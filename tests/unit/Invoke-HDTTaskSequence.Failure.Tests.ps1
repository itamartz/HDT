# What the loop does with a step that failed (DESIGN 4.3, 12.1).
#
# ROADMAP M2's "continueOnError semantics": a tolerated failure carries on and is
# still RECORDED as a failure; an untolerated one ends the run AT the step it
# failed on, so a resume retries it rather than continuing on top of work that
# never happened.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences'
    $script:continueYaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-continue-on-error.yaml') -Raw

    # Only tolerated failures: the run must still report Succeeded.
    $script:toleratedOnlyYaml = @'
schemaVersion: 1
id: TOLERATED-ONLY
name: Only tolerated failures
steps:
  - name: First
    type: NoOp
  - name: Tolerated one
    type: NoOp
    fail: true
    continueOnError: true
  - name: Tolerated two
    type: NoOp
    fail: true
    continueOnError: true
  - name: Last
    type: NoOp
'@

    $script:unknownTypeYaml = @'
schemaVersion: 1
id: UNKNOWN-TYPE
name: An unknown step type
steps:
  - name: First
    type: NoOp
  - name: Nobody implements this
    type: Contoso
    retry:
      count: 3
  - name: Never runs
    type: NoOp
'@
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'continueOnError' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:continueYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'continues past a failed step when continueOnError is true' {
            @($script:result.Result | Where-Object { $_.Name -eq 'After the tolerated failure' })[0].Status |
                Should -BeExactly 'Completed'
        }

        It 'records the step as Failed even though the run continued' {
            @($script:result.Result | Where-Object { $_.Name -eq 'Tolerated failure' })[0].Status | Should -BeExactly 'Failed'
            @($script:result.State.step | Where-Object { $_.index -eq 2 })[0].status | Should -BeExactly 'Failed'
        }

        It 'keeps the exit code of a tolerated failure' {
            @($script:result.Result | Where-Object { $_.Name -eq 'Tolerated failure' })[0].ExitCode | Should -Be 5
        }

        It 'logs a Warning for each tolerated failure' {
            $warning = @($script:record | Where-Object { $_.level -eq 'Warning' -and $_.message -like '*continueOnError*' })

            $warning.Count | Should -Be 1
        }

        It 'stops at a failed step when continueOnError is false' {
            @($script:result.Result | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3, 4)
        }

        It 'does not run the steps after it' {
            @($script:result.Result | Where-Object { $_.Name -eq 'Never runs' }) | Should -BeNullOrEmpty
            @($script:result.State.step | Where-Object { $_.index -eq 5 })[0].status | Should -BeExactly 'Pending'
        }

        It 'reports Failed' {
            $script:result.Status | Should -BeExactly 'Failed'
            $script:result.State.status | Should -BeExactly 'Failed'
        }

        It 'returns the failing step' {
            $script:result.FailedStep.Name | Should -BeExactly 'Fatal failure'
            $script:result.FailedStep.Index | Should -Be 4
        }

        It 'leaves stepIndex at the failed step' {
            # So a resume retries it rather than skipping past it.
            $script:result.State.stepIndex | Should -Be 4
        }

        It 'logs a step.fail for the step that ended the run' {
            $fail = @($script:record | Where-Object { $_.event -eq 'step.fail' -and $_.stepName -eq 'Fatal failure' })

            $fail.Count | Should -BeGreaterOrEqual 1
        }

        It 'reports Succeeded when only continueOnError steps failed' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:toleratedOnlyYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'
            $result.FailedStep | Should -BeNullOrEmpty
            @($result.Result | ForEach-Object { $_.Status }) | Should -Be @('Completed', 'Failed', 'Failed', 'Completed')
        }

        It 'counts the outcomes in the run.end record' {
            $end = @($script:record | Where-Object { $_.event -eq 'run.end' })[0]

            $end.data.completed | Should -Be 2
            $end.data.failed | Should -Be 2
            $end.data.skipped | Should -Be 0
        }
    }

    Context 'an unknown step type' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:unknownTypeYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'fails the step rather than the import' {
            $script:result.Status | Should -BeExactly 'Failed'
            @($script:result.Result | Where-Object { $_.Index -eq 2 })[0].Status | Should -BeExactly 'Failed'
        }

        It 'ran the step before it' {
            @($script:result.Result | Where-Object { $_.Index -eq 1 })[0].Status | Should -BeExactly 'Completed'
        }

        It 'names the unknown type' {
            @($script:result.Result | Where-Object { $_.Index -eq 2 })[0].Message | Should -BeLike '*Contoso*'
        }

        It 'lists the known types' {
            @($script:result.Result | Where-Object { $_.Index -eq 2 })[0].Message | Should -BeLike '*CommandLine*'
        }

        It 'classes it as a Configuration failure' {
            @($script:result.Result | Where-Object { $_.Index -eq 2 })[0].FailureClass | Should -BeExactly 'Configuration'
        }

        It 'does not retry a Configuration failure' {
            # retry: { count: 3 } is declared on the step and deliberately ignored.
            $started = @($script:record | Where-Object { $_.event -eq 'step.start' -and $_.stepIndex -eq 2 })

            $started.Count | Should -Be 1
        }
    }

    Context 'a step that threw' {

        BeforeEach {
            # SetVariable throws a terminating HDTConfigurationError for a name
            # outside the HDT namespace, so this is a real thrown failure rather
            # than a manufactured one.
            $script:throwYaml = @'
schemaVersion: 1
id: THROWING-STEP
name: A step that throws
steps:
  - name: Assign the wrong namespace
    type: SetVariable
    variable: NotAnHDTName
    value: nope
  - name: Never runs
    type: NoOp
'@
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:throwYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        }

        It 'turns the exception into a Failed step rather than a thrown run' {
            $script:result.Status | Should -BeExactly 'Failed'
            @($script:result.Result | Where-Object { $_.Index -eq 1 })[0].Status | Should -BeExactly 'Failed'
        }

        It 'carries the exception message into the result' {
            @($script:result.Result | Where-Object { $_.Index -eq 1 })[0].Message | Should -BeLike '*NotAnHDTName*'
        }

        It 'classes it as a Configuration failure' {
            @($script:result.Result | Where-Object { $_.Index -eq 1 })[0].FailureClass | Should -BeExactly 'Configuration'
        }

        It 'does not run the step after it' {
            @($script:result.State.step | Where-Object { $_.index -eq 2 })[0].status | Should -BeExactly 'Pending'
        }
    }

    Context 'PauseOnError' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:continueYaml
            $script:harness.State.pauseOnError = $true
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
            $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
        }

        It 'returns rather than prompting' {
            $script:result.Status | Should -BeExactly 'Failed'
        }

        It 'logs at Error that the run is paused' {
            $paused = @($script:record | Where-Object { $_.level -eq 'Error' -and $_.message -like '*paused*' })

            $paused.Count | Should -Be 1
        }

        It 'leaves the state loaded and saved' {
            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json

            $saved.status | Should -BeExactly 'Failed'
            $saved.stepIndex | Should -Be 4
        }

        It 'still returns the failing step' {
            $script:result.FailedStep.Name | Should -BeExactly 'Fatal failure'
        }

        It 'reads pauseOnError from the state rather than from a parameter' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:continueYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State
            $record = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath)

            $result.Status | Should -BeExactly 'Failed'
            @($record | Where-Object { $_.message -like '*paused*' }).Count | Should -Be 0
        }
    }

    Context 'the engine never prompts' {

        It 'names Read-Host nowhere in the engine' {
            # DESIGN 4.3's PauseOnError drops to a prompt in the CALLER
            # (Start-HDTDeployment, phase 05). An engine that blocked on input
            # could not be unit tested and would hang CI.
            $hit = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src') -Filter '*.ps1' -Recurse |
                    Select-String -Pattern 'Read-Host' -SimpleMatch)

            $hit.Count | Should -Be 0 -Because (@($hit | ForEach-Object { $_.Path }) -join "`n")
        }
    }
}
