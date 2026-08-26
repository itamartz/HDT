# WHETHER THE DRIVER WINDOW HAS ANYTHING TO SAVE, and what it should say about
# it.
#
# THIS EXISTS BECAUSE SAVE GAVE NO ANSWER. Unticking the box and pressing Save
# wrote the document and then left the window looking exactly as it had a moment
# earlier - same button, same text, nothing to say whether the press had landed.
# A button that looks identical before and after is one somebody presses twice
# and then goes to the share to check by hand.
#
# THE DECISION IS HERE RATHER THAN IN THE HANDLER, the same split
# Get-HDTConsoleEditorState uses: a click has no test, and this does.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    Describe 'Get-HDTConsoleDriverSaveState' {

        Context 'a window that has just opened' {

            BeforeAll {
                $script:opened = Get-HDTConsoleDriverSaveState -Enabled $true -Saved $true `
                    -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf'
            }

            It 'has nothing to save' {
                $script:opened.Dirty | Should -BeFalse
                $script:opened.CanSave | Should -BeFalse
            }

            # NOTHING TO SAY IS SAID WITH NOTHING. A status line that reads
            # 'Saved' on a window nobody has touched is a window claiming credit
            # for a write it did not do.
            It 'says nothing, because nothing has happened yet' {
                $script:opened.Status | Should -BeExactly ''
            }

            # THE COMMAND IS SHOWN EVEN WHEN IT CANNOT BE RUN. The command bar
            # is what teaches the cmdlet behind the window, and hiding it until
            # somebody edits something teaches it to nobody.
            It 'still shows the command the button would run' {
                $script:opened.Command |
                    Should -BeExactly "Set-HDTDriverState -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf' -Enabled `$true"
            }
        }

        Context 'the box unticked and not yet saved' {

            BeforeAll {
                $script:dirty = Get-HDTConsoleDriverSaveState -Enabled $false -Saved $true `
                    -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf'
            }

            It 'has something to save' {
                $script:dirty.Dirty | Should -BeTrue
                $script:dirty.CanSave | Should -BeTrue
            }

            It 'says so' {
                $script:dirty.Status | Should -BeExactly 'Unsaved change'
            }

            It 'shows the command with the value the box now carries' {
                $script:dirty.Command | Should -BeLike '*-Enabled $false'
            }
        }

        Context 'straight after the write' {

            BeforeAll {
                $script:written = Get-HDTConsoleDriverSaveState -Enabled $false -Saved $false `
                    -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf' -Written
            }

            It 'has nothing left to save' {
                $script:written.Dirty | Should -BeFalse
                $script:written.CanSave | Should -BeFalse
            }

            It 'says the write happened' {
                $script:written.Status | Should -BeExactly 'Saved'
            }
        }

        # A SAVE DOES NOT KEEP SAYING 'Saved'. Ticking the box again after a
        # write puts the window back out of step with the share, and a status
        # line still claiming the write would be describing a state the share is
        # not in.
        Context 'the box ticked again after a write' {

            BeforeAll {
                $script:again = Get-HDTConsoleDriverSaveState -Enabled $true -Saved $false `
                    -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\e1d.inf' -Written
            }

            It 'has something to save once more' {
                $script:again.CanSave | Should -BeTrue
            }

            It 'stops claiming the earlier write' {
                $script:again.Status | Should -BeExactly 'Unsaved change'
            }
        }

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Get-HDTConsoleDriverSaveState -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTConsoleDriverSaveState'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
