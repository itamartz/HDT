# Whether an edit on the details pane should be written at all.
#
# TWO HANDLERS ASK THIS, and they ask it about different gestures. A text box
# commits when focus leaves it; a combo box commits the moment a pick is made,
# because the list closes on the click and there is no "moving focus off it" a
# technician has any reason to cause. Both then have to answer the same
# question, and both used to answer it with their own run of guards.
#
# ASKED FOR, NOT ASSUMED. Not every row in this pane comes from
# New-HDTConsoleField - a monitor row and a share that would not open build
# their own - so Editable may not be there at all. Under Set-StrictMode reading
# a property that is not there is a terminating error ON THE DISPATCHER, which
# takes the whole window down for a click on a box that was never editable in
# the first place. That is why this tests for the property before its value.
#
# UNCHANGED IS NOT AN EDIT. Leaving a box without typing in it raises LostFocus
# exactly like an edit does, and rebuilding the pane raises SelectionChanged
# before the binding has settled. Writing on either would put the document
# through a read-set-save for nothing - and on the combo box, before the
# binding settles, would write a blank over a key that had a value.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Test-HDTConsoleRowCommit' {

    Context 'an editable row that was changed' {

        It 'writes the edit' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'DEMO-05'; Property = 'name' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'DEMO-06' | Should -BeTrue
        }
    }

    Context 'an editable row that was not changed' {

        It 'writes nothing, because leaving a box is not an edit' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'DEMO-05'; Property = 'name' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'DEMO-05' | Should -BeFalse
        }

        It 'compares the whole value, not a prefix of it' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'DEMO-05'; Property = 'name' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'DEMO-050' | Should -BeTrue
        }

        It 'treats a case change as an edit, because a document key is not case folded' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'demo-05'; Property = 'name' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'DEMO-05' | Should -BeTrue
        }
    }

    Context 'a row that is not editable' {

        It 'writes nothing' {
            $row = [pscustomobject] @{ Editable = $false; Original = 'x'; Property = 'name' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'y' | Should -BeFalse
        }
    }

    # THE ONE THAT TAKES THE WINDOW DOWN.
    Context 'a row that never carried an Editable property' {

        It 'answers no rather than throwing on the dispatcher' {
            # A monitor row: built somewhere other than New-HDTConsoleField.
            $row = [pscustomobject] @{ Kind = 'MonitorRun'; Name = 'run-0007' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'anything' | Should -BeFalse
        }

        It 'answers no for a row with no Original either' {
            $row = [pscustomobject] @{ Editable = $true }

            Test-HDTConsoleRowCommit -Row $row -Typed 'anything' | Should -BeFalse
        }
    }

    Context 'no row at all' {

        It 'answers no rather than failing' {
            Test-HDTConsoleRowCommit -Row $null -Typed 'anything' | Should -BeFalse
        }
    }

    # A PICK THAT IS NOT A PICK. Rebuilding the pane raises SelectionChanged with
    # nothing selected, and writing that would clear a key that had a value.
    Context 'a combo box that has settled on nothing' {

        It 'writes nothing when the pick is empty and the row had a value' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'amd64'; Property = 'architecture' }

            Test-HDTConsoleRowCommit -Row $row -Typed '' -Picked | Should -BeFalse
        }

        It 'still writes a real pick' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'amd64'; Property = 'architecture' }

            Test-HDTConsoleRowCommit -Row $row -Typed 'x86' -Picked | Should -BeTrue
        }
    }

    # A TEXT BOX IS NOT A COMBO BOX: emptying one is how a value is cleared.
    Context 'a text box emptied on purpose' {

        It 'writes the empty value' {
            $row = [pscustomobject] @{ Editable = $true; Original = 'something'; Property = 'description' }

            Test-HDTConsoleRowCommit -Row $row -Typed '' | Should -BeTrue
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Test-HDTConsoleRowCommit -ErrorAction Stop

        $help.Name | Should -BeExactly 'Test-HDTConsoleRowCommit'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
