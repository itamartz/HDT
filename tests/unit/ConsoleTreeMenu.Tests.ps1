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
                    'OperatingSystem', 'Application', 'BootImage', 'Folder',
                    'MonitorRun')) {

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
        }

        # A MONITORED RUN USED TO BE ON THE LIST ABOVE, and it belonged there
        # while nothing could be done to one. Clear Run is what changed it: the
        # engine writes a heartbeat per deployment and nothing ever removed one,
        # so a share that had built fifty machines drew fifty rows with the live
        # one somewhere among them. See tests/unit/MonitorRunRemoval.Tests.ps1.
        It 'opens one on a monitored run, which can now be cleared' {
            (& $script:ask 'MonitorRun' 'PC-0001').Opens | Should -BeTrue
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

# ---------------------------------------------------------------------------
#
# THE WINDOWS UPDATES NODE, WHICH SHIPPED WITH NO MENU AT ALL. The feature
# built its tree node, its detail pane and its import dialog, and the dialog
# was never reachable: HDTImportWindowsUpdate.xaml and
# New-HDTConsoleHost.ShowImportWindowsUpdate both existed and nothing on the
# window opened either. Right-clicking an update did nothing, which is the
# defect this whole file was written for, a second time.

Describe 'the Windows Updates rows' {

    # MDT'S Packages NODE, and its Import OS Packages wizard hangs off it. The
    # dialog is written; this is the row that has to offer it.
    Context 'Import Windows Update' {

        It 'is on the Windows Updates category' {
            $row = & $script:ask 'Category' 'WindowsUpdates'

            $row.Opens | Should -BeTrue
            $row.IsUpdateRow | Should -BeTrue
        }

        # THE ROW YOU RIGHT-CLICK IS THE RELEASE YOU MEANT, which is the driver
        # store's reason for hanging Import Drivers off every folder as well as
        # the category.
        It 'is on a release group too' {
            $row = & $script:ask 'UpdateRelease' 'Win11-24H2'

            $row.Opens | Should -BeTrue
            $row.IsUpdateRow | Should -BeTrue
        }

        # AND IT PRESELECTS THAT RELEASE. -Release is mandatory on
        # Import-HDTWindowsUpdate because no .msu says which operating system it
        # is for, and the dialog deliberately preselects nothing when it is
        # opened from the category - defaulting to the first row is how a server
        # update gets filed under a client release. Right-clicking Windows
        # Server 2025 is not that: it is the administrator naming the release.
        It 'carries the release the row is for' {
            (& $script:ask 'UpdateRelease' 'WS2025').UpdateRelease |
                Should -BeExactly 'WS2025'
        }

        It 'names no release from the category, where nothing has been chosen' {
            (& $script:ask 'Category' 'WindowsUpdates').UpdateRelease |
                Should -BeExactly ''
        }

        # NO New Folder HERE, AND THE ABSENCE IS THE DECISION. The store is flat
        # - WindowsUpdates\<id>\update.yaml with the .msu beside it - and the
        # release rows are COMPUTED from what the updates say rather than from a
        # folder anybody made. Add-HDTWorkspaceFolder takes TaskSequence,
        # OperatingSystem and Application and nothing else, so a New Folder item
        # here would be one with no command behind it.
        It 'offers no folder actions, because the update store has no folders' {
            (& $script:ask 'Category' 'WindowsUpdates').IsDriverRow | Should -BeFalse
            (& $script:ask 'UpdateRelease' 'Win11-24H2').IsDriverRow | Should -BeFalse
        }
    }

    Context 'Remove Windows Update' {

        It 'is on an individual update, which is a folder on the share' {
            $row = & $script:ask 'WindowsUpdate' 'KB5094126-x64'

            $row.Opens | Should -BeTrue
            $row.IsWindowsUpdate | Should -BeTrue
        }

        # A RELEASE IS NOT A THING ON DISK. It is drawn from what the updates
        # under it say, so there is nothing to remove and nothing to rename -
        # removing one would have to mean removing every update in it, which is
        # a different press from the one somebody thinks they are making.
        It 'is not on a release group, which nothing created' {
            (& $script:ask 'UpdateRelease' 'Win11-24H2').IsWindowsUpdate | Should -BeFalse
        }

        It 'is not on the category' {
            (& $script:ask 'Category' 'WindowsUpdates').IsWindowsUpdate | Should -BeFalse
        }
    }
}

# ---------------------------------------------------------------------------
#
# THE SET, NOT THE ONE THAT JUST BROKE.
#
# The Windows Updates node had no menu because a hand-written list of kinds sat
# in one file and a new feature did not reach it. A test naming WindowsUpdate
# would pass for WindowsUpdate and fail nobody after it, so this walks the kinds
# the tree can actually EMIT - read out of the node builders, not typed here -
# and makes each one account for itself: it offers a menu, or it is on the list
# below with a reason.
#
# ADDING A KIND FAILS THIS UNTIL SOMEBODY DECIDES. That is the whole point. The
# decision may perfectly well be "nothing to offer" - write it down and the test
# goes green.

# READ AT DISCOVERY TIME, AND HANDED TO EACH It THROUGH -ForEach. Pester 5 runs
# this file once to discover and again to execute, and a $script: variable set
# out here does not survive into the second pass - so everything the assertions
# need travels in the -ForEach row rather than being looked up from one.
$script:privateRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
    -ChildPath 'src\Hephaestus\Private'

# NEW-HDTCONSOLENODE IS WHAT MAKES A ROW, so -Kind on a call to it is what the
# tree can draw. Get-HDTConsoleIcon takes a -Kind too and takes several the tree
# never emits - 'Cab', 'Exe' and 'DriverStore' are glyph names - so the call has
# to be part of the match rather than the parameter alone.
$script:emittedKind = @(
    Get-ChildItem -Path $script:privateRoot -Filter '*.ps1' -File |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) } |
        ForEach-Object { [regex]::Matches($_, "New-HDTConsoleNode[^`r`n]*?-Kind\s+'([A-Za-z]+)'") } |
        ForEach-Object { $_ } |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
)

