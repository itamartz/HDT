# WHAT A MONITORED RUN'S Health ACTUALLY IS.
#
# THE BUG THIS FILE EXISTS FOR. Health was decided by one test - "is the status
# the literal string 'Running'?" - and everything else was called Finished. The
# engine writes FOUR statuses (Invoke-HDTTaskSequence): Running, RebootPending,
# Succeeded and Failed. So three different things collapsed into one green tick:
#
#   - a run waiting to REBOOT read as Finished, halfway through its sequence.
#     Spotted on a live deployment sitting at 'Finished' on step 9 of 12;
#   - a run that FAILED read as Finished, with a green tick and no warning -
#     invisible on the one screen built to surface it;
#   - a run that SUCCEEDED read as Finished, which is the only one that was
#     right.
#
# A VERDICT IS NOT AGED, AND A RUN IN FLIGHT IS. Succeeded and Failed are
# terminal: a completed heartbeat is not a heartbeat that stopped, and ageing
# one into a red row teaches a technician to ignore red. Running and
# RebootPending are the opposite - they are claims that something is still
# happening, so if nothing has been written for the stale window, the claim is
# what has gone wrong and the row must say Stalled. A machine that rebooted and
# never came back is precisely the failure this screen is for.
#
# AN UNKNOWN STATUS DOES NOT GET TO CLAIM SUCCESS. Anything this console does
# not recognise is treated as still in flight and left to the stale rule. Being
# wrong about "still going" costs a second look; being wrong about "finished"
# costs a machine nobody goes back to.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
            -Force -ErrorAction Stop

        $script:now = [datetime]::SpecifyKind(
            [datetime]::new(2026, 8, 15, 22, 0, 30), [System.DateTimeKind]::Utc)

        # Ninety seconds old - well inside the stale window.
        $script:fresh = '2026-08-15T21:59:00.0000000Z'

        # Over an hour old - well outside a twenty minute one.
        $script:old = '2026-08-15T20:30:00.0000000Z'

        function New-HDTTestHealthRow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test double; it changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter()] [AllowEmptyString()] [string] $Status = 'Running',
                [Parameter()] [AllowNull()] [object] $Updated = $script:fresh)

            $document = [ordered] @{
                schemaVersion = 1
                runId         = 'RUN-1'
                phase         = 'WinPE'
                status        = $Status
                stepIndex     = 9
                stepCount     = 12
                stepName      = 'Restart into Windows'
                stepType      = 'Restart'
            }

            if ($null -ne $Updated) { $document['updated'] = $Updated }

            return New-HDTConsoleMonitorRow -RunId 'RUN-1' -Path 'C:\ws\Logs\_active\RUN-1.json' `
                -Document (ConvertFrom-Json -InputObject (ConvertTo-Json -Depth 4 -InputObject $document)) `
                -Now $script:now -StaleMinute 20
        }
    }

    Describe 'the Health of a monitored run' {

        It 'calls a <Status> run <Expected>' -ForEach @(
            @{ Status = 'Running'; Expected = 'Live' }
            @{ Status = 'RebootPending'; Expected = 'Rebooting' }
            @{ Status = 'Succeeded'; Expected = 'Finished' }
            @{ Status = 'Failed'; Expected = 'Failed' }
        ) {
            (New-HDTTestHealthRow -Status $Status).Health | Should -BeExactly $Expected
        }

        # THE ONE THE REPORT WAS ABOUT.
        It 'does not call a run waiting to reboot finished' {
            # Seen at 'Finished' on step 9 of 12, with the machine about to
            # restart and carry on.
            (New-HDTTestHealthRow -Status 'RebootPending').Health | Should -Not -BeExactly 'Finished'
        }

        # THE ONE THAT MATTERED MORE.
        It 'does not call a failed run finished' {
            (New-HDTTestHealthRow -Status 'Failed').Health | Should -Not -BeExactly 'Finished'
        }

        It 'treats a status it does not know as still in flight, never as finished' {
            $row = New-HDTTestHealthRow -Status 'Frobnicating'

            $row.Health | Should -Not -BeExactly 'Finished'
            $row.Health | Should -BeExactly 'Live'
        }

        It 'treats a blank status as still in flight, for a heartbeat from an older engine' {
            (New-HDTTestHealthRow -Status '').Health | Should -BeExactly 'Live'
        }
    }

    Describe 'what ages and what does not' {

        It 'ages a <Status> run that has gone quiet into <Expected>' -ForEach @(
            @{ Status = 'Running'; Expected = 'Stalled' }
            # A MACHINE THAT REBOOTED AND NEVER CAME BACK is the failure this
            # screen exists for, so this one ages too.
            @{ Status = 'RebootPending'; Expected = 'Stalled' }
        ) {
            (New-HDTTestHealthRow -Status $Status -Updated $script:old).Health |
                Should -BeExactly $Expected
        }

        It 'never ages a <Status> run, because a verdict is not a heartbeat that stopped' -ForEach @(
            @{ Status = 'Succeeded'; Expected = 'Finished' }
            @{ Status = 'Failed'; Expected = 'Failed' }
        ) {
            (New-HDTTestHealthRow -Status $Status -Updated $script:old).Health |
                Should -BeExactly $Expected
        }

        It 'still says Failed when a failed run carried no readable timestamp' {
            # The verdict is known even when the clock is not. Unreadable would
            # throw away the one fact that matters.
            (New-HDTTestHealthRow -Status 'Failed' -Updated $null).Health |
                Should -BeExactly 'Failed'
        }

        It 'says Unreadable when a run in flight carried no readable timestamp' {
            (New-HDTTestHealthRow -Status 'Running' -Updated $null).Health |
                Should -BeExactly 'Unreadable'
        }
    }

    Describe 'how the row is drawn' {

        It 'gives <Status> its own glyph' -ForEach @(
            @{ Status = 'Running' }
            @{ Status = 'RebootPending' }
            @{ Status = 'Succeeded' }
            @{ Status = 'Failed' }
        ) {
            (New-HDTTestHealthRow -Status $Status).Icon | Should -Not -BeNullOrEmpty
        }

        It 'does not draw a failed run with the same glyph as a successful one' {
            (New-HDTTestHealthRow -Status 'Failed').Icon |
                Should -Not -BeExactly (New-HDTTestHealthRow -Status 'Succeeded').Icon
        }

        It 'does not draw a rebooting run with the same glyph as a finished one' {
            (New-HDTTestHealthRow -Status 'RebootPending').Icon |
                Should -Not -BeExactly (New-HDTTestHealthRow -Status 'Succeeded').Icon
        }
    }

    Describe 'the tree row a failed run gets' {

        BeforeAll {
            $script:activePath = 'C:\ws\Logs\_active'

            $script:failedNode = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Header ([pscustomobject] @{
                    Title = 'HDT'; Root = 'C:\ws'; DeployRoot = '\\host\share'
                }) -FileSystem (New-HDTFakeFileSystem -Directory @($script:activePath) -File @{
                    'C:\ws\Logs\_active\RUN-BAD.json' = (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                                schemaVersion = 1
                                runId         = 'RUN-BAD'
                                phase         = 'FullOS'
                                status        = 'Failed'
                                stepIndex     = 9
                                stepCount     = 12
                                stepName      = 'Install Applications'
                                stepType      = 'InstallApplications'
                                updated       = '2026-08-15T21:59:00.0000000Z'
                            }))
                }) -Clock (New-HDTFakeClock -UtcNow $script:now)
        }

        # A FAILURE HAS TO LOOK LIKE ONE. It was drawn 'Ok' - the same green as
        # a machine that deployed perfectly.
        It 'is drawn as an error, like everything else that is wrong' {
            @($script:failedNode.Children)[0].Status | Should -BeExactly 'Error'
        }

        It 'says Failed in the detail pane' {
            @(@($script:failedNode.Children)[0].Field |
                    Where-Object { $_.Label -eq 'Health' })[0].Value | Should -BeExactly 'Failed'
        }

        It 'counts the failure in the category caption instead of calling it finished' {
            $script:failedNode.Text | Should -BeLike '*failed*'
            $script:failedNode.Text | Should -Not -BeLike '*1 finished*'
        }
    }

    Describe 'Get-HDTConsoleMonitorSummary' {

        It 'leads with the failures, because that is what somebody is looking for' {
            Get-HDTConsoleMonitorSummary -Live 3 -Stalled 0 -Finished 2 -Unreadable 0 `
                -Failed 1 -Rebooting 0 | Should -BeLike '1 failed*'
        }

        It 'names a rebooting run as its own thing' {
            Get-HDTConsoleMonitorSummary -Live 0 -Stalled 0 -Finished 0 -Unreadable 0 `
                -Failed 0 -Rebooting 2 | Should -BeLike '*2 rebooting*'
        }

        It 'still says nothing is running on an empty share' {
            Get-HDTConsoleMonitorSummary -Live 0 -Stalled 0 -Finished 0 -Unreadable 0 `
                -Failed 0 -Rebooting 0 |
                Should -BeExactly 'There is no deployment running on this share.'
        }

        It 'still captions an empty share with the bare word' {
            Get-HDTConsoleMonitorSummary -Live 0 -Stalled 0 -Finished 0 -Unreadable 0 `
                -Failed 0 -Rebooting 0 -Caption | Should -BeExactly 'Monitoring'
        }
    }
}
