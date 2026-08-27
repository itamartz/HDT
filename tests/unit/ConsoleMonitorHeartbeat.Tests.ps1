# WHEN THE MACHINE LAST SPOKE, AS A TIME RATHER THAN AN AGE.
#
# The detail pane's 'Last heartbeat' said '1h 3m' - the same relative age the
# tree row already carries a few pixels above it. Two renderings of one fact,
# and neither of them the one somebody writes in a ticket or lines up against a
# log. A technician reading a stalled deployment wants to know WHEN it stopped,
# because that is what they compare against everything else that happened on
# that machine.
#
# THE ROW KEEPS THE AGE AND THE FIELD TAKES THE TIME. They answer different
# questions: the row is scanned - 'is this one still moving?' - and the field is
# read. Nothing is lost by splitting them, and the pane stops repeating the row.
#
# LOCAL TIME, AND A FORMAT WITH NO CULTURE IN IT. The heartbeat is written and
# stored in UTC, but the console runs on somebody's desk and they are comparing
# it to their own clock. The format is fixed rather than culture-dependent: this
# file's neighbour records three hours lost to a [string] cast that rendered a
# DateTime in the current culture and then parsed it back as a round-trip
# stamp, and 'dd/MM' against 'MM/dd' is the same trap wearing a hat.
#
# AND A STAMP FROM THE FUTURE IS SHOWN AS IT IS. Nothing syncs a clock in
# WinPE, so a live deployment can be hours ahead of the console. The AGE clamps
# to zero for that, deliberately - 'in 8 hours' helps nobody decide whether a
# machine is alive - but the TIME must not be clamped or corrected, because an
# absolute stamp that disagrees with the wall clock is the only thing on this
# screen that makes the skew visible at all. It cost an afternoon once.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
            -Force -ErrorAction Stop

        # 2026-08-15 22:00:30 UTC, ninety seconds after the heartbeat below.
        $script:now = [datetime]::SpecifyKind(
            [datetime]::new(2026, 8, 15, 22, 0, 30), [System.DateTimeKind]::Utc)

        $script:stampUtc = [datetime]::SpecifyKind(
            [datetime]::new(2026, 8, 15, 21, 59, 0), [System.DateTimeKind]::Utc)

        # WHAT THE HOST'S OWN CLOCK CALLS THAT MOMENT. Computed rather than
        # written down, because this suite runs on a laptop in one zone and on
        # OSDTEST01 in whatever zone it is set to.
        $script:expectLocal = $script:stampUtc.ToLocalTime().ToString(
            'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

        function New-HDTTestHeartbeat {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test double; it changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter()] [AllowNull()] [object] $Updated = '2026-08-15T21:59:00.0000000Z',
                [Parameter()] [string] $Status = 'Running')

            $document = [ordered] @{
                schemaVersion = 1
                runId         = 'RUN-1'
                phase         = 'WinPE'
                status        = $Status
                stepIndex     = 3
                stepCount     = 12
                stepName      = 'Apply OS'
                stepType      = 'ApplyImage'
            }

            if ($null -ne $Updated) { $document['updated'] = $Updated }

            return New-HDTConsoleMonitorRow -RunId 'RUN-1' -Path 'C:\ws\Logs\_active\RUN-1.json' `
                -Document (ConvertFrom-Json -InputObject (ConvertTo-Json -Depth 4 -InputObject $document)) `
                -Now $script:now -StaleMinute 20
        }
    }

    Describe 'the last heartbeat as a time' {

        It 'renders the stamp as a wall-clock time, not a duration' {
            (New-HDTTestHeartbeat).UpdatedText | Should -BeExactly $script:expectLocal
        }

        It 'uses a format that reads the same in every culture' {
            # yyyy-MM-dd HH:mm:ss - sortable, and no argument about which number
            # is the month.
            (New-HDTTestHeartbeat).UpdatedText |
                Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }

        It 'shows the local time, not UTC, because the console is on somebody''s desk' {
            # THE SKIP IS DECIDED HERE, NOT IN -Skip:. A -Skip: expression is
            # evaluated during DISCOVERY, before any BeforeAll has run, so it
            # would read $script:stampUtc as unset and take the whole file down
            # with it.
            $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($script:stampUtc)

            if ($offset -eq [timespan]::Zero) {
                Set-ItResult -Skipped -Because 'this host is at UTC, so there is nothing to tell apart'
                return
            }

            (New-HDTTestHeartbeat).UpdatedText |
                Should -Not -BeExactly $script:stampUtc.ToString(
                    'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        }

        It 'still keeps the age, which is what the tree row is scanned for' {
            $row = New-HDTTestHeartbeat

            $row.SinceText | Should -BeExactly '1m 30s'
            $row.Text | Should -BeLike '*1m 30s ago*'
        }

        It 'says nothing rather than a wrong time when no stamp was written' {
            $row = New-HDTTestHeartbeat -Updated $null

            $row.UpdatedText | Should -BeNullOrEmpty
            $row.Health | Should -BeExactly 'Unreadable'
        }

        It 'says nothing when the stamp was there but unreadable' {
            (New-HDTTestHeartbeat -Updated 'the day before yesterday').UpdatedText |
                Should -BeNullOrEmpty
        }

        # THE WinPE CLOCK. This is the case the absolute time exists for.
        Context 'a machine whose clock is hours ahead' {

            BeforeAll {
                $script:aheadUtc = $script:now.AddHours(8)
                $script:ahead = New-HDTTestHeartbeat -Updated (
                    $script:aheadUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture))
            }

            It 'shows the time it actually claims, so the skew is visible' {
                $script:ahead.UpdatedText | Should -BeExactly (
                    $script:aheadUtc.ToLocalTime().ToString(
                        'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))
            }

            It 'still clamps the AGE to zero, so it is not branded stale' {
                $script:ahead.SinceSecond | Should -Be 0
                $script:ahead.Health | Should -BeExactly 'Live'
            }
        }
    }

    Describe 'the Last heartbeat field on the detail pane' {

        BeforeAll {
            $script:activePath = 'C:\ws\Logs\_active'

            $script:node = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Header ([pscustomobject] @{
                    Title = 'HDT'; Root = 'C:\ws'; DeployRoot = '\\host\share'
                }) -FileSystem (New-HDTFakeFileSystem -Directory @($script:activePath) -File @{
                    'C:\ws\Logs\_active\RUN-1.json' = (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                                schemaVersion = 1
                                runId         = 'RUN-1'
                                phase         = 'WinPE'
                                status        = 'Running'
                                stepIndex     = 3
                                stepCount     = 12
                                stepName      = 'Apply OS'
                                stepType      = 'ApplyImage'
                                updated       = '2026-08-15T21:59:00.0000000Z'
                            }))
                }) -Clock (New-HDTFakeClock -UtcNow $script:now)

            $script:field = @(@($script:node.Children)[0].Field)
        }

        It 'carries the time, not the duration' {
            $value = @($script:field | Where-Object { $_.Label -eq 'Last heartbeat' })[0].Value

            $value | Should -BeExactly $script:expectLocal
            $value | Should -Not -BeLike '*ago*'
            $value | Should -Not -BeLike '*1m 30s*'
        }

        It 'still falls back to (never) when there is no time to show' {
            $node = Get-HDTConsoleMonitorNode -Path 'C:\ws' -Header ([pscustomobject] @{
                    Title = 'HDT'; Root = 'C:\ws'; DeployRoot = '\\host\share'
                }) -FileSystem (New-HDTFakeFileSystem -Directory @($script:activePath) -File @{
                    'C:\ws\Logs\_active\RUN-2.json' = (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                                schemaVersion = 1
                                runId         = 'RUN-2'
                                status        = 'Running'
                            }))
                }) -Clock (New-HDTFakeClock -UtcNow $script:now)

            @(@($node.Children)[0].Field | Where-Object { $_.Label -eq 'Last heartbeat' })[0].Value |
                Should -BeExactly '(never)'
        }
    }
}
