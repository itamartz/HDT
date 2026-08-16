# WHAT THE PROGRESS WINDOW SHOWS, WORKED OUT FROM THE LOG.
#
# DESIGN 11.1: the progress window is driven by the JSONL event stream and NOT
# by a parallel progress API. The engine already emits run.start, step.start,
# step.complete, step.fail, step.skip and phase.change with a controlled
# vocabulary (DESIGN 4.4.2), so there is exactly one source of truth for what a
# deployment is doing - the screen and the log can never disagree, and a step
# author gets progress for free without calling a UI function.
#
# THIS IS THAT DERIVATION, AND IT IS PURE. No window, no runspace, no clock, no
# file system. The window is a thin adapter over what this returns, which is
# what lets the whole of it be asserted on a developer machine with no display.
#
# ELAPSED COMES FROM THE RECORDS' OWN TIMESTAMPS. Reading a clock here would
# make every assertion below depend on when it ran, and would report time
# passing during a reboot the deployment was not running through.
#
# THE RECORDS ARE THE REAL SHAPE - ts, runId, seq, level, phase, stepIndex,
# stepName, stepType, component, event, message, durationMs, data - as
# ConvertTo-HDTLogRecord writes them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTProgressRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Event,

            [Parameter()]
            [int] $Second = 0,

            [Parameter()]
            [string] $Phase = 'WinPE',

            [Parameter()]
            [AllowNull()]
            [hashtable] $Data,

            [Parameter()]
            [int] $StepIndex = 0,

            [Parameter()]
            [AllowEmptyString()]
            [string] $StepName = ''
        )

        $record = [ordered] @{
            ts        = ([datetime]::new(2026, 8, 15, 9, 0, 0, [System.DateTimeKind]::Utc)).AddSeconds($Second).ToString('o')
            runId     = 'r-1'
            seq       = $Second + 1
            level     = 'Info'
            phase     = $Phase
            component = 'Engine'
            event     = $Event
            message   = $Event
        }

        if ($StepIndex -gt 0) {
            $record['stepIndex'] = $StepIndex
            $record['stepName'] = $StepName
            $record['stepType'] = 'NoOp'
        }

        if ($null -ne $Data) { $record['data'] = $Data }

        return [pscustomobject] $record
    }

    # A run that has partitioned a disk and is applying an image: five steps,
    # two finished, the third in flight.
    $script:midRun = @(
        New-HDTProgressRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepIndex = 0; stepCount = 5; leg = 1 }
        New-HDTProgressRecord -Event 'step.start' -Second 1 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1; name = 'Partition disk'; type = 'DiskPartition'; attempt = 1 }
        New-HDTProgressRecord -Event 'step.complete' -Second 20 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1; attempt = 1; exitCode = 0 }
        New-HDTProgressRecord -Event 'step.start' -Second 21 -StepIndex 2 -StepName 'Apply unattend' -Data @{ index = 2; name = 'Apply unattend'; type = 'ApplyUnattend'; attempt = 1 }
        New-HDTProgressRecord -Event 'step.complete' -Second 25 -StepIndex 2 -StepName 'Apply unattend' -Data @{ index = 2; attempt = 1; exitCode = 0 }
        New-HDTProgressRecord -Event 'step.start' -Second 26 -StepIndex 3 -StepName 'Apply image' -Data @{ index = 3; name = 'Apply image'; type = 'ApplyImage'; attempt = 1 }
    )
}

