# WHAT A DEPLOYMENT LOOKS LIKE WHEN IT CANNOT DRAW.
#
# DESIGN 11.1: "If XAML fails to load - a boot image built without the right
# components, an exotic display, a serial console - the engine logs the reason
# and WRITES STYLED CONSOLE LINES INSTEAD, then carries on."
#
# Start-HDTProgressDisplay already reports Console rather than throwing. This is
# the other half: the line itself. It is pure, so the one thing a technician
# reads on a machine that could not open a window is asserted here rather than
# discovered on the machine.
#
# ONE LINE PER CALL, FIXED WIDTH AT THE FRONT. A serial console and a WinPE
# command prompt are both 80 columns wide and neither wraps kindly; the counter
# and the percentage are padded so consecutive lines form columns rather than
# ragged text. That is the whole of what "styled" can mean where there is no
# window.

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

    # THE CLOCK, FIXED, AND PASSED IN AT EVERY CALL BELOW. The line's elapsed is
    # now the difference between the step's start and the time of asking, so a
    # test that let the real clock supply the second half would assert on when
    # the suite happened to run.
    $script:now = [datetime]::new(2026, 8, 15, 9, 30, 0, [System.DateTimeKind]::Utc)

    function New-HDTTestProgress {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()] [string] $SequenceId = 'STD-CLIENT',
            [Parameter()] [int] $StepNumber = 3,
            [Parameter()] [int] $StepCount = 8,
            [Parameter()] [string] $StepName = 'Apply Windows 11 Enterprise LTSC 2024',
            [Parameter()] [string] $StepType = 'ApplyImage',
            [Parameter()] [int] $CompletedCount = 2,
            [Parameter()] [int] $PercentComplete = 25,
            [Parameter()] [string] $Phase = 'WinPE',
            [Parameter()] [string] $Status = 'Running',
            [Parameter()] [int] $ElapsedSecond = 84,
            [Parameter()] [int] $StepPercent = 0,
            [Parameter()] [string] $Activity = ''
        )

        return [pscustomobject] @{
            RunId           = 'r-1'
            SequenceId      = $SequenceId
            StepNumber      = $StepNumber
            StepCount       = $StepCount
            StepName        = $StepName
            StepType        = $StepType
            CompletedCount  = $CompletedCount
            PercentComplete = $PercentComplete
            Phase           = $Phase
            Status          = $Status
            StepPercent     = $StepPercent
            Activity        = $Activity

            # THE KNOB IS STILL "HOW LONG HAS IT BEEN GOING", because that is
            # what every assertion below is about - but the progress object no
            # longer carries a duration, so the seconds are turned back into the
            # instant the step started, which is what it does carry.
            StepStartTime   = $script:now.AddSeconds(-$ElapsedSecond)
        }
    }
}

