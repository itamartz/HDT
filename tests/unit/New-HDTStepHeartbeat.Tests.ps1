
# THE ONE MECHANISM THAT KEEPS A LONG STEP'S SCREEN ALIVE.
#
# THE DEFECT IT EXISTS FOR, MEASURED, NOT IMAGINED. On LT-7FJ45S2,
# run-20260829-190105:
#
#   Apply Windows Settings   step.start 03:04:41.370, next record 03:08:02.099.
#                            THREE MINUTES AND TWENTY-ONE SECONDS with no record
#                            of any kind.
#   Install Applications     step.progress "installing 1 of 2" 16:13:41.358,
#                            next record 16:15:38.176. ONE MINUTE FIFTY-SEVEN
#                            while a single MSI ran.
#
# AND SILENCE IS NOT COSMETIC HERE. Get-HDTDeploymentProgress derives everything
# it shows - the bar, the step, AND THE ELAPSED CLOCK - from the timestamps of
# the records themselves, deliberately, because reading a wall clock there would
# make the answer depend on when it was asked. So between two records nothing on
# the screen moves at all: the technician watched "00:00:00 elapsed" for three
# and a half minutes of a deployment that was working perfectly.
#
# THE FIX BELONGS ON THE PRODUCER SIDE, and this is it: a step that is waiting on
# something long emits a record periodically, so there is always something with a
# fresh timestamp for the derivation to read.
#
# MDT'S SHAPE, BECAUSE MDT SOLVED THIS FIRST. ZTIUtility.vbs's RunCommandLog
# (lines 2173-2201) does not block on a child process - it launches with
# WshShell.Exec and spins on oExec.Status with SafeSleep 100 - and inside that
# loop, at lines 2229-2237, it writes a periodic heartbeat event (41003) when
# DateDiff("n", lastHeartbeat, Now) >= 5. Poll rather than block, and a timed
# record for when the tool itself has nothing to say. HDT does both; only the
# interval differs, and the reason is in the command's own comments.
#
# WHAT IS ASSERTED HERE is the emitter alone: that it rations itself, that it
# says something that is true and changing, and above all THAT A FAST STEP PAYS
# NOTHING. The half that proves a heartbeat actually fires against a real
# blocking child process is tests/contract/ProcessService.Contract.Tests.ps1,
# which runs the real adapter against a real cmd.exe - a fake that returns
# instantly can be made to emit heartbeats that a real WaitForExit never would.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:startUtc = [datetime]::new(2026, 8, 29, 3, 4, 41, [System.DateTimeKind]::Utc)

    function New-HDTHeartbeatTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test context; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowNull()]
            [object] $Progress
        )

        $fs = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow $script:startUtc

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $fs -Clock $clock -ThreadId 1

        return [pscustomobject] @{
            Log        = $log
            Service    = [pscustomobject] @{ Clock = $clock; Progress = $Progress }
            Clock      = $clock
            FileSystem = $fs
        }
    }

    # The heartbeat records only, in order. Every other record the log context
    # writes for itself - the clock caveat, for one - is not this command's.
    function Get-HDTHeartbeatRecord {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)] [object] $Context)

        $path = [string] $Context.Log.JsonlPath
        if (-not $Context.FileSystem.TestPath($path)) { return @() }

        $text = [string] $Context.FileSystem.ReadAllText($path)

        return @(
            foreach ($line in ($text -split "`n")) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

                $record = ConvertFrom-Json -InputObject $trimmed
                if ([string] $record.event -ne 'step.progress') { continue }
                if ($null -eq $record.data.PSObject.Properties['heartbeat']) { continue }

                $record
            })
    }
}

