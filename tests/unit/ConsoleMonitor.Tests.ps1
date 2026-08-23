# The monitoring view: which deployments are in flight, and where they have got to.
#
# ROADMAP M8: "Monitoring view tailing Logs\_active\". DESIGN 12: "tails
# Logs\_active\, showing in-flight deployments, current step, and elapsed time;
# opens the full report on completion". DESIGN 4.4.6 is the other half of the
# same decision: "The engine writes a small status.json heartbeat to
# <share>\Logs\_active\<RunId>.json each step. The console tails that directory.
# No web service, no SQL, no MDT Monitoring dependency."
#
# SO THE WHOLE FEATURE IS A DIRECTORY LISTING AND SOME ARITHMETIC, and both
# belong in a command. The window will re-run this on a timer and assign what
# comes back; it works nothing out, which is what keeps it exempt from TDD.
#
# ELAPSED TIME NEEDS A CLOCK, AND THE CLOCK IS INJECTED. "How long has this been
# running" is the one number on this screen that changes without anything being
# written, and a command that read the wall clock could only be tested by
# sleeping. IClockService is the engine's own, so the console measures time the
# same way the deployment writing these files does.
#
# A HEARTBEAT THAT STOPPED IS THE POINT OF THE SCREEN. A deployment that died -
# power, network, a bugcheck - leaves its last heartbeat behind and never writes
# another. Nothing else in HDT will ever notice; this is where it shows.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\ws'
    $script:activePath = 'C:\ws\Logs\_active'

    # THE INSTANT IS BUILT WITH ITS KIND, NOT PARSED FROM A STRING.
    # [datetime]::Parse('2026-08-15T22:00:00Z') returns a LOCAL time, and the
    # fake clock hands back whatever it was seeded with - so on this host, three
    # hours east of UTC, every age in this file came out three hours too large
    # and the failures pointed at the cmdlet rather than at the seed. Built this
    # way the fixture means the same thing in every time zone, which is also the
    # only way these tests pass on a machine that is not this one.
    $script:now = [datetime]::new(2026, 8, 15, 22, 0, 0, [System.DateTimeKind]::Utc)

    # THE SHAPE IS Write-HDTStatus'S, not one invented here. If that document
    # changes, this fixture is wrong in the same way the console would be.
    function New-HDTTestHeartbeat {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Returns a JSON string in memory; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)] [string] $RunId,
            [Parameter(Mandatory = $true)] [string] $Updated,
            [Parameter()] [string] $Phase = 'WinPE',
            [Parameter()] [string] $Status = 'Running',
            [Parameter()] [int] $StepIndex = 3,
            [Parameter()] [int] $StepCount = 12,
            [Parameter()] [string] $StepName = 'Apply OS',
            [Parameter()] [string] $StepType = 'ApplyImage'
        )

        return (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                    schemaVersion = 1
                    runId         = $RunId
                    phase         = $Phase
                    status        = $Status
                    stepIndex     = $StepIndex
                    stepCount     = $StepCount
                    stepName      = $StepName
                    stepType      = $StepType
                    updated       = $Updated
                }))
    }

    function New-HDTTestMonitorFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [hashtable] $File = @{})

        $content = @{}
        foreach ($key in $File.Keys) { $content[$key] = $File[$key] }

        # The directory must exist even when it holds nothing - a share that has
        # never run a deployment still has the folder.
        return New-HDTFakeFileSystem -File $content -Directory @($script:activePath)
    }
}