Describe 'Get-HDTDeploymentProgress' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTDeploymentProgress' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a run in flight' {

        It 'names the task sequence' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).SequenceId | Should -BeExactly 'STD-CLIENT'
        }

        It 'names the step that is running now' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).StepName | Should -BeExactly 'Apply image'
        }

        It 'says step N of M' {
            $progress = Get-HDTDeploymentProgress -Record $script:midRun

            [int] $progress.StepNumber | Should -Be 3
            [int] $progress.StepCount | Should -Be 5
        }

        It 'counts a step as done when it finished, not when the next one started' {
            # THE OFF-BY-ONE A PROGRESS BAR ALWAYS HAS. Two steps have
            # completed; the third is running and has not.
            [int] (Get-HDTDeploymentProgress -Record $script:midRun).CompletedCount | Should -Be 2
        }

        It 'reports percent complete from what finished' {
            [int] (Get-HDTDeploymentProgress -Record $script:midRun).PercentComplete | Should -Be 40
        }

        It 'reports the phase' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).Phase | Should -BeExactly 'WinPE'
        }

        It 'reports elapsed from the records themselves, never from a clock' {
            # A clock here would make this assertion depend on when it ran, and
            # would count time passing during a reboot the deployment was not
            # running through.
            [int] (Get-HDTDeploymentProgress -Record $script:midRun).ElapsedSecond | Should -Be 26
        }

        It 'is Running' {
            [string] (Get-HDTDeploymentProgress -Record $script:midRun).Status | Should -BeExactly 'Running'
        }
    }

    Context 'the phase changing under it' {

        It 'follows phase.change rather than the record it is written on' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'phase.change' -Second 200 -Phase 'WinPE' -Data @{ from = 'WinPE'; to = 'FullOS' })

            [string] (Get-HDTDeploymentProgress -Record $record).Phase | Should -BeExactly 'FullOS'
        }

        It 'keeps counting across the reboot, because the step numbers do' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'phase.change' -Second 200 -Data @{ from = 'WinPE'; to = 'FullOS' }
                New-HDTProgressRecord -Event 'step.complete' -Second 201 -StepIndex 3 -Data @{ index = 3; attempt = 1; exitCode = 0 }
                New-HDTProgressRecord -Event 'step.start' -Second 202 -Phase 'FullOS' -StepIndex 4 -StepName 'Install applications' -Data @{ index = 4; name = 'Install applications'; type = 'InstallApplications'; attempt = 1 })

            $progress = Get-HDTDeploymentProgress -Record $record

            [int] $progress.StepNumber | Should -Be 4
            [int] $progress.CompletedCount | Should -Be 3
            [string] $progress.Phase | Should -BeExactly 'FullOS'
        }
    }

    Context 'a step that did not complete' {

        It 'counts a skipped step as done, because the bar is about progress and not about work' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.skip' -Second 30 -StepIndex 3 -Data @{ index = 3; reason = 'condition' })

            [int] (Get-HDTDeploymentProgress -Record $record).CompletedCount | Should -Be 3
        }

        It 'goes to Failed on step.fail and names the step that did it' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -StepName 'Apply image' -Data @{ index = 3; attempt = 1 })

            $progress = Get-HDTDeploymentProgress -Record $record

            [string] $progress.Status | Should -BeExactly 'Failed'
            [string] $progress.StepName | Should -BeExactly 'Apply image'
        }

        It 'does not count a failed step as completed' {
            # A BAR THAT ADVANCES ON FAILURE IS A BAR THAT LIES at the one
            # moment a technician is reading it closely.
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -Data @{ index = 3; attempt = 1 })

            [int] (Get-HDTDeploymentProgress -Record $record).CompletedCount | Should -Be 2
        }

        It 'stays Failed even if something is logged after it' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.fail' -Second 40 -StepIndex 3 -Data @{ index = 3 }
                New-HDTProgressRecord -Event 'message' -Second 41)

            [string] (Get-HDTDeploymentProgress -Record $record).Status | Should -BeExactly 'Failed'
        }
    }

    Context 'a run that ended' {

        It 'is Succeeded when every step finished' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'step.complete' -Second 60 -StepIndex 3 -Data @{ index = 3 }
                New-HDTProgressRecord -Event 'step.start' -Second 61 -StepIndex 4 -StepName 'Configure boot' -Data @{ index = 4; name = 'Configure boot' }
                New-HDTProgressRecord -Event 'step.complete' -Second 70 -StepIndex 4 -Data @{ index = 4 }
                New-HDTProgressRecord -Event 'step.start' -Second 71 -StepIndex 5 -StepName 'Restart' -Data @{ index = 5; name = 'Restart' }
                New-HDTProgressRecord -Event 'step.complete' -Second 75 -StepIndex 5 -Data @{ index = 5 }
                New-HDTProgressRecord -Event 'run.end' -Second 76 -Data @{ status = 'Succeeded' })

            $progress = Get-HDTDeploymentProgress -Record $record

            [string] $progress.Status | Should -BeExactly 'Succeeded'
            [int] $progress.PercentComplete | Should -Be 100
        }

        It 'takes the status run.end reported rather than counting for itself' {
            $record = @($script:midRun) + @(
                New-HDTProgressRecord -Event 'run.end' -Second 80 -Data @{ status = 'Failed' })

            [string] (Get-HDTDeploymentProgress -Record $record).Status | Should -BeExactly 'Failed'
        }
    }

    Context 'a stream it cannot make sense of' {

        It 'survives no records at all' {
            $progress = Get-HDTDeploymentProgress -Record @()

            [int] $progress.StepCount | Should -Be 0
            [int] $progress.PercentComplete | Should -Be 0
            [string] $progress.Status | Should -BeExactly 'Unknown'
        }

        It 'reports no percentage when nothing said how many steps there are' {
            # A DIVISION BY ZERO IN A PROGRESS BAR takes down the window that
            # was showing a technician what went wrong.
            $record = @(New-HDTProgressRecord -Event 'step.start' -Second 1 -StepIndex 1 -StepName 'Partition disk' -Data @{ index = 1 })

            [int] (Get-HDTDeploymentProgress -Record $record).PercentComplete | Should -Be 0
        }

        It 'ignores a record with no event rather than throwing' {
            $record = @([pscustomobject] @{ ts = '2026-08-15T09:00:00.0000000Z'; message = 'no event here' }) + @($script:midRun)

            { Get-HDTDeploymentProgress -Record $record } | Should -Not -Throw
        }

        It 'never reports more than 100 percent' {
            # A resumed run can log more completions than run.start counted.
            $record = @($script:midRun) + @(1..9 | ForEach-Object {
                    New-HDTProgressRecord -Event 'step.complete' -Second (100 + $_) -StepIndex $_ -Data @{ index = $_ }
                })

            [int] (Get-HDTDeploymentProgress -Record $record).PercentComplete | Should -BeLessOrEqual 100
        }
    }
}
