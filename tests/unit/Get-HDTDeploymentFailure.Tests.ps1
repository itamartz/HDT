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

# THE SAME WINDOW REPORTS A RUN THAT WORKED. MDT ends State Restore on a
# Deployment Summary that says which of the two happened; HDT ended it on
# nothing at all, so a ZTI machine that finished and a ZTI machine that failed
# looked identical to the person standing at it.
#
# ONE SCREEN, TWO STATES, rather than a second window to keep in step with this
# one - the headline is a field like every other thing on it.
Describe 'the summary for a run that succeeded' {

    BeforeAll {
        $script:goodRecord = @(
            [pscustomobject] @{ runId = 'run-20260821-140000'; event = 'run.start'
                data = [pscustomobject] @{ sequenceId = 'DEMO-05'; stepCount = 11 } }
            [pscustomobject] @{ runId = 'run-20260821-140000'; event = 'run.end'
                data = [pscustomobject] @{ status = 'Succeeded' } }
        )

        $script:good = Get-HDTDeploymentFailure -Record $script:goodRecord -LogPath '\host\HDTShare\Logs'
    }

    It 'does not call it a failure' {
        $script:good.IsFailure | Should -BeFalse
        $script:good.Status | Should -BeExactly 'Succeeded'
    }

    It 'shows the success headline and hides the failure one' {
        # NOT A FIELD. A Field sets text and cannot set a colour, and the
        # failure headline is painted #FFF48771 in the markup - red only ever
        # means wrong, so a success must not be written into it.
        $visible = @($script:good.Pane | Where-Object { $_.Visible } | ForEach-Object { $_.Name })

        $visible | Should -Contain 'HDTFailureSuccessText'
        $visible | Should -Not -Contain 'HDTFailureTitleText'
    }

    It 'hides the reason box, which has nothing to say' {
        $visible = @($script:good.Pane | Where-Object { $_.Visible } | ForEach-Object { $_.Name })

        $visible | Should -Not -Contain 'HDTFailureReasonLabel'
        $visible | Should -Not -Contain 'HDTFailureReasonBox'
    }

    It 'names the steps it got through instead of the step it died on' {
        $step = @($script:good.Field | Where-Object { $_.Name -eq 'HDTFailureStepText' })[0]

        $step.Text | Should -Not -Match '(?i)before the first step'
        $step.Text | Should -Match '11'
    }

    It 'leaves a failure the window it always had' {
        $bad = Get-HDTDeploymentFailure -Record @(
            [pscustomobject] @{ runId = 'r'; event = 'run.end'; data = [pscustomobject] @{ status = 'Failed' } }
        ) -LogPath 'C:\HDT\Logs'

        $visible = @($bad.Pane | Where-Object { $_.Visible } | ForEach-Object { $_.Name })

        $visible | Should -Contain 'HDTFailureTitleText'
        $visible | Should -Contain 'HDTFailureReasonBox'
        $visible | Should -Not -Contain 'HDTFailureSuccessText'
    }
}

