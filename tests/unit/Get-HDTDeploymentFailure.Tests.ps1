# WHAT A TECHNICIAN IS TOLD WHEN A DEPLOYMENT FAILS.
#
# A machine that failed used to print a FATAL line into a console nobody was
# looking at and power itself off five seconds later. Everything needed to fix
# it was in the log, on a share, under a folder named after a computer that no
# longer exists - and the person standing in front of the machine had a black
# screen and a shrug. MDT shows a summary dialog naming the step that failed;
# this is the derivation behind HDT's.
#
# IT IS PURE, LIKE Get-HDTDeploymentProgress AND FOR THE SAME REASON: no window,
# no runspace, no file system, so what a technician reads can be asserted on a
# machine with no display.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTFailureRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [string] $Event,
            [Parameter()] [int] $Second = 0,
            [Parameter()] [AllowNull()] [hashtable] $Data,
            [Parameter()] [int] $StepIndex = 0,
            [Parameter()] [AllowEmptyString()] [string] $StepName = '',
            [Parameter()] [AllowEmptyString()] [string] $StepType = '',
            [Parameter()] [AllowEmptyString()] [string] $Message = ''
        )

        $record = [ordered] @{
            ts        = ([datetime]::new(2026, 8, 18, 9, 0, 0, [System.DateTimeKind]::Utc)).AddSeconds($Second).ToString('o')
            runId     = 'run-20260818-090000'
            seq       = $Second + 1
            level     = 'Info'
            phase     = 'WinPE'
            component = 'Engine'
            event     = $Event
            message   = $Message
        }

        if ($StepIndex -gt 0) {
            $record['stepIndex'] = $StepIndex
            $record['stepName'] = $StepName
            $record['stepType'] = $StepType
        }

        if ($null -ne $Data) { $record['data'] = $Data }

        return [pscustomobject] $record
    }

    # THE REAL SHAPE, off a real VM run: the Validate step refusing a disk that
    # already carries Windows.
    $script:refusal = @'
this machine did not pass the pre-flight:
  - no disk on this machine can be used as the deployment target:
  - disk 0 carries existing data on volume C (NTFS), D (NTFS), and the step did not declare that it may be replaced
'@

    $script:failedRun = @(
        New-HDTFailureRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepCount = 12 } -Message 'run started'
        New-HDTFailureRecord -Event 'step.start' -Second 2 -StepIndex 1 -StepName 'Validate' -StepType 'Validate' `
            -Data @{ index = 1; name = 'Validate'; type = 'Validate' } -Message "step 1 'Validate' (Validate) starting, attempt 1 of 1"
        New-HDTFailureRecord -Event 'step.fail' -Second 4 -StepIndex 1 -StepName 'Validate' -StepType 'Validate' `
            -Data @{ index = 1; attempt = 1 } -Message $script:refusal
        New-HDTFailureRecord -Event 'run.end' -Second 5 -Data @{ status = 'Failed' } -Message 'Run ended Failed'
    )
}

Describe 'Get-HDTDeploymentFailure' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTDeploymentFailure' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a run that failed on a step' {

        It 'names the step that failed' {
            $failure = Get-HDTDeploymentFailure -Record $script:failedRun

            [string] $failure.StepName | Should -BeExactly 'Validate'
            [int] $failure.StepNumber | Should -Be 1
        }

        It 'carries the step type, because two steps can share a name' {
            [string] (Get-HDTDeploymentFailure -Record $script:failedRun).StepType | Should -BeExactly 'Validate'
        }

        It 'carries the reason exactly as the step gave it' {
            # THE REFUSAL IS THE MOST USEFUL SENTENCE ON THE SCREEN and it is
            # not summarised, shortened or rewritten: "the step did not declare
            # that it may be replaced" is the fix, stated.
            [string] (Get-HDTDeploymentFailure -Record $script:failedRun).Message |
                Should -BeLike '*did not declare that it may be replaced*'
        }

        It 'says which sequence was running' {
            [string] (Get-HDTDeploymentFailure -Record $script:failedRun).SequenceId | Should -BeExactly 'STD-CLIENT'
        }

        It 'says how far it got' {
            $failure = Get-HDTDeploymentFailure -Record $script:failedRun

            [int] $failure.StepCount | Should -Be 12
            [string] $failure.Status | Should -BeExactly 'Failed'
        }

        It 'reports the run id, which names the log folder' {
            [string] (Get-HDTDeploymentFailure -Record $script:failedRun).RunId | Should -BeExactly 'run-20260818-090000'
        }

        It 'is a failure' {
            (Get-HDTDeploymentFailure -Record $script:failedRun).IsFailure | Should -BeTrue
        }
    }

    Context 'a run that did not fail' {

        It 'is not a failure when every step completed' {
            $record = @(
                New-HDTFailureRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepCount = 2 }
                New-HDTFailureRecord -Event 'step.complete' -Second 2 -StepIndex 1 -Data @{ index = 1 }
                New-HDTFailureRecord -Event 'run.end' -Second 3 -Data @{ status = 'Succeeded' }
            )

            (Get-HDTDeploymentFailure -Record $record).IsFailure | Should -BeFalse
        }

        It 'is not a failure for an empty log' {
            (Get-HDTDeploymentFailure -Record @()).IsFailure | Should -BeFalse
        }
    }

    Context 'a run that died before any step' {

        It 'still reports the failure when the loop itself failed' {
            # A share that could not be reached, a sequence that would not
            # parse: there is no step to name and the technician still needs
            # the sentence.
            $record = @(
                New-HDTFailureRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'STD-CLIENT'; stepCount = 0 }
                New-HDTFailureRecord -Event 'step.fail' -Second 1 -Message 'the sequence document could not be read'
            )

            $failure = Get-HDTDeploymentFailure -Record $record

            $failure.IsFailure | Should -BeTrue
            [string] $failure.Message | Should -BeExactly 'the sequence document could not be read'
            [string] $failure.StepName | Should -BeExactly ''
        }
    }

    Context 'where to look next' {

        It 'carries the log path it was given' {
            # The screen has to say where the evidence is, because the machine
            # is about to be powered off and the RAM disk goes with it.
            $failure = Get-HDTDeploymentFailure -Record $script:failedRun -LogPath 'X:\HDT\Logs'

            [string] $failure.LogPath | Should -BeExactly 'X:\HDT\Logs'
        }

        It 'survives having no log path at all' {
            [string] (Get-HDTDeploymentFailure -Record $script:failedRun).LogPath | Should -BeExactly ''
        }
    }

    Context 'the fields the window shows' {

        It 'hands over one field per control the failure page names' {
            $field = @((Get-HDTDeploymentFailure -Record $script:failedRun -LogPath 'X:\HDT\Logs').Field)

            @($field | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDTFailureStepText'
            @($field | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDTFailureMessageText'
            @($field | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDTFailureLogText'
        }

        It 'puts the step number and name on the step line' {
            $field = @((Get-HDTDeploymentFailure -Record $script:failedRun).Field |
                    Where-Object { $_.Name -eq 'HDTFailureStepText' })

            [string] $field[0].Text | Should -BeLike '*Validate*'
            [string] $field[0].Text | Should -BeLike '*1 of 12*'
        }
    }
}
