# Applying several edited fields on a task sequence in one press.
#
# ONE READ, EVERY CHANGE, ONE WRITE. Saving per row would write the document
# twice for a name and a description typed together, and the SECOND write would
# be built from lines read before the first - so the first edit disappears. The
# order the edits are applied in is therefore the order they are listed, against
# one set of lines carried through.
#
# THE KEY IS 'name' AND THE PARAMETER IS -Name. The document spells its keys
# camelCase and the command spells its parameters PascalCase; only the first
# letter changes, so 'timeoutMinutes' is -TimeoutMinutes.
#
# ONLY A RENAME MAKES THE TREE STALE. The row reads 'id - name', so rebuilding
# after a description edit re-reads every open share and revalidates every
# sequence in it to learn nothing.
#
# EVERY COMMAND THE PRESS RAN, ending with the save - DESIGN 12's "learn the
# automation surface by clicking around" only works if the box shows the whole
# sequence, retypeable top to bottom.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleSequenceSave' {

    Context 'a name and a description typed together' {

        BeforeAll {
            $script:both = Get-HDTConsoleSequenceSave -Path 'C:\ws\Control\DEMO-05\sequence.yaml' -Pending @(
                [pscustomobject] @{ Property = 'name'; Value = 'Windows 11 bare metal' }
                [pscustomobject] @{ Property = 'description'; Value = 'from the client template' }
            )
        }

        It 'applies both edits, in the order they were listed' {
            @($script:both.Edit.Parameter) | Should -Be @('Name', 'Description')
        }

        It 'carries each typed value with its parameter' {
            @($script:both.Edit.Value) | Should -Be @('Windows 11 bare metal', 'from the client template')
        }

        It 'reports the rename, because the tree row reads id - name' {
            $script:both.Renamed | Should -BeTrue
        }

        It 'echoes every command the press ran, the save last' {
            @($script:both.Command) | Should -Be @(
                "Set-HDTTaskSequenceProperty -Line `$line -Name 'Windows 11 bare metal'"
                "Set-HDTTaskSequenceProperty -Line `$line -Description 'from the client template'"
                "Save-HDTSequenceDocument -Line `$line -Path 'C:\ws\Control\DEMO-05\sequence.yaml'"
            )
        }
    }

    Context 'an edit that is not a rename' {

        BeforeAll {
            $script:one = Get-HDTConsoleSequenceSave -Path 'C:\ws\Control\DEMO-05\sequence.yaml' -Pending @(
                [pscustomobject] @{ Property = 'description'; Value = 'a bare metal client' }
            )
        }

        It 'does not ask for the expensive rebuild' {
            $script:one.Renamed | Should -BeFalse
        }

        It 'still echoes the save' {
            @($script:one.Command).Count | Should -Be 2
            @($script:one.Command)[-1] |
                Should -BeExactly "Save-HDTSequenceDocument -Line `$line -Path 'C:\ws\Control\DEMO-05\sequence.yaml'"
        }
    }

    Context 'a camel-cased key' {

        It 'capitalises only its first letter' {
            $answer = Get-HDTConsoleSequenceSave -Path 'C:\ws\s.yaml' -Pending @(
                [pscustomobject] @{ Property = 'timeoutMinutes'; Value = '90' })

            $answer.Edit[0].Parameter | Should -BeExactly 'TimeoutMinutes'
        }
    }

    Context 'nothing edited' {

        It 'asks for no edits' {
            $answer = Get-HDTConsoleSequenceSave -Path 'C:\ws\s.yaml' -Pending @()

            @($answer.Edit).Count | Should -Be 0
        }

        It 'echoes nothing at all rather than a save of no changes' {
            # A press with nothing pending never reaches the document, so a
            # Save line in the box would name a write that did not happen.
            $answer = Get-HDTConsoleSequenceSave -Path 'C:\ws\s.yaml' -Pending @()

            @($answer.Command).Count | Should -Be 0
            $answer.Renamed | Should -BeFalse
        }
    }

    Context 'the rename among several edits' {

        It 'is reported wherever in the list it falls' {
            $answer = Get-HDTConsoleSequenceSave -Path 'C:\ws\s.yaml' -Pending @(
                [pscustomobject] @{ Property = 'description'; Value = 'x' }
                [pscustomobject] @{ Property = 'name'; Value = 'y' }
            )

            $answer.Renamed | Should -BeTrue
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleSequenceSave -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleSequenceSave'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
