# ROADMAP M2's "retry/backoff", plus timeout and failure classification.
#
# Every flaky step here is flaky BY DECLARATION - the NoOp step's failAttempt
# property fails attempts 1..N and succeeds afterwards - so the test is
# deterministic. Proving a retry policy against something genuinely intermittent
# gives a suite that fails one run in twenty and teaches everyone to re-run it.
#
# AND NOTHING HERE WAITS. Every backoff is taken through the injected clock,
# whose Sleep advances fake time and returns immediately. If this file ever takes
# as long as the delays it configures, the clock stopped being injected
# somewhere.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # -Yaml, in one place, so a retry policy reads the way sequence.yaml does.
    $script:flakyYaml = {
        param([string] $Retry = '', [string] $Extra = '', [int] $FailAttempt = 0)

        $failLine = ''
        if ($FailAttempt -gt 0) {
            $failLine = "    failAttempt: {0}`n" -f $FailAttempt
        }

        return @"
schemaVersion: 1
id: RETRY
name: A flaky step
steps:
  - name: Before
    type: NoOp
  - name: Flaky
    type: NoOp
$failLine$Retry$Extra
  - name: After
    type: NoOp
"@
    }

    $script:attemptCount = {
        param($Harness)

        return @(Get-HDTLogRecord -FileSystem $Harness.FileSystem -Path $Harness.Log.JsonlPath -Event 'step.start' |
                Where-Object { $_.stepIndex -eq 2 }).Count
    }
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'retry' {

        It 'does not retry a step with no retry policy' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 1)
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            & $script:attemptCount $harness | Should -Be 1
            $result.Status | Should -BeExactly 'Failed'
        }

        It 'retries up to the configured count' {
            # count: 2 is 1 + 2 = three attempts, and failAttempt: 3 fails all
            # three of them.
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 3 -Retry "    retry:`n      count: 2`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            & $script:attemptCount $harness | Should -Be 3
            $result.Status | Should -BeExactly 'Failed'
        }

        It 'stops retrying once the step succeeds' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 1 -Retry "    retry:`n      count: 3`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            & $script:attemptCount $harness | Should -Be 2
        }

        It 'reports Completed after a successful retry' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 1 -Retry "    retry:`n      count: 3`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'
            @($result.Result | Where-Object { $_.Index -eq 2 })[0].Status | Should -BeExactly 'Completed'
        }

        It 'records the attempt number in the state' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 1 -Retry "    retry:`n      count: 3`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.State.step | Where-Object { $_.index -eq 2 })[0].attempt | Should -Be 2
        }

        It 'returns the attempt number in the result' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 2 -Retry "    retry:`n      count: 3`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.Result | Where-Object { $_.Index -eq 2 })[0].Attempt | Should -Be 3
        }

        It 'logs one step.start per attempt' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 3 -Retry "    retry:`n      count: 2`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $started = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Event 'step.start' |
                    Where-Object { $_.stepIndex -eq 2 })

            @($started | ForEach-Object { $_.data.attempt }) | Should -Be @(1, 2, 3)
        }

        It 'logs the attempt number in the step.fail data' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 3 -Retry "    retry:`n      count: 2`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $failed = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Event 'step.fail' |
                    Where-Object { $_.stepIndex -eq 2 -and $null -ne $_.data.failureClass })

            $failed.Count | Should -Be 1
            $failed[0].data.attempt | Should -Be 3
        }

        It 'reports Failed after the last attempt failed' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 5 -Retry "    retry:`n      count: 2`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Failed'
            $result.FailedStep.Name | Should -BeExactly 'Flaky'
        }

        It 'classes a plain step failure as Transient' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 1)
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.Result | Where-Object { $_.Index -eq 2 })[0].FailureClass | Should -BeExactly 'Transient'
        }

        It 'does not retry a Configuration failure' {
            # A SetVariable step assigning outside the HDT namespace throws a
            # terminating HDTConfigurationError. retry: { count: 3 } is declared
            # and deliberately ignored.
            $yaml = @'
schemaVersion: 1
id: RETRY-CONFIG
name: A configuration failure
steps:
  - name: Wrong namespace
    type: SetVariable
    variable: NotAnHDTName
    value: nope
    retry:
      count: 3
      delaySeconds: 30
'@
            $harness = New-HDTSequenceTestHarness -Yaml $yaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Event 'step.start').Count | Should -Be 1
            @($result.Result | Where-Object { $_.Index -eq 1 })[0].FailureClass | Should -BeExactly 'Configuration'
            $harness.Clock.TotalSleepMillisecond | Should -Be 0
        }

        It 'does not retry when continueOnError already tolerated the failure' {
            # The order is retry FIRST, tolerate second: the step is attempted
            # its full three times and only then forgiven.
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 5 `
                    -Retry "    retry:`n      count: 2`n" -Extra "    continueOnError: true`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            & $script:attemptCount $harness | Should -Be 3
            $result.Status | Should -BeExactly 'Succeeded'
            @($result.Result | Where-Object { $_.Index -eq 3 })[0].Status | Should -BeExactly 'Completed'
        }
    }

    Context 'backoff' {

        It 'waits the fixed delay between attempts' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 3 `
                    -Retry "    retry:`n      count: 2`n      delaySeconds: 3`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            # Three attempts, so two waits.
            $harness.Clock.TotalSleepMillisecond | Should -Be 6000
        }

        It 'doubles the delay for exponential backoff' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 4 `
                    -Retry "    retry:`n      count: 3`n      delaySeconds: 1`n      backoff: exponential`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $sleep = @($harness.Journal | Where-Object { $_.Service -eq 'Clock' -and $_.Operation -eq 'Sleep' })

            @($sleep | ForEach-Object { $_.Arguments[0] }) | Should -Be @(1000, 2000, 4000)
            $harness.Clock.TotalSleepMillisecond | Should -Be 7000
        }

        It 'does not wait before the first attempt' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -Retry "    retry:`n      count: 3`n      delaySeconds: 30`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $harness.Clock.TotalSleepMillisecond | Should -Be 0
        }

        It 'does not wait after the last attempt' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 9 `
                    -Retry "    retry:`n      count: 1`n      delaySeconds: 5`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            # Two attempts, one wait - not two.
            $harness.Clock.TotalSleepMillisecond | Should -Be 5000
        }

        It 'does not wait at all when the delay is zero' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 9 -Retry "    retry:`n      count: 2`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            @($harness.Journal | Where-Object { $_.Service -eq 'Clock' -and $_.Operation -eq 'Sleep' }).Count | Should -Be 0
        }

        It 'waits through the injected clock' {
            $harness = New-HDTSequenceTestHarness -Yaml (& $script:flakyYaml -FailAttempt 9 `
                    -Retry "    retry:`n      count: 2`n      delaySeconds: 600`n")

            $elapsed = Measure-Command {
                Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null
            }

            # Twenty minutes of configured backoff, in well under a second.
            $harness.Clock.TotalSleepMillisecond | Should -Be 1200000
            $elapsed.TotalSeconds | Should -BeLessThan 5
        }
    }

    Context 'timeout' {

        It 'passes timeoutMinutes to a CommandLine step as milliseconds' {
            $yaml = @'
schemaVersion: 1
id: TIMEOUT-COMMANDLINE
name: A bounded command
steps:
  - name: Install the agent
    type: CommandLine
    file: setup.exe
    arguments: /q
    timeoutMinutes: 30
'@
            $harness = New-HDTSequenceTestHarness -Yaml $yaml -ProcessResult @{ 'setup.exe /q' = @{ ExitCode = 0 } }
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $start = @($harness.Journal | Where-Object { $_.Service -eq 'ProcessService' -and $_.Operation -eq 'Start' })

            $start.Count | Should -Be 1
            $start[0].Arguments[3] | Should -Be 1800000
        }

        It 'fails a step that ran longer than its timeout' {
            # A clock that jumps a minute per reading crosses a one-minute
            # timeout without anything actually waiting.
            $harness = New-HDTSequenceTestHarness -TickMillisecond 60000 `
                -Yaml (& $script:flakyYaml -Extra "    timeoutMinutes: 1`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $row = @($result.Result | Where-Object { $_.Index -eq 2 })[0]

            $row.Status | Should -BeExactly 'Failed'
            $row.TimedOut | Should -BeTrue
            $result.Status | Should -BeExactly 'Failed'
        }

        It 'says it timed out in the message' {
            $harness = New-HDTSequenceTestHarness -TickMillisecond 60000 `
                -Yaml (& $script:flakyYaml -Extra "    timeoutMinutes: 1`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.Result | Where-Object { $_.Index -eq 2 })[0].Message | Should -BeLike '*timed out*'
        }

        It 'classes a timeout as Environment' {
            $harness = New-HDTSequenceTestHarness -TickMillisecond 60000 `
                -Yaml (& $script:flakyYaml -Extra "    timeoutMinutes: 1`n")
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.Result | Where-Object { $_.Index -eq 2 })[0].FailureClass | Should -BeExactly 'Environment'
        }

        It 'retries a timeout when a retry policy allows it' {
            $harness = New-HDTSequenceTestHarness -TickMillisecond 60000 `
                -Yaml (& $script:flakyYaml -Retry "    retry:`n      count: 2`n" -Extra "    timeoutMinutes: 1`n")
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            & $script:attemptCount $harness | Should -Be 3
        }

        It 'does not bound a step that declares no timeoutMinutes' {
            # timeoutMinutes is absent, which the flattener defaults to 0, and 0
            # is unbounded.
            $harness = New-HDTSequenceTestHarness -TickMillisecond 600000 -Yaml (& $script:flakyYaml)
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'
            @($result.Result | Where-Object { $_.Index -eq 2 })[0].TimedOut | Should -BeFalse
        }

        It 'records the duration on every step' {
            $harness = New-HDTSequenceTestHarness -TickMillisecond 1000 -Yaml (& $script:flakyYaml)
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            foreach ($row in @($result.Result)) {
                $row.DurationMs | Should -BeGreaterThan 0 -Because "step $($row.Index) took measurable time on a ticking clock"
            }

            foreach ($step in @($result.State.step)) {
                $step.durationMs | Should -BeGreaterThan 0
            }
        }
    }
}