Describe 'New-HDTStepHeartbeat' {

    Context 'the command exists' {

        It 'is a private command of Hephaestus' {
            Get-Command -Name 'New-HDTStepHeartbeat' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'hands back something a service adapter can invoke' {
            $context = New-HDTHeartbeatTestContext

            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' -Activity 'Adobe Acrobat'

            $tick | Should -BeOfType ([scriptblock]) -Because (
                'IProcessService.Start takes an OnTick scriptblock; the heartbeat has to BE one so that ' +
                'the adapter never learns what a log is.')
        }
    }

    Context 'a step that finishes before the interval' {

        # THE RULE THAT KEEPS THE LOG READABLE. A SetVariable step takes 200 ms
        # and calls nothing; a ConfigureBoot step runs a process that returns in
        # two seconds. Neither must add a single line, or a deployment's log
        # grows by a third to say nothing.
        It 'writes nothing at all when it is ticked immediately' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'CommandLine' -Activity 'bcdboot'

            & $tick

            @(Get-HDTHeartbeatRecord -Context $context).Count | Should -Be 0
        }

        It 'writes nothing after two hundred milliseconds of ticking' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'CommandLine' -Activity 'bcdboot'

            # What the adapter's poll loop does to a process that exits fast:
            # ticks a handful of times and then stops.
            foreach ($offset in @(50, 100, 150, 200)) {
                $context.Clock.SetUtcNow($script:startUtc.AddMilliseconds($offset))
                & $tick
            }

            @(Get-HDTHeartbeatRecord -Context $context).Count | Should -Be 0
        }
    }

    Context 'a step that runs for minutes' {

        It 'writes its first record one interval in, and not before' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(14))
            & $tick
            @(Get-HDTHeartbeatRecord -Context $context).Count | Should -Be 0

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(15))
            & $tick
            @(Get-HDTHeartbeatRecord -Context $context).Count | Should -Be 1
        }

        It 'rations itself to one record per interval however often it is ticked' {
            # THE POLL IS FOUR TIMES A SECOND AND THE RECORD IS EVERY FIFTEEN.
            # Ticking is free; writing a line to a JSONL on a share is not, and
            # Update-HDTProgressDisplay re-reads and re-parses the WHOLE log on
            # every one - so a heartbeat that wrote per poll would be quadratic
            # in the length of the deployment.
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            # Two minutes of polling at four hertz: 480 ticks, 8 records.
            for ($i = 1; $i -le 480; $i++) {
                $context.Clock.SetUtcNow($script:startUtc.AddMilliseconds(250 * $i))
                & $tick
            }

            @(Get-HDTHeartbeatRecord -Context $context).Count | Should -Be 8
        }

        It 'reports the elapsed time on the operation, which is the fact that is actually changing' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            foreach ($second in @(15, 30, 45)) {
                $context.Clock.SetUtcNow($script:startUtc.AddSeconds($second))
                & $tick
            }

            $record = @(Get-HDTHeartbeatRecord -Context $context)

            @($record | ForEach-Object { [int] $_.data.elapsedSecond }) | Should -Be @(15, 30, 45)
        }

        It 'names what it is waiting on, so the line is not a spinner' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(135))
            & $tick

            $record = @(Get-HDTHeartbeatRecord -Context $context)[0]

            [string] $record.message | Should -Match 'Adobe Acrobat'
            [string] $record.message | Should -Match '2m 15s' -Because (
                'Format-HDTConsoleDuration is how every other elapsed in this product is written, and a ' +
                'technician reading "135" has to do the arithmetic themselves.')
            [string] $record.data.activity | Should -BeExactly 'Adobe Acrobat'
            [string] $record.component | Should -BeExactly 'InstallApplications'
        }
    }

    Context 'what it must never do to the bar' {

        # THE TRAP THIS DESIGN WAS CHOSEN TO AVOID. Get-HDTDeploymentProgress
        # reads `percent` off a step.progress record and only off that; a
        # heartbeat that carried percent 0 - or that invented one from elapsed
        # time - would drag the step bar back to nought every fifteen seconds in
        # the middle of an apply that was 70% done.
        It 'carries no percent, so the step bar cannot jump backwards' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'ApplyImage' `
                -Activity 'applying the image' -IntervalSecond 15

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(20))
            & $tick

            $record = @(Get-HDTHeartbeatRecord -Context $context)[0]

            $record.data.PSObject.Properties['percent'] | Should -BeNullOrEmpty
        }

        It 'leaves a step bar that a real progress record had already moved exactly where it was' {
            # Asserted through the consumer rather than by reading the record,
            # because the consumer is the thing that must not regress.
            $record = @(
                [pscustomobject] @{ ts = '2026-08-29T03:00:00.0000000Z'; event = 'run.start'
                    data                = [pscustomobject] @{ sequenceId = 'STD-CLIENT'; stepCount = 10 }
                }
                [pscustomobject] @{ ts = '2026-08-29T03:00:01.0000000Z'; event = 'step.start'
                    data                = [pscustomobject] @{ index = 5; name = 'Apply image'; type = 'ApplyImage' }
                }
                [pscustomobject] @{ ts = '2026-08-29T03:04:00.0000000Z'; event = 'step.progress'
                    data                = [pscustomobject] @{ percent = 70 }
                }
                [pscustomobject] @{ ts = '2026-08-29T03:04:15.0000000Z'; event = 'step.progress'
                    data                = [pscustomobject] @{ activity = 'applying the image'; elapsedSecond = 255; heartbeat = $true }
                }
            )

            $progress = Get-HDTDeploymentProgress -Record $record

            [int] $progress.StepPercent | Should -Be 70
        }

        It 'says on screen what the step is still doing, which is now the whole point of it' {
            # WHAT THIS TEST USED TO ASSERT, AND WHY IT NO LONGER CAN. Elapsed
            # was summed from the records' own timestamps, so a heartbeat was
            # the thing that MOVED THE CLOCK - and between heartbeats the clock
            # was frozen by construction. The window runs the clock itself now,
            # against the step's start time, so it moves whether or not anything
            # writes a record and there is no elapsed here to assert on.
            #
            # THE HEARTBEAT IS STILL WORTH WRITING, and this is what for: on a
            # step that has gone quiet its message is the only thing on the card
            # that says anything at all, and the log keeps the evidence that the
            # machine was alive at that instant.
            #
            # The measured defect, reproduced: a step.start and then silence.
            $silent = @(
                [pscustomobject] @{ ts = '2026-08-29T03:04:41.3700000Z'; event = 'step.start'
                    data                = [pscustomobject] @{ index = 7; name = 'Apply Windows Settings'; type = 'ApplyUnattend' }
                }
            )

            $quiet = Get-HDTDeploymentProgress -Record $silent

            [string] $quiet.Activity | Should -BeExactly ''
            [datetime] $quiet.StepStartTime |
                Should -Be ([datetime]::new(2026, 8, 29, 3, 4, 41, [System.DateTimeKind]::Utc).AddTicks(3700000))

            $withHeartbeat = $silent + @(
                [pscustomobject] @{ ts = '2026-08-29T03:07:41.3700000Z'; event = 'step.progress'
                    message             = 'applying the answer file - still running after 180s'
                    data                = [pscustomobject] @{ activity = 'applying the answer file'; elapsedSecond = 180; heartbeat = $true }
                }
            )

            $beating = Get-HDTDeploymentProgress -Record $withHeartbeat

            [string] $beating.Activity | Should -BeExactly 'applying the answer file - still running after 180s'

            # AND IT DID NOT RESTART THE CLOCK. Only step.start does that; a
            # heartbeat that moved the step's start time would reset the very
            # number it is written to keep honest.
            [datetime] $beating.StepStartTime | Should -Be ([datetime] $quiet.StepStartTime)
        }
    }

    Context 'it tells the window to look' {

        It 'asks the display to re-read the log when it writes one' {
            # THE HALF THAT WAS MISSING FOR ApplyDrivers: a record written to a
            # JSONL that nothing reads back draws nothing.
            $display = New-HDTFakeProgressHost
            $context = New-HDTHeartbeatTestContext -Progress $display

            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(15))
            & $tick

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -Be 1
        }

        It 'does not disturb the display on a tick that writes nothing' {
            $display = New-HDTFakeProgressHost
            $context = New-HDTHeartbeatTestContext -Progress $display

            $tick = New-HDTStepHeartbeat -Context $context -Component 'InstallApplications' `
                -Activity 'Adobe Acrobat' -IntervalSecond 15

            & $tick

            @($display.Operations | Where-Object { $_ -eq 'Update' }).Count | Should -Be 0
        }
    }

    Context 'it never fails a deployment' {

        # Same contract as Update-HDTProgressDisplay, and for the same reason:
        # this runs from inside an adapter's poll loop, on a machine part-way
        # through installing an operating system. A heartbeat is not allowed to
        # be the thing that stops it.
        It 'returns a scriptblock that does nothing when there is no clock to ask' {
            $context = [pscustomobject] @{ Log = $null; Service = [pscustomobject] @{ Progress = $null } }

            $tick = New-HDTStepHeartbeat -Context $context -Component 'CommandLine' -Activity 'setup.exe'

            { & $tick } | Should -Not -Throw
        }

        It 'survives a context with no services at all' {
            $tick = New-HDTStepHeartbeat -Context $null -Component 'CommandLine' -Activity 'setup.exe'

            { & $tick } | Should -Not -Throw
        }

        It 'survives a log whose file system has gone with the RAM disk' {
            $context = New-HDTHeartbeatTestContext
            $tick = New-HDTStepHeartbeat -Context $context -Component 'CommandLine' `
                -Activity 'setup.exe' -IntervalSecond 15

            $context.Log.FileSystem = $null

            $context.Clock.SetUtcNow($script:startUtc.AddSeconds(30))

            { & $tick } | Should -Not -Throw
        }
    }
}

}
