# Which sentence the New Deployment Share page shows, and whether Create stays
# live.
#
# THREE THINGS CAN HAVE SOMETHING TO SAY and only one line to say it in: the
# path and id check, the share name check, and whether this console is elevated
# enough to publish a share at all. A page that shows whichever ran last tells a
# technician to fix the wrong thing.
#
# THE ELEVATION SENTENCE OUTRANKS THE OTHERS, because it is the one NOTHING ON
# THIS PAGE CAN FIX. Every other message names something the person can type
# their way out of; this one means closing the console and reopening it as an
# administrator, so it has to be said even when a lesser complaint is also true.
#
# AND IT DOES NOT DISABLE CREATE. The folder is still worth writing without the
# share - the share can be added later, and refusing the whole page over the
# half that needs elevation would send somebody away with nothing. That is the
# one message that warns without blocking, which is why it is asserted rather
# than remembered.
#
# NOT PUBLISHING MEANS ELEVATION IS IRRELEVANT. An empty share name publishes
# nothing, the document allows it, and telling an unelevated technician they
# cannot publish a share they never asked for is a refusal they cannot act on.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleNewWorkspaceMessage' {

    Context 'a page with nothing wrong with it' {

        BeforeAll {
            $script:fine = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage '' -Publishing $true -Elevated $true
        }

        It 'leaves Create live' {
            $script:fine.CanCreate | Should -BeTrue
        }

        It 'says nothing' {
            $script:fine.Message | Should -BeExactly ''
        }
    }

    Context 'a path or id the check refused' {

        It 'says what the check said and follows its verdict' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $false -Message 'that folder already holds a share.' `
                -ShareMessage '' -Publishing $true -Elevated $true

            $answer.Message | Should -BeExactly 'that folder already holds a share.'
            $answer.CanCreate | Should -BeFalse
        }
    }

    Context 'a share name the share check refused' {

        BeforeAll {
            $script:shareBad = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage 'that share name is already taken.' -Publishing $true -Elevated $true
        }

        It 'says the share complaint when nothing else is complaining' {
            $script:shareBad.Message | Should -BeExactly 'that share name is already taken.'
        }

        It 'blocks Create, because the page cannot do what it promises' {
            $script:shareBad.CanCreate | Should -BeFalse
        }
    }

    # THE PATH CHECK GOES FIRST, because it is the more specific complaint.
    Context 'both checks complaining at once' {

        It 'keeps the path message rather than replacing it with the share one' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $false -Message 'that folder already holds a share.' `
                -ShareMessage 'that share name is already taken.' -Publishing $true -Elevated $true

            $answer.Message | Should -BeExactly 'that folder already holds a share.'
        }
    }

    # THE ONE NOTHING ON THE PAGE CAN FIX.
    Context 'publishing a share from a console that is not elevated' {

        BeforeAll {
            $script:notElevated = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage '' -Publishing $true -Elevated $false
        }

        It 'says so, and says what to do about it' {
            $script:notElevated.Message | Should -Match 'not running as an administrator'
            $script:notElevated.Message | Should -Match 'Run as administrator'
        }

        It 'still lets the folder be created' {
            # The share can be added later; refusing the whole page would send
            # somebody away with nothing.
            $script:notElevated.CanCreate | Should -BeTrue
        }

        It 'outranks a share complaint that is also true' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage 'that share name is already taken.' -Publishing $true -Elevated $false

            $answer.Message | Should -Match 'not running as an administrator'
        }

        It 'outranks a path complaint too, but does not un-refuse it' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $false -Message 'that folder already holds a share.' `
                -ShareMessage '' -Publishing $true -Elevated $false

            $answer.Message | Should -Match 'not running as an administrator'
            $answer.CanCreate | Should -BeFalse
        }
    }

    # NOT PUBLISHING MEANS ELEVATION IS IRRELEVANT.
    Context 'a share with no share name, from a console that is not elevated' {

        It 'says nothing about administrators' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage '' -Publishing $false -Elevated $false

            $answer.Message | Should -BeExactly ''
            $answer.CanCreate | Should -BeTrue
        }

        It 'ignores a share complaint about a share nobody asked for' {
            $answer = Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' `
                -ShareMessage 'that share name is already taken.' -Publishing $false -Elevated $true

            $answer.Message | Should -BeExactly ''
            $answer.CanCreate | Should -BeTrue
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleNewWorkspaceMessage -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleNewWorkspaceMessage'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
