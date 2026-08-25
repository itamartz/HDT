# What the boot image build window shows for one progress report.
#
# THIS IS THE SCREEN SOMEBODY WATCHES FOR TWO AND A HALF MINUTES, and the whole
# job of it is to say that something is happening and what. Every line of it was
# composed inside a DispatcherTimer where nothing could test it, and every
# lesson below was learned by watching a real build go wrong.
#
# THE DETAIL GOES ON THE LOG LINE, NOT ONLY IN THE LABEL. Step 8 reports once
# per cab, and a line carrying the title alone printed "Applying the optional
# components" nineteen times - which says the build is moving and refuses to say
# what it is moving through. The cab's name is the entire value of reporting per
# component, and it is also what says WHICH one was being applied if the build
# dies inside that step.
#
# THE PER-STEP CLOCK RESTARTS ON A NEW STEP TITLE, NOT ON EVERY REPORT. Step 8
# reports nineteen times; a clock reset by each of those would never show that
# the step as a whole has been running for a minute, which is the one number
# that distinguishes "working" from "hung".
#
# BOTH CLOCKS, because they answer different questions: the total says how long
# there is left to wait, and the per-step says whether anything is happening at
# all.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    function New-HDTTestBuildReport {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Title = 'Applying the optional components',
            [Parameter()] [string] $Detail = 'WinPE-NetFx.cab',
            [Parameter()] [int] $Step = 8,
            [Parameter()] [int] $Total = 12,
            [Parameter()] [bool] $IsComplete = $false,
            [Parameter()] [bool] $Succeeded = $false
        )

        return [pscustomobject] @{
            Title = $Title; Detail = $Detail; Step = $Step; Total = $Total
            IsComplete = $IsComplete; Succeeded = $Succeeded
        }
    }
}

Describe 'Get-HDTConsoleBuildProgress' {

    Context 'an ordinary step report' {

        BeforeAll {
            $script:step = Get-HDTConsoleBuildProgress -Report (New-HDTTestBuildReport) `
                -Elapsed ([timespan]::FromSeconds(95)) -OnStep ([timespan]::FromSeconds(30)) `
                -StepText 'Mounting the image'
        }

        It 'is not finished' {
            $script:step.Finished | Should -BeFalse
        }

        It 'shows the step title and its detail' {
            $script:step.StepText | Should -BeExactly 'Applying the optional components'
            $script:step.DetailText | Should -BeExactly 'WinPE-NetFx.cab'
        }

        It 'counts the step out of the total' {
            $script:step.CountText | Should -BeExactly 'step 8 of 12'
        }

        It 'drives the bar from the same numbers' {
            $script:step.BarValue | Should -Be 8
            $script:step.BarMaximum | Should -Be 12
        }

        # THE WHOLE VALUE OF REPORTING PER COMPONENT.
        It 'puts the detail on the log line, not only in the label' {
            $script:step.LogLine | Should -BeExactly '01:35   8/12  Applying the optional components  -  WinPE-NetFx.cab'
        }

        It 'shows both clocks, and names the step the second one is timing' {
            $script:step.ElapsedText | Should -BeExactly 'elapsed 01:35   -   30s on "Applying the optional components"'
        }

        It 'leaves Close alone while the build is running' {
            $script:step.CloseEnabled | Should -BeFalse
        }
    }

    # THE ONE NUMBER THAT DISTINGUISHES WORKING FROM HUNG.
    Context 'the per-step clock' {

        It 'restarts when the step title changes' {
            $answer = Get-HDTConsoleBuildProgress -Report (New-HDTTestBuildReport -Title 'Unmounting') `
                -Elapsed ([timespan]::FromSeconds(95)) -OnStep ([timespan]::FromSeconds(30)) `
                -StepText 'Applying the optional components'

            $answer.RestartStepClock | Should -BeTrue
        }

        It 'does not restart on the nineteenth report of the same step' {
            $answer = Get-HDTConsoleBuildProgress -Report (New-HDTTestBuildReport -Detail 'WinPE-WMI.cab') `
                -Elapsed ([timespan]::FromSeconds(95)) -OnStep ([timespan]::FromSeconds(60)) `
                -StepText 'Applying the optional components'

            $answer.RestartStepClock | Should -BeFalse
        }
    }

    Context 'a step reporting no detail' {

        It 'writes the log line without a trailing separator' {
            $answer = Get-HDTConsoleBuildProgress -Report (New-HDTTestBuildReport -Title 'Mounting' -Detail '' -Step 2) `
                -Elapsed ([timespan]::FromSeconds(20)) -OnStep ([timespan]::FromSeconds(5)) -StepText 'Mounting'

            $answer.LogLine | Should -BeExactly '00:20   2/12  Mounting'
        }

        It 'treats whitespace as no detail' {
            $answer = Get-HDTConsoleBuildProgress -Report (New-HDTTestBuildReport -Title 'Mounting' -Detail '   ' -Step 2) `
                -Elapsed ([timespan]::FromSeconds(20)) -OnStep ([timespan]::FromSeconds(5)) -StepText 'Mounting'

            $answer.LogLine | Should -Not -Match '-\s*$'
        }
    }

    Context 'a build that finished successfully' {

        BeforeAll {
            $script:done = Get-HDTConsoleBuildProgress -StepText 'Unmounting' `
                -Report (New-HDTTestBuildReport -IsComplete $true -Succeeded $true -Detail 'HDTPE_wiz_x64.wim, 412 MB') `
                -Elapsed ([timespan]::FromSeconds(150)) -OnStep ([timespan]::FromSeconds(9))
        }

        It 'says Finished' {
            $script:done.Finished | Should -BeTrue
            $script:done.StepText | Should -BeExactly 'Finished'
        }

        It 'fills the bar rather than leaving it short' {
            $script:done.BarValue | Should -Be $script:done.BarMaximum
        }

        It 'writes what was built on the last log line' {
            $script:done.LogLine | Should -BeExactly '02:30  done - HDTPE_wiz_x64.wim, 412 MB'
        }

        It 'stops the running clock and says how long it took' {
            $script:done.ElapsedText | Should -BeExactly 'took 02:30'
        }

        It 'lets the window be closed' {
            $script:done.CloseEnabled | Should -BeTrue
        }
    }

    Context 'a build that failed' {

        BeforeAll {
            $script:failed = Get-HDTConsoleBuildProgress -StepText 'Applying the optional components' `
                -Report (New-HDTTestBuildReport -IsComplete $true -Succeeded $false -Detail 'DISM returned 0x800f081e') `
                -Elapsed ([timespan]::FromSeconds(63)) -OnStep ([timespan]::FromSeconds(9))
        }

        It 'says Failed rather than Finished' {
            $script:failed.StepText | Should -BeExactly 'Failed'
        }

        It 'says so on the log line too, where it can be read after the fact' {
            $script:failed.LogLine | Should -BeExactly '01:03  FAILED - DISM returned 0x800f081e'
        }

        It 'shows the reason it gave' {
            $script:failed.DetailText | Should -BeExactly 'DISM returned 0x800f081e'
        }

        It 'still lets the window be closed' {
            $script:failed.CloseEnabled | Should -BeTrue
        }

        It 'asks for the failure colour, which a running step does not' {
            $script:failed.IsFailure | Should -BeTrue
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleBuildProgress -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleBuildProgress'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
