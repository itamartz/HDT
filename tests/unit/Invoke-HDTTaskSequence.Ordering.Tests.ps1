# The execution loop: ordering, phase filtering and conditions (DESIGN 4.3).
#
# This is the first half of DESIGN 12.2.1's headline target - "the entire task
# sequence engine can execute a full sequence end-to-end in a Pester run against
# fake services, asserting the ordered list of operations it would have
# performed" - and ROADMAP M2's "conditions skipping groups".
#
# Everything here runs against fakes. Nothing on this machine is read or written.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences'

    $script:flatYaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-flat.yaml') -Raw
    $script:conditionYaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-conditional-group.yaml') -Raw

    $script:phaseYaml = @'
schemaVersion: 1
id: PHASE-FILTER
name: Phase filtering
steps:
  - name: Anywhere
    type: NoOp
  - name: WinPE only
    type: NoOp
    runIn: WinPE
  - name: Full OS only
    type: NoOp
    runIn: FullOS
  - name: The end
    type: NoOp
'@
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'ordering' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'runs every step once, in index order' {
            $started = @($script:record | Where-Object { $_.event -eq 'step.start' })

            @($started | ForEach-Object { $_.stepName }) | Should -Be @('First', 'Second', 'Third')
        }

        It 'reports Succeeded when every step completed' {
            $script:result.Status | Should -BeExactly 'Succeeded'
        }

        It 'returns one result per step, in order' {
            @($script:result.Result | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
            @($script:result.Result | ForEach-Object { $_.Status }) | Should -Be @('Completed', 'Completed', 'Completed')
        }

        It 'returns no failing step' {
            $script:result.FailedStep | Should -BeNullOrEmpty
        }

        It 'records every step Completed in the state' {
            @($script:result.State.step | ForEach-Object { $_.status }) | Should -Be @('Completed', 'Completed', 'Completed')
        }

        It 'leaves stepIndex past the last step' {
            $script:result.State.stepIndex | Should -Be 4
        }

        It 'sets the state status to Succeeded' {
            $script:result.State.status | Should -BeExactly 'Succeeded'
        }

        It 'logs run.start first and run.end last' {
            $script:record[0].event | Should -BeExactly 'run.start'
            $script:record[-1].event | Should -BeExactly 'run.end'
        }

        It 'logs one step.complete per step' {
            @($script:record | Where-Object { $_.event -eq 'step.complete' }).Count | Should -Be 3
        }

        It 'writes a status heartbeat at the start and the end' {
            $heartbeat = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:harness.StatusPath })

            $heartbeat.Count | Should -BeGreaterOrEqual 2
        }

        It 'leaves the final heartbeat reporting the run status' {
            $status = $script:harness.FileSystem.ReadAllText($script:harness.StatusPath) | ConvertFrom-Json

            $status.status | Should -BeExactly 'Succeeded'
        }

        It 'checkpoints the state after every step' {
            $checkpoint = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:harness.StatePath })

            # Running plus the outcome for each of three steps, plus the final
            # save in the finally block.
            $checkpoint.Count | Should -BeGreaterOrEqual 7
        }

        It 'numbers per-step logs in execution order' {
            $script:harness.FileSystem.TestPath('X:\HDT\Logs\Steps\001-First.log') | Should -BeTrue
            $script:harness.FileSystem.TestPath('X:\HDT\Logs\Steps\002-Second.log') | Should -BeTrue
            $script:harness.FileSystem.TestPath('X:\HDT\Logs\Steps\003-Third.log') | Should -BeTrue
        }

        It 'sets the step name and type on the log context for every step' {
            $started = @($script:record | Where-Object { $_.event -eq 'step.start' })

            @($started | ForEach-Object { $_.stepIndex }) | Should -Be @(1, 2, 3)
            @($started | ForEach-Object { $_.stepType }) | Should -Be @('NoOp', 'SetVariable', 'NoOp')
        }

        It 'clears the step from the log context before run.end' {
            $end = @($script:record | Where-Object { $_.event -eq 'run.end' })[0]

            $end.PSObject.Properties['stepName'] | Should -BeNullOrEmpty
        }

        It 'carries a variable a step set into the returned state' {
            $script:result.State.variable['HDTStage'] | Should -BeExactly 'second'
        }
    }

    Context 'step type discovery' {

        It 'discovers step types once, not once per step' {
            # A mock is right here and a fake is not: the question is how many
            # times the engine called its own discovery, which no service double
            # can answer.
            $global:HDTTestStepType = Get-HDTStepType

            try {
                Mock -ModuleName Hephaestus -CommandName Get-HDTStepType -MockWith { $global:HDTTestStepType }

                $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
                Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

                Should -Invoke -ModuleName Hephaestus -CommandName Get-HDTStepType -Times 1 -Exactly
            } finally {
                Remove-Variable -Name HDTTestStepType -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'uses a registry it was given rather than discovering one' {
            $global:HDTTestStepType = Get-HDTStepType

            try {
                Mock -ModuleName Hephaestus -CommandName Get-HDTStepType -MockWith { $global:HDTTestStepType }

                $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
                Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                    -State $harness.State -StepType $global:HDTTestStepType | Out-Null

                Should -Invoke -ModuleName Hephaestus -CommandName Get-HDTStepType -Times 0 -Exactly
            } finally {
                Remove-Variable -Name HDTTestStepType -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'a state it was not given' {

        It 'builds its own run state when none was supplied' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context

            $result.Status | Should -BeExactly 'Succeeded'
            @($result.State.step).Count | Should -Be 3
            $result.State.sequenceId | Should -BeExactly 'FLAT'
        }
    }

    Context 'phase filtering' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:phaseYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'runs a WinPE step while in WinPE' {
            @($script:result.Result | Where-Object { $_.Name -eq 'WinPE only' })[0].Status | Should -BeExactly 'Completed'
        }

        It 'skips a FullOS step while in WinPE' {
            @($script:result.Result | Where-Object { $_.Name -eq 'Full OS only' })[0].Status | Should -BeExactly 'Skipped'
        }

        It 'names the phase in the skip reason' {
            $reason = @($script:result.Result | Where-Object { $_.Name -eq 'Full OS only' })[0].Reason

            $reason | Should -BeLike '*FullOS*'
            $reason | Should -BeLike '*WinPE*'
        }

        It 'logs a step.skip naming the step' {
            $skip = @($script:record | Where-Object { $_.event -eq 'step.skip' })

            $skip.Count | Should -Be 1
            $skip[0].stepName | Should -BeExactly 'Full OS only'
        }

        It 'records the skip in the state' {
            @($script:result.State.step | Where-Object { $_.index -eq 3 })[0].status | Should -BeExactly 'Skipped'
        }

        It 'advances past a skipped step' {
            @($script:result.Result | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3, 4)
            $script:result.Status | Should -BeExactly 'Succeeded'
        }

        It 'does not log phase.change when the context phase and the state phase match' {
            @($script:record | Where-Object { $_.event -eq 'phase.change' }).Count | Should -Be 0
        }

        It 'logs phase.change when the context phase differs from the state phase' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:phaseYaml
            $harness.State.phase = 'WinPE'

            $second = New-HDTSequenceTestHarness -Yaml $script:phaseYaml -Phase FullOS -State $harness.State
            Invoke-HDTTaskSequence -Sequence $second.Sequence -Context $second.Context -State $second.State | Out-Null

            $record = @(Get-HDTLogRecord -FileSystem $second.FileSystem -Path $second.Log.JsonlPath -Event 'phase.change')

            $record.Count | Should -Be 1
            $record[0].message | Should -BeLike '*FullOS*'
        }

        It 'records the new phase in the state after a phase change' {
            $first = New-HDTSequenceTestHarness -Yaml $script:phaseYaml
            $second = New-HDTSequenceTestHarness -Yaml $script:phaseYaml -Phase FullOS -State $first.State

            $result = Invoke-HDTTaskSequence -Sequence $second.Sequence -Context $second.Context -State $second.State

            $result.State.phase | Should -BeExactly 'FullOS'
        }
    }

    Context 'conditions' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:conditionYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
            $script:byName = {
                param([string] $Name)
                return @($script:result.Result | Where-Object { $_.Name -eq $Name })[0]
            }
        }

        It 'runs a step whose condition is true' {
            (& $script:byName 'Runs when the gate is open').Status | Should -BeExactly 'Completed'
        }

        It 'skips a step whose condition is false' {
            (& $script:byName 'Skipped while the gate is open').Status | Should -BeExactly 'Skipped'
        }

        It 'names the condition in the skip reason' {
            (& $script:byName 'Skipped while the gate is open').Reason | Should -BeLike '*"%HDTGate%" == "closed"*'
        }

        It 'skips every step in a group whose condition is false' {
            # ROADMAP M2: "conditions skipping groups". Three contained steps,
            # each named, rather than one line that hides them.
            (& $script:byName 'Laptop first').Status | Should -BeExactly 'Skipped'
            (& $script:byName 'Laptop second').Status | Should -BeExactly 'Skipped'
            (& $script:byName 'Laptop inner first').Status | Should -BeExactly 'Skipped'
        }

        It 'names the group in each of those skip reasons' {
            foreach ($name in @('Laptop first', 'Laptop second', 'Laptop inner first')) {
                (& $script:byName $name).Reason | Should -BeLike "*Laptop only*" -Because "the skip reason for '$name' must name the group"
            }
        }

        It 'skips a step of an inner group when the outer group is false' {
            (& $script:byName 'Laptop inner first').Status | Should -BeExactly 'Skipped'
            (& $script:byName 'Laptop inner first').Reason | Should -BeLike '*Laptop only*'
        }

        It 'evaluates a group condition against a variable a previous step set' {
            # The gate is opened by step 2, so a group condition read at import
            # time would have been false.
            (& $script:byName 'Inside the open group').Status | Should -BeExactly 'Completed'
        }

        It 'runs the steps after that group' {
            (& $script:byName 'After the groups').Status | Should -BeExactly 'Completed'
        }

        It 'reports an unresolved condition token in the log' {
            $warning = @($script:record | Where-Object { $_.level -eq 'Warning' -and $_.message -like '*HDTNeverSupplied*' })

            $warning.Count | Should -BeGreaterOrEqual 1
        }

        It 'leaves an unresolved token false rather than empty' {
            (& $script:byName 'Skipped for an unresolved token').Status | Should -BeExactly 'Skipped'
        }

        It 'skips a step whose applicability function returned false' {
            (& $script:byName 'Nothing to run').Status | Should -BeExactly 'Skipped'
            (& $script:byName 'Nothing to run').Reason | Should -BeLike '*PowerShell*'
        }

        It 'reports Succeeded even though six steps were skipped' {
            $script:result.Status | Should -BeExactly 'Succeeded'
        }

        It 'returns one result per step of the flattened sequence' {
            @($script:result.Result).Count | Should -Be @($script:harness.Sequence.Step).Count
        }
    }

    Context 'the parameters' {

        It 'defaults the state and status paths to the log directory' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $harness.FileSystem.TestPath('X:\HDT\Logs\state.json') | Should -BeTrue
            $harness.FileSystem.TestPath('X:\HDT\Logs\status.json') | Should -BeTrue
        }

        It 'mirrors the state when a mirror path was given' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State `
                -MirrorStatePath 'W:\HDT\state.json' | Out-Null

            $harness.FileSystem.TestPath('W:\HDT\state.json') | Should -BeTrue
        }

        It 'runs nothing under -WhatIf' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:flatYaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State -WhatIf | Out-Null

            $harness.FileSystem.TestPath($harness.Log.JsonlPath) | Should -BeFalse
            @($harness.State.step | ForEach-Object { $_.status }) | Should -Be @('Pending', 'Pending', 'Pending')
        }
    }
}