# EVERY CATEGORY THE SHARE DRAWS. 'Category' is one Kind and seven rows, and the
# menu is decided by the NAME - so the kind alone proves nothing about any of
# them.
$script:categoryName = @('TaskSequences', 'OperatingSystems', 'Applications',
    'BootImage', 'SelectionProfiles', 'Drivers', 'WindowsUpdates', 'Media')

# DELIBERATELY MENU-LESS, AND WHY. Each of these is a decision somebody made,
# not a kind that was forgotten - which is the difference this file exists to
# keep visible.
$script:noMenuReason = @{
    # A PLACEHOLDER FOR A CATEGORY WITH NOTHING IN IT. It stands for no thing on
    # the share, so there is nothing to act on; the actions belong to its parent
    # category, which has its own menu one row up.
    'Empty'           = 'the (none) placeholder stands for nothing on the share'

    # CLEAR RUN IS ON THE RUN AND NEVER HERE. Clearing this row and clearing
    # every run on the share are different actions, and one item that means
    # whichever the mouse happened to be over is how somebody loses the record
    # of a deployment they were still reading.
    'MonitorCategory' = 'Clear Run belongs to the run, not to the node above fifty of them'

    # A STEP IS EDITED IN THE SEQUENCE EDITOR, which the task sequence row
    # opens. The tree draws steps to be read; every action on one is in that
    # window.
    'Step'            = 'steps are edited in the sequence editor, opened from the task sequence row'
    'StepGroup'       = 'groups are edited in the sequence editor, opened from the task sequence row'
}

Describe 'every kind the tree can emit' {

    It 'found the node builders at all, so the rest of this is testing something' -ForEach @(
        @{ Emitted = $script:emittedKind }
    ) {
        @($Emitted).Count | Should -BeGreaterThan 10
        $Emitted | Should -Contain 'WindowsUpdate'
        $Emitted | Should -Contain 'DriverFolder'
    }

    # THE ONE THAT FAILS FOR THE NEXT FEATURE. A kind the tree draws either
    # offers something or has a reason written down for offering nothing, and
    # adding a kind fails this until somebody decides which. That is the whole
    # point: the decision may perfectly well be "nothing to offer" - write it
    # down and this goes green.
    It 'accounts for <Kind> - it offers a menu, or it says why it does not' -ForEach @(
        $script:emittedKind | ForEach-Object {
            $reason = ''
            if ($script:noMenuReason.ContainsKey($_)) { $reason = [string] $script:noMenuReason[$_] }

            @{ Kind = $_; Reason = $reason; Category = $script:categoryName }
        }
    ) {
        # A CATEGORY IS DECIDED BY ITS NAME, never by the kind, so it is asked
        # once per category the share actually draws.
        if ($Kind -eq 'Category') {
            foreach ($category in @($Category)) {
                (& $script:ask 'Category' $category).Opens |
                    Should -BeTrue -Because "the $category category has items on its menu"
            }

            return
        }

        $opens = (& $script:ask $Kind '').Opens

        if (-not [string]::IsNullOrEmpty($Reason)) {
            $opens | Should -BeFalse -Because ('{0} is deliberately menu-less: {1}' -f $Kind, $Reason)
            return
        }

        $opens | Should -BeTrue -Because ("$Kind is a row the tree draws and nothing says it should have " +
            'no menu. Give it its items, or list it in $script:noMenuReason with the reason.')
    }

    # AND THE LIST DOES NOT ROT. A reason left behind for a kind the tree no
    # longer draws reads as a decision and is a leftover.
    It 'still draws <Kind>, which is listed as menu-less' -ForEach @(
        $script:noMenuReason.Keys | ForEach-Object { @{ Kind = $_; Emitted = $script:emittedKind } }
    ) {
        $Emitted | Should -Contain $Kind -Because 'a reason for a kind that is gone is a leftover'
    }
}