# A LEG THAT NEVER REACHED A STEP HAS NO RECORDS TO DERIVE A FAILURE FROM, and
# it is the case that most needs the screen.
#
# Watched on 2026-08-21. The full-OS leg resumed, could not open
# \192.168.2.42\HDTShare - the machine had been handed the host's own address
# by DHCP - so the workspace root stayed C:\HDT, Import-HDTSequenceDocument
# threw on a sequence that is not there, and the payload died at script scope
# under ErrorActionPreference = 'Stop'. The summary block sits BELOW the loop,
# so it never ran: no window, and no log line either, because the run log
# context is built after the import that threw.
#
# THE PAYLOAD NOW CATCHES THAT AND STILL DRAWS THE SCREEN, which means this
# command has to fill one from a sentence alone. The DESCRIPTION already
# promised it - "a run that died before any step is still a failure with a
# sentence" - and only delivered when a step.fail record existed to carry it.
Describe 'the summary for a leg that never reached a step' {

    It 'takes the reason as a parameter' {
        $parameter = (Get-Command -Name Get-HDTDeploymentFailure).Parameters

        $parameter.ContainsKey('Reason') | Should -BeTrue
    }

    It 'reports a failure from the reason alone, with no records at all' {
        $failure = Get-HDTDeploymentFailure -Record @() -Reason 'the deployment share could not be reached'

        $failure.IsFailure | Should -BeTrue
        [string] $failure.Status | Should -BeExactly 'Failed'
        [string] $failure.Message | Should -BeExactly 'the deployment share could not be reached'
    }

    It 'shows the failure headline rather than the success one' {
        # WITHOUT THIS THE SCREEN LIES. An empty record set leaves Status empty,
        # $succeeded false and IsFailure false - which draws the window with
        # neither headline and an empty reason box, under a green heading on any
        # path that checks Status alone.
        $pane = @((Get-HDTDeploymentFailure -Record @() -Reason 'no share').Pane)

        [bool] (@($pane | Where-Object { $_.Name -eq 'HDTFailureTitleText' })[0].Visible) | Should -BeTrue
        [bool] (@($pane | Where-Object { $_.Name -eq 'HDTFailureSuccessText' })[0].Visible) | Should -BeFalse
        [bool] (@($pane | Where-Object { $_.Name -eq 'HDTFailureReasonBox' })[0].Visible) | Should -BeTrue
    }

    It 'says the run never reached a step rather than naming one' {
        $field = @((Get-HDTDeploymentFailure -Record @() -Reason 'no share').Field |
                Where-Object { $_.Name -eq 'HDTFailureStepText' })

        [string] $field[0].Text | Should -BeExactly 'before the first step'
    }

    It 'puts the reason where the window reads its message from' {
        $field = @((Get-HDTDeploymentFailure -Record @() -Reason "  the network path was not found  ").Field |
                Where-Object { $_.Name -eq 'HDTFailureMessageText' })

        [string] $field[0].Text | Should -BeExactly 'the network path was not found'
    }

    It 'keeps whatever the records could still tell it' {
        # The boot log has a run id even when the run never started, and the
        # technician needs it to find the log on the share.
        $record = @(New-HDTFailureRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'DEMO-05'; stepCount = 10 })

        $failure = Get-HDTDeploymentFailure -Record $record -Reason 'no share' -LogPath 'C:\HDT\Logs'

        [string] $failure.RunId | Should -BeExactly 'run-20260818-090000'
        [string] $failure.SequenceId | Should -BeExactly 'DEMO-05'
        [string] $failure.LogPath | Should -BeExactly 'C:\HDT\Logs'
    }

    It 'defers to the sentence the step itself wrote' {
        # BOTH PAYLOADS PASS A REASON ON EVERY FAILING RUN, not only the ones
        # that died early - so a reason that overwrote the message would put the
        # payload's second-hand account on screen in place of the step's own,
        # which is the one that contains the fix.
        $failure = Get-HDTDeploymentFailure -Record $script:failedRun -Reason 'the sequence document could not be read'

        [string] $failure.Message | Should -BeExactly $script:refusal.Trim()
        $failure.IsFailure | Should -BeTrue
    }

    It 'forces the failure even when the records described none' {
        # A run.start with no step.fail and no run.end - a leg that got a log
        # context and then died outside the loop. Without this the window opens
        # under a green headline on a machine that failed.
        $record = @(New-HDTFailureRecord -Event 'run.start' -Second 0 -Data @{ sequenceId = 'DEMO-05'; stepCount = 10 })

        $failure = Get-HDTDeploymentFailure -Record $record -Reason 'the deployment share could not be reached'

        $failure.IsFailure | Should -BeTrue
        [string] $failure.Message | Should -BeExactly 'the deployment share could not be reached'
    }

    It 'changes nothing when no reason is given' {
        $failure = Get-HDTDeploymentFailure -Record @()

        $failure.IsFailure | Should -BeFalse
        [string] $failure.Message | Should -BeExactly ''
    }

    It 'treats an empty reason as no reason' {
        (Get-HDTDeploymentFailure -Record @() -Reason '   ').IsFailure | Should -BeFalse
    }
}