Describe 'Get-HDTConsoleMonitor' {

    Context 'a share with nothing running' {

        It 'returns no rows rather than failing' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            @($monitor.Run).Count | Should -Be 0
            $monitor.Status | Should -BeExactly 'Ok'
        }

        It 'says so in words, because an empty list looks like a broken screen' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Summary | Should -BeLike '*no deployment*'
        }
    }

    Context 'a share that has never had one' {

        It 'reports rather than throwing when Logs\_active\ is not there at all' {
            # A brand new share, or one whose Logs folder was cleaned out. The
            # console must open on it.
            $bare = New-HDTFakeFileSystem -File @{} -Directory @('C:\ws')

            $monitor = Get-HDTConsoleMonitor -Path $script:root -FileSystem $bare `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Status | Should -BeExactly 'Ok'
            @($monitor.Run).Count | Should -Be 0
        }
    }

    Context 'one deployment in flight' {

        BeforeAll {
            $script:monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0001.json' = (New-HDTTestHeartbeat -RunId 'RUN-0001' -Updated '2026-08-15T21:58:30.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)
        }

        It 'finds it' {
            @($script:monitor.Run).Count | Should -Be 1
            $script:monitor.Run[0].RunId | Should -BeExactly 'RUN-0001'
        }

        It 'says which step it is on, by number and by name' {
            $script:monitor.Run[0].StepIndex | Should -Be 3
            $script:monitor.Run[0].StepName | Should -BeExactly 'Apply OS'
            $script:monitor.Run[0].StepType | Should -BeExactly 'ApplyImage'
        }

        It 'says how far through the sequence it is, not only which step' {
            # "step 3" is a number nobody can act on. The count travels in the
            # heartbeat because the console is reading a share, not running a
            # sequence, and cannot work the total out for itself.
            $script:monitor.Run[0].StepCount | Should -Be 12
            $script:monitor.Run[0].StepText | Should -BeExactly '3 of 12'
        }

        It 'says what it knows when an older engine wrote no count' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-OLD.json' = (ConvertTo-Json -Depth 4 -InputObject ([ordered] @{
                                    schemaVersion = 1
                                    runId         = 'RUN-OLD'
                                    phase         = 'WinPE'
                                    status        = 'Running'
                                    stepIndex     = 3
                                    stepName      = 'Apply OS'
                                    stepType      = 'ApplyImage'
                                    updated       = '2026-08-15T21:59:00.0000000Z'
                                }))
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Run[0].StepCount | Should -Be 0
            $monitor.Run[0].StepText | Should -BeExactly '3'
        }

        It 'says which phase it is in, because that is half of where it has got to' {
            $script:monitor.Run[0].Phase | Should -BeExactly 'WinPE'
        }

        It 'works out how long since it last said anything' {
            $script:monitor.Run[0].SinceSecond | Should -Be 90
        }

        It 'renders that as something readable rather than a number of seconds' {
            $script:monitor.Run[0].SinceText | Should -BeExactly '1m 30s'
        }

        It 'calls it live, because it spoke within the last few minutes' {
            $script:monitor.Run[0].Health | Should -BeExactly 'Live'
        }

        It 'leads with the run and the step, which is what the row is for' {
            $script:monitor.Run[0].Text | Should -BeLike '*RUN-0001*'
            $script:monitor.Run[0].Text | Should -BeLike '*Apply OS*'
        }

        It 'shows the cmdlet behind the row, like every other row in this console' {
            $script:monitor.Run[0].Command | Should -BeLike '*RUN-0001.json*'
        }

        It 'counts it in the summary' {
            $script:monitor.Summary | Should -BeLike '*1*'
        }
    }

    Context 'a deployment that stopped talking' {

        It 'calls it stalled once the heartbeat is older than the threshold' {
            # DESIGN 4.4.6 has the engine write one per STEP, and a step can
            # legitimately take a while - applying an image is minutes. The
            # threshold is therefore generous and settable, not a guess baked in.
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0002.json' = (New-HDTTestHeartbeat -RunId 'RUN-0002' -Updated '2026-08-15T21:00:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Run[0].Health | Should -BeExactly 'Stalled'
            $monitor.Run[0].SinceText | Should -BeExactly '1h 0m'
        }

        It 'takes the threshold from the caller' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root -StaleMinute 120 `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0002.json' = (New-HDTTestHeartbeat -RunId 'RUN-0002' -Updated '2026-08-15T21:00:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Run[0].Health | Should -BeExactly 'Live'
        }

        It 'says so in the summary too, because that is the line somebody scans' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0002.json' = (New-HDTTestHeartbeat -RunId 'RUN-0002' -Updated '2026-08-15T21:00:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Summary | Should -BeLike '*stalled*'
        }
    }

    Context 'a run that finished' {

        It 'reads the status the engine wrote rather than inferring one' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0003.json' = (New-HDTTestHeartbeat -RunId 'RUN-0003' -Status 'Succeeded' -Updated '2026-08-15T21:59:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Run[0].RunStatus | Should -BeExactly 'Succeeded'
        }

        It 'does not call a finished run stalled, however long ago it finished' {
            # A completed heartbeat is not a heartbeat that stopped. Ageing one
            # into a red row is how a screen cries wolf.
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0003.json' = (New-HDTTestHeartbeat -RunId 'RUN-0003' -Status 'Succeeded' -Updated '2026-08-14T09:00:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            $monitor.Run[0].Health | Should -BeExactly 'Finished'
        }
    }

    Context 'several at once, which is the case the screen exists for' {

        BeforeAll {
            $script:many = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-A.json' = (New-HDTTestHeartbeat -RunId 'RUN-A' -Updated '2026-08-15T21:59:50.0000000Z')
                        'C:\ws\Logs\_active\RUN-B.json' = (New-HDTTestHeartbeat -RunId 'RUN-B' -Updated '2026-08-15T20:00:00.0000000Z')
                        'C:\ws\Logs\_active\RUN-C.json' = (New-HDTTestHeartbeat -RunId 'RUN-C' -Updated '2026-08-15T21:30:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)
        }

        It 'finds all of them' {
            @($script:many.Run).Count | Should -Be 3
        }

        It 'puts the one that spoke most recently first' {
            # A technician watching twenty machines wants the one that just moved
            # at the top, not the one whose id sorts first.
            @($script:many.Run | ForEach-Object { $_.RunId }) | Should -Be @('RUN-A', 'RUN-C', 'RUN-B')
        }

        It 'counts the live ones and the stalled ones separately' {
            # RUN-A spoke 10 seconds ago; RUN-C 30 minutes and RUN-B two hours,
            # both past the 20-minute default. Two machines that have gone quiet
            # is exactly the morning this screen is for.
            $script:many.LiveCount | Should -Be 1
            $script:many.StalledCount | Should -Be 2
        }
    }

    Context 'a heartbeat that cannot be read' {

        It 'shows the run as unreadable instead of hiding it or throwing' {
            # A file caught mid-write, or truncated by a machine that lost power
            # between the open and the flush. The run still exists and the
            # screen must still say so.
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-BAD.json' = '{ "runId": "RUN-BAD", '
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            @($monitor.Run).Count | Should -Be 1
            $monitor.Run[0].Health | Should -BeExactly 'Unreadable'
            $monitor.Run[0].RunId | Should -BeExactly 'RUN-BAD'
            $monitor.Run[0].Text | Should -BeLike '*RUN-BAD*'
        }

        It 'keeps the others' {
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-BAD.json' = '{ oh dear'
                        'C:\ws\Logs\_active\RUN-OK.json'  = (New-HDTTestHeartbeat -RunId 'RUN-OK' -Updated '2026-08-15T21:59:00.0000000Z')
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            @($monitor.Run).Count | Should -Be 2
            @($monitor.Run | Where-Object { $_.Health -eq 'Unreadable' }).Count | Should -Be 1
        }
    }

    Context 'what is not a heartbeat' {

        It 'ignores anything that is not a .json' {
            # The engine's own log files live one directory up, but a share is a
            # place people put things.
            $monitor = Get-HDTConsoleMonitor -Path $script:root `
                -FileSystem (New-HDTTestMonitorFileSystem -File @{
                        'C:\ws\Logs\_active\RUN-0001.json' = (New-HDTTestHeartbeat -RunId 'RUN-0001' -Updated '2026-08-15T21:59:00.0000000Z')
                        'C:\ws\Logs\_active\readme.txt'    = 'not a heartbeat'
                        'C:\ws\Logs\_active\notes.log'     = 'nor this'
                    }) `
                -Clock (New-HDTFakeClock -UtcNow $script:now)

            @($monitor.Run).Count | Should -Be 1
        }
    }
}


}
