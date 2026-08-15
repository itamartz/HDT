# THE NAVIGATOR, AND IT IS WHERE EVERY BRANCH IN THE SHELL LIVES.
#
# HDTWizardShell.xaml opens ONCE and the page inside it is swapped in place, so
# something has to decide - on every click - which page is now current, what the
# rail shows, whether Back is available, what the Next button says, and whether
# Next has run off the end of the list. That decision is this command, and it is
# pure: no window, no file system, no WPF.
#
# WHY THAT SPLIT IS NOT NEGOTIABLE. New-HDTWizardHost is exempt from TDD as a
# thin WPF adapter (CLAUDE.md rule 1), and the price of the exemption is that the
# adapter must have nothing in it worth testing. The moment page order lived in
# the host, the host would be worth testing and could not be exempt - which is
# exactly the trap it fell into once already, when it read the network.
#
# THE ONE THAT MATTERS. Done is what closes the window and lets the deployment
# start. Every other answer must leave it false: an off-by-one at the end of the
# list is a wizard that partitions a disk one page early.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTTestPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [string[]] $Id = @('TaskSequence', 'ComputerName', 'Summary')
        )

        return @($Id | ForEach-Object {
                [pscustomobject] @{
                    Id          = $_
                    Title       = $_
                    Heading     = ('Heading for {0}' -f $_)
                    Subheading  = ('Subheading for {0}' -f $_)
                    XamlPath    = ('X:\HDT\UI\{0}.xaml' -f $_)
                    Xaml        = ('<Grid />')
                }
            })
    }
}

