# THE LAST HEARTBEAT A RUN WRITES THREW AWAY WHERE IT GOT TO.
#
# The engine calls SetStep before each step and ClearStep after it, and
# Write-HDTStatus reads the step off the context. The verdict is written AFTER
# the loop - so by then the context has been cleared, and the final heartbeat
# said stepIndex 0 with no name at all.
#
# WHAT THAT LOOKED LIKE ON THE CONSOLE. A deployment that ran all twelve steps
# and succeeded was drawn:
#
#     run-20260827-202800 - (no step yet)   (3m 34s ago)
#     Step number:  0 of 12
#
# "(no step yet)" on a finished deployment, and a step count that counts to
# nothing. Worse on a FAILURE, where the one thing anybody opens the Monitoring
# node to find out - WHICH step it died on - was the single fact the last write
# discarded.
#
# SO THE VERDICT CARRIES ITS STEP EXPLICITLY. The overrides exist because the
# context is the wrong place to keep this: ClearStep is correct - a step that
# has ended is not the current step, and the logger must not tag later records
# with it - so the caller that knows the run is over passes what it reached.
#
# UNSUPPLIED IS NOT THE SAME AS ZERO. Every per-step heartbeat still reads the
# context, which is what keeps a live run's row moving, so these must not
# override anything unless a caller actually asked.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:statusPath = 'X:\HDT\Logs\status.json'

    function Get-HDTTestStatusDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [object] $FileSystem)

        return ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText($script:statusPath))
    }
}

Describe 'Write-HDTStatus, naming the step a finished run reached' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 17, 34, 51, [System.DateTimeKind]::Utc))
        $script:context = New-HDTLogContext -RunId 'run-1' -Phase FullOS -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock

        $script:context.SetStep(12, 'Install Applications', 'InstallApplications', $null)
        $script:context.StepCount = 12

        # WHAT THE ENGINE DOES BEFORE IT WRITES THE VERDICT. The step is over,
        # so the context no longer names one.
        $script:context.ClearStep()
    }

    It 'reports the step it was told about rather than the cleared context' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Succeeded' `
            -StepIndex 12 -StepName 'Install Applications' -StepType 'InstallApplications'

        $document = Get-HDTTestStatusDocument -FileSystem $script:fs

        $document.stepIndex | Should -Be 12
        $document.stepName | Should -BeExactly 'Install Applications'
        $document.stepType | Should -BeExactly 'InstallApplications'
    }

    It 'writes the verdict it was given alongside it' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Succeeded' `
            -StepIndex 12 -StepName 'Install Applications' -StepType 'InstallApplications'

        (Get-HDTTestStatusDocument -FileSystem $script:fs).status | Should -BeExactly 'Succeeded'
    }

    # THE ONE THE MONITORING NODE IS OPENED FOR.
    It 'names the step a failed run died on' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Failed' `
            -StepIndex 9 -StepName 'Restart into Windows' -StepType 'Restart'

        $document = Get-HDTTestStatusDocument -FileSystem $script:fs

        $document.status | Should -BeExactly 'Failed'
        $document.stepIndex | Should -Be 9
        $document.stepName | Should -BeExactly 'Restart into Windows'
    }

    It 'mirrors the overridden step to the share too, not just locally' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Succeeded' `
            -StepIndex 12 -StepName 'Install Applications' -StepType 'InstallApplications' `
            -ActivePath '\\host\HDTShare\Logs\_active\run-1.json'

        (ConvertFrom-Json -InputObject ([string] $script:fs.ReadAllText(
                    '\\host\HDTShare\Logs\_active\run-1.json'))).stepIndex | Should -Be 12
    }

    Context 'when no override is given' {

        It 'still reads the step off the context, which is what a live row moves on' {
            $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)

            Write-HDTStatus -Context $script:context -Path $script:statusPath

            $document = Get-HDTTestStatusDocument -FileSystem $script:fs

            $document.stepIndex | Should -Be 3
            $document.stepName | Should -BeExactly 'Apply OS'
        }

        It 'still reports a cleared context as nothing, rather than inventing a step' {
            Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Running'

            (Get-HDTTestStatusDocument -FileSystem $script:fs).stepIndex | Should -Be 0
        }
    }

    Context 'an override of zero' {

        It 'is honoured, because a run that failed before any step began reached none' {
            # UNSUPPLIED IS NOT ZERO. If this read as "not supplied" the context
            # would win, and a run that died in setup would claim a step.
            $script:context.SetStep(7, 'Apply OS', 'ApplyImage', $null)

            Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Failed' `
                -StepIndex 0 -StepName '' -StepType ''

            $document = Get-HDTTestStatusDocument -FileSystem $script:fs

            $document.stepIndex | Should -Be 0
            $document.stepName | Should -BeNullOrEmpty
        }
    }

    It 'keeps stepCount, which is not the step and does not get cleared' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Succeeded' `
            -StepIndex 12 -StepName 'Install Applications' -StepType 'InstallApplications'

        (Get-HDTTestStatusDocument -FileSystem $script:fs).stepCount | Should -Be 12
    }
}
