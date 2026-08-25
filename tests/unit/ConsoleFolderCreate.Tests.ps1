# Making a folder from the tree: what to ask, and where the folder lands.
#
# THE PARENT IS THE ROW IT WAS ASKED FOR ON, which is what makes ONE menu item
# serve both "a folder at the top" and "a folder inside this one". Right-click
# the category and the new folder is top level; right-click a folder and it goes
# inside it. Nothing on the screen distinguishes the two presses, so the row
# under the pointer is the whole difference.
#
# THE PROMPT HAS TO SAY WHICH OF THE TWO IS ABOUT TO HAPPEN, because the dialog
# is the last point where somebody can tell. A prompt that reads the same either
# way makes the nesting a surprise discovered afterwards, in a tree that has to
# be edited to undo it.
#
# A FOLDER ORGANISES THE WINDOW AND NOTHING ELSE. Nothing moves on disk and a
# deployment does not know folders exist - which is exactly what the hint says,
# because an MDT admin has every reason to assume the opposite.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleFolderCreate' {

    Context 'a folder made at the top of a category' {

        BeforeAll {
            $script:top = Get-HDTConsoleFolderCreate -Root 'C:\HDTLab\Share' -Parent '' -Name 'Clients'
        }

        It 'puts it at the top, under no parent' {
            $script:top.Folder | Should -BeExactly 'Clients'
        }

        It 'edits the share document' {
            $script:top.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\workspace.yaml'
        }

        It 'says nothing about being inside anything' {
            $script:top.Prompt | Should -Not -Match 'inside'
        }

        It 'still says a folder moves nothing on disk' {
            $script:top.Prompt | Should -Match 'nothing moves on disk'
        }
    }

    Context 'a folder made inside another one' {

        BeforeAll {
            $script:nested = Get-HDTConsoleFolderCreate -Root 'C:\HDTLab\Share' -Parent 'Clients' -Name 'Bare metal'
        }

        It 'lands under its parent' {
            $script:nested.Folder | Should -BeExactly 'Clients\Bare metal'
        }

        It 'tells the reader which folder it is about to go inside' {
            $script:nested.Prompt | Should -Match "inside 'Clients'"
        }
    }

    Context 'a folder made three deep' {

        It 'keeps the whole parent path rather than only the last part' {
            $answer = Get-HDTConsoleFolderCreate -Root 'C:\ws' -Parent 'Clients\Bare metal' -Name 'Laptops'

            $answer.Folder | Should -BeExactly 'Clients\Bare metal\Laptops'
        }
    }

    # WHITESPACE IS NOT A NAME. The dialog trims, but a parent read off a row
    # can still be blank, and ' \x' is not a folder anybody asked for.
    Context 'a parent that is blank' {

        It 'treats whitespace as no parent at all' {
            $answer = Get-HDTConsoleFolderCreate -Root 'C:\ws' -Parent '   ' -Name 'Clients'

            $answer.Folder | Should -BeExactly 'Clients'
            $answer.Prompt | Should -Not -Match 'inside'
        }
    }

    Context 'the command it echoes' {

        It 'names the category and the folder it made' {
            $answer = Get-HDTConsoleFolderCreate -Root 'C:\ws' -Parent 'Clients' -Name 'Bare metal' `
                -Category 'TaskSequence'

            $answer.Command |
                Should -BeExactly "Add-HDTWorkspaceFolder -Line `$line -Category TaskSequence -Folder 'Clients\Bare metal'"
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleFolderCreate -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleFolderCreate'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
