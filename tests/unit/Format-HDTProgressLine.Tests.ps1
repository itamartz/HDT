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

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

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
            [Parameter()] [int] $ElapsedSecond = 84
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
            ElapsedSecond   = $ElapsedSecond
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
            Format-HDTProgressLine -Progress (New-HDTTestProgress) | Should -BeLike '*3/8*'
        }

        It 'carries the percentage' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) | Should -BeLike '*25%*'
        }

        It 'carries the phase, which is the first thing asked about a long run' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) | Should -BeLike '*WinPE*'
        }

        It 'carries the step name' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress) | Should -BeLike '*Apply Windows 11*'
        }

        It 'carries elapsed as a clock rather than as a count of seconds' {
            # 84 seconds is 00:01:24. A technician comparing two machines reads
            # a clock; nobody divides by sixty at a bench.
            Format-HDTProgressLine -Progress (New-HDTTestProgress) | Should -BeLike '*00:01:24*'
        }

        It 'is one line, because a console scrolls' {
            @((Format-HDTProgressLine -Progress (New-HDTTestProgress)) -split "`n").Count | Should -Be 1
        }
    }

    Context 'the width it has to live in' {

        It 'fits in 80 columns' {
            # A WinPE prompt and a serial console are both 80 wide, and neither
            # wraps kindly - a line that spills leaves the technician reading
            # half of every second line.
            [int] (Format-HDTProgressLine -Progress (New-HDTTestProgress)).Length |
                Should -BeLessOrEqual 80
        }

        It 'still fits when the step name is absurd' {
            $long = New-HDTTestProgress -StepName ('Apply ' + ('very ' * 40) + 'long image')

            [int] (Format-HDTProgressLine -Progress $long).Length | Should -BeLessOrEqual 80
        }

        It 'keeps the counter and the phase when it truncates the name' {
            # THE NAME IS THE PART THAT GIVES WAY. Where the deployment is up to
            # survives; which step it is on is allowed to be abbreviated.
            $long = New-HDTTestProgress -StepName ('x' * 200)
            $line = Format-HDTProgressLine -Progress $long

            $line | Should -BeLike '*3/8*'
            $line | Should -BeLike '*WinPE*'
            $line | Should -BeLike '*00:01:24*'
        }

        It 'pads the counter so consecutive lines form columns' {
            $one = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepNumber 3 -StepCount 8 -PercentComplete 25)
            $two = Format-HDTProgressLine -Progress (New-HDTTestProgress -StepNumber 10 -StepCount 48 -PercentComplete 100)

            # The step name starts at the same column in both.
            [int] $one.IndexOf('Apply') | Should -Be ([int] $two.IndexOf('Apply'))
        }
    }

    Context 'a run that is not simply running' {

        It 'says so when it failed' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress -Status 'Failed') | Should -BeLike '*FAILED*'
        }

        It 'says so when it finished' {
            Format-HDTProgressLine -Progress (New-HDTTestProgress -Status 'Succeeded' -PercentComplete 100) |
                Should -BeLike '*DONE*'
        }

        It 'does not shout on an ordinary running step' {
            # A line that says RUNNING on every step is a line nobody reads by
            # the fourth one, and then FAILED goes past unnoticed.
            $line = Format-HDTProgressLine -Progress (New-HDTTestProgress)

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

            { Format-HDTProgressLine -Progress $empty } | Should -Not -Throw
        }

        It 'omits the count when nothing said how many steps there are' {
            $unknown = New-HDTTestProgress -StepCount 0 -StepNumber 1

            Format-HDTProgressLine -Progress $unknown | Should -Not -BeLike '*/0*'
        }
    }
}
