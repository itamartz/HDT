# The tree's right-click menu: which rows open one, and what is on it.
#
# THIS FILE EXISTS BECAUSE NOTHING TESTED THE MENU AT ALL, and the gap cost a
# defect that reached the administrator's screen. A menu item was added and made
# Visible for its row, and right-clicking that row still did nothing:
# ContextMenuOpening cancels the WHOLE menu for any row kind not in one list,
# and the new kind was not in it. An item that is Visible on a cancelled menu is
# invisible in the only sense that matters.
#
# THE DECISION IS A COMMAND SO THAT PESTER CAN REACH IT. It used to be a line
# inside a closure hung off a TreeView, where the only thing that could see it
# was a person with a mouse - which is how it shipped. ContextMenuEventArgs has
# only internal constructors, so raising the event from a test is not a thing
# this repository is going to do; moving the decision out is.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:ask = {
        param([string] $Kind, [string] $Name, [bool] $Folder = $false, [string] $DriverPath = '')

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($K, $N, $F, $D)
            Get-HDTConsoleTreeMenuRow -Kind $K -Name $N -HasFolderAction $F -DriverPath $D
        } $Kind $Name $Folder $DriverPath
    }
}

Describe 'Get-HDTConsoleTreeMenuRow' {

    Context 'whether the row opens a menu at all' {

        # THE ONE THAT WOULD HAVE CAUGHT IT.
        It 'opens one on the Selection Profiles category' {
            (& $script:ask 'Category' 'SelectionProfiles').Opens | Should -BeTrue
        }

        It 'opens one on a profile row' {
            (& $script:ask 'SelectionProfile' 'boot-critical').Opens | Should -BeTrue
        }

        It 'opens one on every kind that has an item' {
            foreach ($kind in @('Root', 'Share', 'Category', 'TaskSequence',
                    'OperatingSystem', 'Application', 'BootImage', 'Folder')) {

                (& $script:ask $kind '').Opens |
                    Should -BeTrue -Because "$kind has items on the menu"
            }
        }

        # A ROW WITH NOTHING TO OFFER STILL OPENS NO MENU. A menu that appears
        # everywhere with one live item teaches that right-click does nothing
        # here, on the rows where it does something.
        It 'opens none on a row with nothing to offer' {
            (& $script:ask 'Step' 'Apply OS').Opens | Should -BeFalse
            (& $script:ask 'Empty' '').Opens | Should -BeFalse
            (& $script:ask 'MonitorRun' 'PC-0001').Opens | Should -BeFalse
        }

        # THE FOLDER ITEMS ARE DECIDED ELSEWHERE and arrive as a flag, but they
        # are a reason to open a menu like any other.
        It 'opens one for a row the folder items apply to' {
            (& $script:ask 'Step' 'Apply OS' $true).Opens | Should -BeTrue
        }
    }

    Context 'the selection profile item' {

        It 'is on the category and on a profile row' {
            (& $script:ask 'Category' 'SelectionProfiles').IsSelectionProfile | Should -BeTrue
            (& $script:ask 'SelectionProfile' 'boot-critical').IsSelectionProfile | Should -BeTrue
        }

        # A CATEGORY IS TOLD FROM A CATEGORY BY ITS NAME, never by its label -
        # the label carries a count.
        It 'is not on another category' {
            (& $script:ask 'Category' 'TaskSequences').IsSelectionProfile | Should -BeFalse
            (& $script:ask 'Category' 'Applications').IsSelectionProfile | Should -BeFalse
        }

        # THE LABEL SAYS WHICH OF THE TWO THINGS YOU CAME FOR. On the category it
        # is New, because that is Workbench's wording and creating is why anybody
        # opens that node - 'Selection Profiles' there reads as a place rather
        # than an action, and somebody looking for New does not find it.
        It 'says New on the category' {
            (& $script:ask 'Category' 'SelectionProfiles').SelectionProfileHeader |
                Should -BeExactly 'New Selection Profile'
        }

        It 'says the manager on a profile row, which already exists' {
            (& $script:ask 'SelectionProfile' 'boot-critical').SelectionProfileHeader |
                Should -BeExactly 'Selection Profiles'
        }
    }

    Context 'the driver store items' {

        # MDT HANGS New Folder AND Import Drivers OFF BOTH, and for the reason it
        # does: a vendor WinPE pack goes under WinPE\ and a model pack goes under
        # a Make, so the row you right-click is the parent you meant.
        It 'is on the Drivers category' {
            $row = & $script:ask 'Category' 'Drivers'

            $row.IsDriverRow | Should -BeTrue
            $row.Opens | Should -BeTrue
        }

        It 'is on a folder inside the store' {
            $row = & $script:ask 'DriverFolder' 'Drivers\WinPE' $false 'Drivers\WinPE'

            $row.IsDriverRow | Should -BeTrue
        }

        # A FOLDER ROW ELSEWHERE IN THE TREE IS NOT A DRIVER FOLDER. Applications
        # and task sequences have folders too, and importing a vendor pack into
        # one would be nonsense.
        It 'is not on a folder that belongs to something else' {
            (& $script:ask 'Folder' 'Applications\Utilities' $false 'Applications\Utilities').IsDriverRow |
                Should -BeFalse
        }

        # WHERE THE NEW FOLDER LANDS, relative to Drivers\. The category is the
        # store's root, so it contributes nothing to the path.
        It 'puts a new folder at the store root from the category' {
            (& $script:ask 'Category' 'Drivers').DriverParent | Should -BeExactly ''
        }

        It 'puts it under the folder that was right-clicked' {
            (& $script:ask 'DriverFolder' 'Drivers\WinPE' $false 'Drivers\WinPE').DriverParent |
                Should -BeExactly 'WinPE'
        }

        It 'keeps a nested path whole' {
            (& $script:ask 'DriverFolder' 'Drivers\Dell\Latitude 7450' $false 'Drivers\Dell\Latitude 7450').DriverParent |
                Should -BeExactly 'Dell\Latitude 7450'
        }
    }
}