Describe 'Step-HDTWizardPage' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Step-HDTWizardPage' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'where it starts' {

        It 'starts on the first page' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Start'

            [int] $state.Index | Should -Be 0
            [string] $state.Page.Id | Should -BeExactly 'TaskSequence'
            [bool] $state.Done | Should -BeFalse
        }

        It 'offers no Back on the first page' {
            # There is nowhere to go back TO, and a button that is enabled and
            # does nothing is how a technician concludes the machine is hung.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Start'

            [bool] $state.BackEnabled | Should -BeFalse
        }

        It 'carries the page heading and subheading, so the shell never invents one' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Start'

            [string] $state.Heading | Should -BeExactly 'Heading for TaskSequence'
            [string] $state.Subheading | Should -BeExactly 'Subheading for TaskSequence'
        }
    }

    Context 'moving forward and back' {

        It 'moves to the next page on Next' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Next'

            [int] $state.Index | Should -Be 1
            [string] $state.Page.Id | Should -BeExactly 'ComputerName'
            [bool] $state.Done | Should -BeFalse
        }

        It 'offers Back once there is somewhere to go back to' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Next'

            [bool] $state.BackEnabled | Should -BeTrue
        }

        It 'moves to the previous page on Back' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 2 -Action 'Back'

            [int] $state.Index | Should -Be 1
            [string] $state.Page.Id | Should -BeExactly 'ComputerName'
        }

        It 'never walks off the front of the list' {
            # Back is disabled on page one, but a disabled button is a
            # presentation choice and this is the guarantee underneath it.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Back'

            [int] $state.Index | Should -Be 0
            [bool] $state.Done | Should -BeFalse
        }

        It 'walks the whole list and comes back, keeping the pages in order' {
            # THE BENCHMARK FOR THIS COMMAND: a real click sequence, asserted as
            # an ordered list, the same shape DESIGN 12.2.1 asks of the engine.
            $page = New-HDTTestPage
            $visited = @()
            $index = 0

            foreach ($action in @('Start', 'Next', 'Next', 'Back', 'Next')) {
                $state = Step-HDTWizardPage -Page $page -Index $index -Action $action
                $index = [int] $state.Index
                if (-not $state.Done) { $visited += [string] $state.Page.Id }
            }

            ($visited -join ' > ') | Should -BeExactly (
                'TaskSequence > ComputerName > Summary > ComputerName > Summary')
        }
    }

    Context 'the end of the list' {

        It 'says Deploy on the last page, not Next' {
            # MDT's Finish. The button that starts a deployment must not read
            # like the button that turns a page.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 2 -Action 'Start'

            [string] $state.NextCaption | Should -BeExactly 'Deploy'
        }

        It 'says Next everywhere else' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Start'

            [string] $state.NextCaption | Should -BeExactly 'Next'
        }

        It 'is Done when Next is pressed on the last page' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 2 -Action 'Next'

            [bool] $state.Done | Should -BeTrue
        }

        It 'is not Done anywhere before the last page' -ForEach @(0, 1) {
            # THE OFF-BY-ONE THIS EXISTS TO CATCH. Done closes the window and
            # starts a deployment; one page early is a disk partitioned before
            # the technician confirmed it.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index $PSItem -Action 'Next'

            [bool] $state.Done | Should -BeFalse
        }

        It 'has no current page once it is Done' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 2 -Action 'Next'

            $state.Page | Should -BeNullOrEmpty -Because (
                'there is no page after the last one, and returning the last one again would let a caller show it twice')
        }

        It 'is Done immediately on a single-page wizard' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage -Id @('Summary')) -Index 0 -Action 'Next'

            [bool] $state.Done | Should -BeTrue
        }

        It 'says Deploy on a single-page wizard, because its only page is also its last' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage -Id @('Summary')) -Index 0 -Action 'Start'

            [string] $state.NextCaption | Should -BeExactly 'Deploy'
            [bool] $state.BackEnabled | Should -BeFalse
        }
    }

    Context 'the rail' {

        It 'lists every page, in order' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 1 -Action 'Start'

            @($state.Rail).Count | Should -Be 3
            (@($state.Rail | ForEach-Object { [string] $_.Title }) -join ',') |
                Should -BeExactly 'TaskSequence,ComputerName,Summary'
        }

        It 'marks exactly one row Current' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 1 -Action 'Start'

            @($state.Rail | Where-Object { $_.State -eq 'Current' }).Count | Should -Be 1
            [string] @($state.Rail)[1].State | Should -BeExactly 'Current'
        }

        It 'marks the pages behind it Done and the ones ahead Pending' {
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 1 -Action 'Start'

            [string] @($state.Rail)[0].State | Should -BeExactly 'Done'
            [string] @($state.Rail)[2].State | Should -BeExactly 'Pending'
        }

        It 'carries no colour, because the look is defined in one place and it is not here' {
            # HDTTheme.xaml and the shell's own DataTemplate decide what Done,
            # Current and Pending look like. A brush computed in the engine is a
            # second place the look is defined, and the first one to drift.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 1 -Action 'Start'

            @($state.Rail)[0].PSObject.Properties.Name | Should -Not -Contain 'Fill'
            @($state.Rail)[0].PSObject.Properties.Name | Should -Not -Contain 'Ink'
        }

        It 'still lists every page when the wizard is Done' {
            # The rail is the last thing on screen before the window closes; a
            # rail that emptied itself would flash blank on the way out.
            $state = Step-HDTWizardPage -Page (New-HDTTestPage) -Index 2 -Action 'Next'

            @($state.Rail).Count | Should -Be 3
            @($state.Rail | Where-Object { $_.State -eq 'Current' }).Count | Should -Be 0
        }
    }

    Context 'what it refuses' {

        It 'refuses an empty page list' {
            # Every page skipped means the wizard must NOT BE SHOWN, which is
            # the caller's decision - the same rule HDTSkipWelcome follows. A
            # shell that opened on nothing would return an Action for a window
            # with no content in it.
            { Step-HDTWizardPage -Page @() -Index 0 -Action 'Start' } |
                Should -Throw -ExpectedMessage '*no pages*'
        }

        It 'refuses an index past the end of the list, naming both numbers' {
            $record = $null
            try {
                Step-HDTWizardPage -Page (New-HDTTestPage) -Index 7 -Action 'Start'
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*7*'
            $record.Exception.Message | Should -BeLike '*3*'
        }

        It 'refuses a negative index' {
            { Step-HDTWizardPage -Page (New-HDTTestPage) -Index -1 -Action 'Start' } | Should -Throw
        }

        It 'refuses an action it does not know' {
            # The allow-list reflex from Show-HDTWizard, for the same reason:
            # guessing what an unrecognised action meant is how Next gets
            # inferred from something that was not Next.
            { Step-HDTWizardPage -Page (New-HDTTestPage) -Index 0 -Action 'Deploy' } | Should -Throw
        }
    }
}
