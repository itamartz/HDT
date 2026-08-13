# ROADMAP M2's "a simulated reboot mid-sequence resuming at the right index" and
# "an interrupted non-resumable step failing rather than silently re-running".
#
# Every test here drives two or three LEGS. A leg ends at RebootPending; the next
# one begins by taking the state document out of the fake filesystem AS TEXT and
# importing it back, which is what a real second leg does after the RAM disk it
# was written from has gone. Passing the in-memory object between legs would
# prove nothing about the document.
#
# The legs share one fake filesystem, so the JSONL stream is genuinely one file
# across all three - which is how the seq continuity assertion is possible at
# all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:rebootYaml = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences/valid-reboot-legs.yaml') -Raw

    # One leg: a fresh harness over the shared filesystem, resumed from the state
    # text the previous leg checkpointed.
    $script:runLeg = {
        param([object] $FileSystem, [string] $StateJson, [string] $Phase)

        $argument = @{ Yaml = $script:rebootYaml; Phase = $Phase }
        if ($null -ne $FileSystem) { $argument['FileSystem'] = $FileSystem }
        if (-not [string]::IsNullOrEmpty($StateJson)) { $argument['StateJson'] = $StateJson }

        $harness = New-HDTSequenceTestHarness @argument

        # What Invoke-HDTBootReconciliation does before handing the state over.
        if (-not [string]::IsNullOrEmpty($StateJson)) {
            $harness.State.leg = [int] $harness.State.leg + 1
        }

        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        return [pscustomobject] @{
            Harness   = $harness
            Result    = $result
            StateJson = $harness.FileSystem.ReadAllText($harness.StatePath)
        }
    }
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'resuming at the right index' {

        BeforeAll {
            $script:fs = New-HDTFakeFileSystem

            $script:leg1 = & $script:runLeg $script:fs '' 'WinPE'
            $script:leg2 = & $script:runLeg $script:fs $script:leg1.StateJson 'FullOS'
            $script:leg3 = & $script:runLeg $script:fs $script:leg2.StateJson 'FullOS'

            $script:record = @(Get-HDTLogRecord -FileSystem $script:fs -Path 'X:\HDT\Logs\HDT.jsonl')
        }

        It 'ends the first leg at the Restart' {
            $script:leg1.Result.Status | Should -BeExactly 'RebootPending'
            @($script:leg1.Result.Result | ForEach-Object { $_.Name }) |
                Should -Be @('Prepare the disk', 'Remember the first leg', 'Restart into the full OS')
        }

        It 'starts the second leg at the step after the Restart' {
            $ran = @($script:leg2.Result.Result | Where-Object { $_.Status -ne 'Skipped' })

            $ran[0].Index | Should -Be 4
            $ran[0].Name | Should -BeExactly 'Confirm the first leg'
        }

        It 'does not re-run a completed step' {
            $completed = @($script:record | Where-Object { $_.event -eq 'step.complete' -and $_.stepName -eq 'Prepare the disk' })

            $completed.Count | Should -Be 1
        }

        It 'logs step.skip for steps completed on a previous leg' {
            $skip = @($script:record | Where-Object { $_.event -eq 'step.skip' -and $_.stepName -eq 'Prepare the disk' })

            $skip.Count | Should -BeGreaterOrEqual 1
        }

        It 'names the leg they completed on' {
            $skip = @($script:record | Where-Object { $_.event -eq 'step.skip' -and $_.stepName -eq 'Prepare the disk' })[0]

            $skip.message | Should -BeLike '*leg 1*'
        }

        It 'increments the leg on each resume' {
            $script:leg1.Result.State.leg | Should -Be 1
            $script:leg2.Result.State.leg | Should -Be 2
            $script:leg3.Result.State.leg | Should -Be 3
        }

        It 'runs every remaining step' {
            $script:leg3.Result.Status | Should -BeExactly 'Succeeded'
        }

        It 'reports Succeeded at the end of the last leg' {
            $script:leg3.Result.State.status | Should -BeExactly 'Succeeded'
        }

        It 'runs the whole sequence exactly once across three legs' {
            # The property the whole state document exists for.
            $completed = @($script:record | Where-Object { $_.event -eq 'step.complete' } | ForEach-Object { $_.stepName })

            $completed | Should -Be @(
                'Prepare the disk',
                'Remember the first leg',
                'Restart into the full OS',
                'Confirm the first leg',
                'Restart again',
                'Full OS only',
                'Finish')

            @($completed | Select-Object -Unique).Count | Should -Be $completed.Count
        }

        It 'continues the JSONL seq across legs' {
            # No restart to 1, no gap. The reboot-survival property of DESIGN
            # 4.4.2, over one physical log file written by three separate runs.
            $seq = @($script:record | ForEach-Object { [long] $_.seq })

            $seq[0] | Should -Be 1
            $seq | Should -Be @(1..$seq.Count)
        }

        It 'carries variables set in the first leg into the second' {
            # 'Confirm the first leg' is conditioned on %HDTFirstLeg%, which a
            # SetVariable step set before the reboot. It can only be there
            # because the state document carried it.
            @($script:leg2.Result.Result | Where-Object { $_.Name -eq 'Confirm the first leg' })[0].Status |
                Should -BeExactly 'Completed'

            $script:leg2.Result.State.variable['HDTFirstLeg'] | Should -BeExactly 'done'
        }

        It 'switches to FullOS steps after the reboot' {
            @($script:leg3.Result.Result | Where-Object { $_.Name -eq 'Full OS only' })[0].Status | Should -BeExactly 'Completed'
        }

        It 'skips WinPE-only steps in the second leg' {
            $row = @($script:leg3.Result.Result | Where-Object { $_.Name -eq 'WinPE only' })[0]

            $row.Status | Should -BeExactly 'Skipped'
            $row.Reason | Should -BeLike '*WinPE*'
        }

        It 'logs phase.change on the leg that changed phase' {
            $change = @($script:record | Where-Object { $_.event -eq 'phase.change' })

            $change.Count | Should -Be 1
            $change[0].message | Should -BeLike '*FullOS*'
        }

        It 'tears autologon down at the end of the last leg' {
            Get-HDTAutoLogonArtifact -Registry $script:leg3.Harness.Registry -Lsa $script:leg3.Harness.Lsa `
                -FileSystem $script:fs -State $script:leg3.Result.State | Should -BeNullOrEmpty
        }
    }

    Context 'an interrupted step' {

        BeforeEach {
            # A machine that died mid-step: step 1 is Running and the run is on
            # leg 2. Whether it re-runs is the step's own declaration.
            $script:interruptedYaml = @'
schemaVersion: 1
id: INTERRUPTED
name: An interrupted step
steps:
  - name: Half applied
    type: CommandLine
    command: setup.exe /q
  - name: After it
    type: NoOp
'@
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:interruptedYaml `
                -ProcessResult @{ 'cmd.exe /c setup.exe /q' = @{ ExitCode = 0 } }

            $script:harness.State.leg = 2
            $script:harness.State.stepIndex = 1
            $script:harness.State.step[0].status = 'Running'
            $script:harness.State.step[0].attempt = 1
            $script:harness.State.step[0].leg = 1

            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'fails the run when a Running step is not resumable' {
            $script:result.Status | Should -BeExactly 'Failed'
        }

        It 'reports Failed' {
            $script:result.State.status | Should -BeExactly 'Failed'
        }

        It 'names the step and says it does not declare resumable' {
            $message = @($script:result.Result | Where-Object { $_.Index -eq 1 })[0].Message

            $message | Should -BeLike '*Half applied*'
            $message | Should -BeLike '*resumable*'
        }

        It 'does not invoke that step' {
            # The whole point: half-applied work is not silently repeated.
            $script:harness.Process.GetOperationName() | Should -BeNullOrEmpty
        }

        It 'returns the failing step' {
            $script:result.FailedStep.Name | Should -BeExactly 'Half applied'
        }

        It 'does not run the step after it' {
            @($script:result.State.step | Where-Object { $_.index -eq 2 })[0].status | Should -BeExactly 'Pending'
        }

        It 'leaves the run resumable at that index if it is interrupted again' {
            $script:result.State.stepIndex | Should -Be 1
        }

        It 'tears autologon down' {
            # A failed run still disarms the machine.
            Get-HDTAutoLogonArtifact -Registry $script:harness.Registry -Lsa $script:harness.Lsa `
                -FileSystem $script:harness.FileSystem -State $script:result.State | Should -BeNullOrEmpty
        }

        It 're-runs a Running step that declares resumable true' {
            $yaml = $script:interruptedYaml -replace '    command: setup.exe /q', "    command: setup.exe /q`n    resumable: true"

            $harness = New-HDTSequenceTestHarness -Yaml $yaml -ProcessResult @{ 'cmd.exe /c setup.exe /q' = @{ ExitCode = 0 } }
            $harness.State.leg = 2
            $harness.State.stepIndex = 1
            $harness.State.step[0].status = 'Running'
            $harness.State.step[0].leg = 1

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'
            $harness.Process.GetOperationName() | Should -Be @('Start')
        }

        It 'logs a Warning when it resumes an interrupted resumable step' {
            $yaml = $script:interruptedYaml -replace '    command: setup.exe /q', "    command: setup.exe /q`n    resumable: true"

            $harness = New-HDTSequenceTestHarness -Yaml $yaml -ProcessResult @{ 'cmd.exe /c setup.exe /q' = @{ ExitCode = 0 } }
            $harness.State.leg = 2
            $harness.State.stepIndex = 1
            $harness.State.step[0].status = 'Running'
            $harness.State.step[0].leg = 1

            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $warning = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Severity Warning |
                    Where-Object { $_.message -like '*interrupted*' })

            $warning.Count | Should -Be 1
        }
    }
}