Describe 'Format-HDTProgressLine' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Format-HDTProgressLine' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what it says' {

        It 'carries step N of M' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now | Should -BeLike '*3/8*'
        }

        It 'carries the percentage' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now | Should -BeLike '*25%*'
        }

        It 'carries the phase, which is the first thing asked about a long run' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now | Should -BeLike '*WinPE*'
        }

        It 'carries the step name' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now | Should -BeLike '*Apply Windows 11*'
        }

        It 'carries elapsed as a clock rather than as a count of seconds' {
            # 84 seconds is 00:01:24. A technician comparing two machines reads
            # a clock; nobody divides by sixty at a bench.
            Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now | Should -BeLike '*00:01:24*'
        }

        It 'measures elapsed against the time it is told, not against the records' {
            # THE DEFECT THIS REPLACED. The number used to be summed from the
            # records' own timestamps, so it moved only when something wrote a
            # record - and on a step that went quiet for minutes it did not move
            # at all. Same progress object, two different moments of asking, two
            # different clocks: that is what makes it a clock.
            $progress = New-HDTTestProgress

            Format-HDTProgressLine -Progress $progress -Now $script:now | Should -BeLike '*00:01:24*'
            Format-HDTProgressLine -Progress $progress -Now $script:now.AddSeconds(30) | Should -BeLike '*00:01:54*'
        }

        It 'is one line, because a console scrolls' {
            @((Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now) -split "`n").Count | Should -Be 1
        }
    }

    Context 'the width it has to live in' {

        It 'fits in 80 columns' {
            # A WinPE prompt and a serial console are both 80 wide, and neither
            # wraps kindly - a line that spills leaves the technician reading
            # half of every second line.
            [int] (Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now).Length |
                Should -BeLessOrEqual 80
        }

        It 'still fits when the step name is absurd' {
            $long = New-HDTTestProgress -StepName ('Apply ' + ('very ' * 40) + 'long image')

            [int] (Format-HDTProgressLine -Progress $long -Now $script:now).Length | Should -BeLessOrEqual 80
        }

        It 'keeps the counter and the phase when it truncates the name' {
            # THE NAME IS THE PART THAT GIVES WAY. Where the deployment is up to
            # survives; which step it is on is allowed to be abbreviated.
            $long = New-HDTTestProgress -StepName ('x' * 200)
            $line = Format-HDTProgressLine -Progress $long -Now $script:now

            $line | Should -BeLike '*3/8*'
            $line | Should -BeLike '*WinPE*'
            $line | Should -BeLike '*00:01:24*'
        }

        It 'pads the counter so consecutive lines form columns' {
            $one = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepNumber 3 -StepCount 8 -PercentComplete 25) -Now $script:now
            $two = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepNumber 10 -StepCount 48 -PercentComplete 100) -Now $script:now

            # The step name starts at the same column in both.
            [int] $one.IndexOf('Apply') | Should -Be ([int] $two.IndexOf('Apply'))
        }
    }

    Context 'a run that is not simply running' {

        It 'says so when it failed' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress -Status 'Failed') -Now $script:now | Should -BeLike '*FAILED*'
        }

        It 'says so when it finished' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress -Status 'Succeeded' -PercentComplete 100) -Now $script:now |
                Should -BeLike '*DONE*'
        }

        It 'does not shout on an ordinary running step' {
            # A line that says RUNNING on every step is a line nobody reads by
            # the fourth one, and then FAILED goes past unnoticed.
            $line = Format-HDTProgressLine -Progress (New-HDTTestProgress) -Now $script:now

            $line | Should -Not -BeLike '*RUNNING*'
            $line | Should -Not -BeLike '*FAILED*'
        }
    }

    Context 'a stream that said very little' {

        It 'survives a progress object with nothing in it' {
            $empty = [pscustomobject] @{
                SequenceId = ''; StepNumber = 0; StepCount = 0; StepName = ''; StepType = ''
                CompletedCount = 0; PercentComplete = 0; Phase = ''; Status = 'Unknown'; ElapsedSecond = 0
            }

            { Format-HDTProgressLine -Progress $empty -Now $script:now } | Should -Not -Throw
        }

        It 'prints a clock of zero when no step has started' {
            # A run that has not reached its first step has nothing to time, and
            # the column has to be there anyway: consecutive lines forming
            # columns is the whole of the styling this fallback has, so a clock
            # that came and went would shift every other column sideways.
            $notYet = New-HDTTestProgress
            $notYet.StepStartTime = $null

            Format-HDTProgressLine -Progress $notYet -Now $script:now | Should -BeLike '*00:00:00*'
        }

        It 'never prints a negative clock' {
            # WinPE corrects its clock mid-run (DESIGN 4.4.2), and a correction
            # landing between the step's start and the moment of asking is a
            # real shape. A negative timespan renders through the format string
            # as a huge hour count on a wall.
            $ahead = New-HDTTestProgress -ElapsedSecond -600

            Format-HDTProgressLine -Progress $ahead -Now $script:now | Should -BeLike '*00:00:00*'
        }

        It 'omits the count when nothing said how many steps there are' {
            $unknown = New-HDTTestProgress -StepCount 0 -StepNumber 1

            Format-HDTProgressLine -Progress $unknown -Now $script:now | Should -Not -BeLike '*/0*'
        }
    }
}

Describe 'the step that is taking all the time' {

    # AN APPLY IS NINE MINUTES OF ONE LINE. The counter and the sequence
    # percentage are correct and motionless for the whole of it, and a
    # motionless line on a serial console is indistinguishable from a hung
    # machine. dism's own percentage is what moves.
    #
    # THE COLUMN IS RESERVED WHETHER OR NOT IT IS USED, because consecutive
    # lines forming columns is the entire styling this fallback has, and a
    # column that appears when a step happens to report would shift the clock
    # sideways mid-deployment.

    It 'shows the percentage the step reported' {
        Format-HDTProgressLine -Progress (New-HDTTestProgress -StepPercent 37) -Now $script:now | Should -BeLike '*37%*'
    }

    It 'shows nothing where a step reported nothing' {
        Format-HDTProgressLine -Progress (New-HDTTestProgress -StepPercent 0) -Now $script:now | Should -Not -BeLike '*0%*'
    }

    It 'keeps the clock in the same column either way' {
        $with = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepPercent 37) -Now $script:now
        $without = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepPercent 0) -Now $script:now

        $with.IndexOf('00:01:24') | Should -Be $without.IndexOf('00:01:24')
    }

    It 'still fits in eighty columns with a long name and a percentage' {
        $long = New-HDTTestProgress -StepPercent 100 -StepName ('Apply ' + ('Windows Server 2025 Standard Desktop Experience ' * 3))

        (Format-HDTProgressLine -Progress $long -Now $script:now).Length | Should -BeLessOrEqual 80
    }

    It 'survives a progress object that predates the field' {
        $old = [pscustomobject] @{
            SequenceId = 'STD-CLIENT'; StepNumber = 3; StepCount = 8; StepName = 'Apply image'; StepType = 'ApplyImage'
            CompletedCount = 2; PercentComplete = 25; Phase = 'WinPE'; Status = 'Running'; ElapsedSecond = 84
        }

        { Format-HDTProgressLine -Progress $old -Now $script:now } | Should -Not -Throw
    }
}


}