# ---------------------------------------------------------------------------
#
# THE MEDIA ROWS, AND THE THIRD TIME THIS LIST HAS BEEN THE DEFECT.
#
# Plans 07-01 and 07-02 built media.yaml, four commands and
# Update-HDTMediaContent. Plan 07-03 put the node on screen. None of that is
# reachable with a mouse unless the Kind is written down in $offers - which is
# the exact shape of the Windows Updates half-feature above, and of the one
# before that.

Describe 'Get-HDTConsoleTreeMenuRow, on the media rows' {

    It 'opens a menu on a Media row, which is a Kind it did not know' {
        (& $script:ask 'Media' 'WIN11-FIELD').Opens | Should -BeTrue
    }

    It 'says a Media row is one, so the window can show Update Media Content on it' {
        (& $script:ask 'Media' 'WIN11-FIELD').IsMediaRow | Should -BeTrue
    }

    # BOTH ROWS OFFER IT, which is the rule the boot image and selection profile
    # rows already follow and for their reason: it is one action on one thing,
    # and which of the two somebody right-clicks when there is one media
    # definition is not worth being wrong about.
    #
    # 'Category' IS ALREADY IN $offers, so Opens on the category proves nothing
    # about this change - IsMediaRow is what carries the category half.
    It 'says the Media category is one too, for the boot image rows'' reason' {
        $row = & $script:ask 'Category' 'Media'

        $row.Opens | Should -BeTrue
        $row.IsMediaRow | Should -BeTrue
    }

    # THE ID IS WHAT THE COMMAND NAMES. An item row carries its own; the
    # category names none, because nothing has been chosen there.
    It 'carries the media id from an item row and none from the category' {
        (& $script:ask 'Media' 'WIN11-FIELD').MediaId | Should -BeExactly 'WIN11-FIELD'
        (& $script:ask 'Category' 'Media').MediaId | Should -BeExactly ''
    }

    It 'says nothing else is a media row' {
        (& $script:ask 'Category' 'Applications').IsMediaRow | Should -BeFalse
        (& $script:ask 'Category' 'SelectionProfiles').IsMediaRow | Should -BeFalse
        (& $script:ask 'OperatingSystem' 'WIN11-LTSC').IsMediaRow | Should -BeFalse
        (& $script:ask 'BootImage' 'HDTPE_x64').IsMediaRow | Should -BeFalse
    }

    # THE REGRESSION GUARD, WRITTEN AGAINST THE SET. A test naming Media passes
    # for Media and fails nobody after it - so this walks every Kind
    # Get-HDTConsoleIcon accepts and compares Opens against what it was, one
    # element at a time. Adding a kind to that set and forgetting this file is
    # then a failure with the kind's name in it.
    It 'still answers exactly as it did for every kind it already knew' {
        $expected = [ordered] @{
            # In $offers, and each of them has items.
            'Root'             = $true
            'Share'            = $true
            'Category'         = $true
            'TaskSequence'     = $true
            'OperatingSystem'  = $true
            'Application'      = $true
            'BootImage'        = $true
            'Folder'           = $true
            'MonitorRun'       = $true
            'UpdateRelease'    = $true
            'WindowsUpdate'    = $true
            'Media'            = $true

            # Decided outside $offers, by a rule of their own.
            'SelectionProfile' = $true
            'DriverFolder'     = $true

            # Deliberately menu-less, each for a reason written down in
            # $script:noMenuReason above.
            'Empty'            = $false
            'StepGroup'        = $false
            'Step'             = $false
            'MonitorCategory'  = $false

            # A GLYPH NAME, NOT A ROW KIND. Get-HDTConsoleIcon takes several the
            # tree never emits; the Drivers category is Kind 'Category' and only
            # asks for this picture.
            'DriverStore'      = $false
        }

        # READ INSIDE THE MODULE, because Get-HDTConsoleIcon is private and this
        # file does not run in module scope - the same hop $script:ask makes.
        $module = Get-Module -Name Hephaestus

        $kind = @(& $module {
                (Get-Command -Name 'Get-HDTConsoleIcon').Parameters['Kind'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues }
            })

        # THE TWO LISTS HAVE TO BE THE SAME LIST, or this passes by testing
        # fewer kinds than exist.
        @($kind | Sort-Object) | Should -Be @(@($expected.Keys) | Sort-Object) `
            -Because 'a Kind with no line here is a Kind whose menu nobody decided'

        foreach ($current in @($kind)) {
            (& $script:ask $current '').Opens |
                Should -Be ([bool] $expected[$current]) -Because ('{0} answered differently' -f $current)
        }
    }
}
