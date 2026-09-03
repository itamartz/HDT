function Get-HDTConsoleTreeMenuRow {
    <#
        .SYNOPSIS
            What a tree row's right-click menu offers, and whether it opens at
            all.

        .DESCRIPTION
            THE GUARD THAT DECIDES WHETHER THERE IS A MENU. A row with nothing to
            offer opens none - a menu that appears everywhere with one live item
            teaches that right-click does nothing here, on the rows where it does
            something.

            IT IS A COMMAND AND NOT A LINE IN THE HANDLER BECAUSE IT ALREADY COST
            A DEFECT. A menu item was added and made Visible for its row, and
            right-clicking that row still did nothing: the handler cancels the
            whole menu for any kind not in one list, and the new kind was not in
            it. An item that is Visible on a cancelled menu is invisible in the
            only sense that matters, and nothing could see that but a person with
            a mouse. Here, Pester can.

            THE SELECTION PROFILE LABEL IS DECIDED HERE TOO, because it is the
            same decision. On the CATEGORY it is New - Workbench's wording, and
            creating is why anybody opens that node; 'Selection Profiles' there
            reads as a place rather than an action, and somebody looking for New
            does not find it. On a PROFILE row it is the manager, because that
            row already exists and editing is what is left.

        .PARAMETER Kind
            The row's Kind.

        .PARAMETER Name
            The row's Name. A category is told from a category by it, never by
            its label - the label carries a count.

        .PARAMETER HasFolderAction
            Whether the folder items apply to this row, as
            Get-HDTConsoleFolderAction decided.

        .PARAMETER DriverPath
            The row's driver-store path, when it is one - 'Drivers\WinPE'. It is
            what New Folder hangs a new folder off and what Import Drivers fills.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Opens,
            IsSelectionProfile, SelectionProfileHeader, IsDriverRow,
            DriverParent, IsUpdateRow, IsWindowsUpdate, UpdateRelease,
            IsMediaRow and MediaId.

        .EXAMPLE
            Get-HDTConsoleTreeMenuRow -Kind 'Category' -Name 'SelectionProfiles'

        .EXAMPLE
            (Get-HDTConsoleTreeMenuRow -Kind 'Step' -Name 'Apply OS').Opens

            $false - a step has nothing on this menu, so right-clicking it opens
            nothing at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Kind,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Name = '',

        [Parameter()]
        [bool] $HasFolderAction = $false,

        [Parameter()]
        [AllowEmptyString()]
        [string] $DriverPath = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # BOTH PROFILE ROWS OFFER IT - the category and a profile under it - for the
    # boot image rows' reason: it is one action on one document, and which of the
    # two somebody right-clicks when there are no profiles yet is not worth being
    # wrong about.
    $isProfileCategory = (($Kind -eq 'Category') -and ($Name -eq 'SelectionProfiles'))
    $isSelectionProfile = (($Kind -eq 'SelectionProfile') -or $isProfileCategory)

    $header = 'Selection Profiles'
    if ($isProfileCategory) { $header = 'New Selection Profile' }

    # EVERY KIND THAT HAS SOMETHING ON THE MENU. Adding an item without adding
    # its kind here is the defect this command exists to make impossible.
    # A MONITORED RUN IS HERE BECAUSE IT CAN BE CLEARED. Nothing ever took a
    # heartbeat off this node, so a share that had deployed fifty machines drew
    # fifty rows and the live one was somewhere among them.
    # THE WINDOWS UPDATE ROWS ARE HERE BECAUSE THEY WERE NOT, and that is the
    # second time this exact list has cost the same defect. The Windows Updates
    # feature shipped its tree node, its detail pane, its import dialog
    # (HDTImportWindowsUpdate.xaml) and the host method that opens it - and
    # right-clicking any of it did nothing, because none of its kinds were
    # written down here. Nothing could see that but a person with a mouse, which
    # is how it reached one.
    # AND THE MEDIA ROWS ARE HERE FOR THE THIRD TIME THAT SENTENCE HAS HAD TO BE
    # WRITTEN. Media\<id>\media.yaml, four commands, Update-HDTMediaContent and
    # a tree node were all built before this line existed; every one of them is
    # unreachable with a mouse until the Kind is on this list, and nothing but a
    # person with a mouse can see that it is not.
    $offers = @('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem',
        'Application', 'BootImage', 'Folder', 'MonitorRun',
        'UpdateRelease', 'WindowsUpdate', 'Media')

    # THE DRIVER STORE'S OWN TWO, on the Drivers category and on every folder in
    # it. MDT hangs New Folder and Import Drivers off both, and for the reason it
    # does: a vendor pack goes under WinPE\, and a model pack goes under a Make -
    # so the row you right-click is the parent you meant.
    # A DRIVER FOLDER IS ITS OWN KIND, not a Folder with a telltale path. They
    # look alike and are not: Delete Folder edits a folder: LABEL in a task
    # sequence or an application document, and a driver folder is a real
    # directory - so while they shared a Kind, every folder in the driver store
    # was offered an action that would have edited the wrong thing entirely.
    $isDriverCategory = (($Kind -eq 'Category') -and ($Name -eq 'Drivers'))
    $isDriverFolder = ($Kind -eq 'DriverFolder')
    $isDriverRow = ($isDriverCategory -or $isDriverFolder)

    # WHERE A NEW FOLDER OR AN IMPORT LANDS, relative to Drivers\. The category
    # is the store's root, so it contributes nothing to the path.
    $under = ''
    # THE ROW'S OWN NAME CARRIES IT - 'Drivers\WinPE' - so -DriverPath is only a
    # fallback for a caller that has the path and not the row.
    if ($isDriverFolder) {
        $source = $Name
        if ([string]::IsNullOrWhiteSpace($source)) { $source = $DriverPath }

        $under = ($source -replace '^Drivers\\', '')
    }

    # THE UPDATE STORE'S OWN TWO, and they are NOT the driver store's two with
    # different words on them.
    #
    # IMPORT HANGS OFF THE CATEGORY AND OFF EVERY RELEASE, which is the driver
    # store's rule and it holds here for the driver store's reason: the row you
    # right-click is the release you meant.
    #
    # THERE IS NO NEW FOLDER, AND THE ABSENCE IS THE DECISION. The update store
    # is FLAT - WindowsUpdates\<id>\update.yaml with the .msu beside it - and the
    # release rows are computed from what the updates say rather than from a
    # folder anybody made. Add-HDTWorkspaceFolder takes TaskSequence,
    # OperatingSystem and Application and nothing else, so a New Folder item here
    # would be one with no command behind it - which is worse than no menu.
    $isUpdateCategory = (($Kind -eq 'Category') -and ($Name -eq 'WindowsUpdates'))
    $isUpdateRelease = ($Kind -eq 'UpdateRelease')
    $isUpdateRow = ($isUpdateCategory -or $isUpdateRelease)

    # REMOVE IS ON THE UPDATE AND NEVER ON THE RELEASE ABOVE IT. A release is
    # drawn from what the updates under it say and is not a thing on disk, so
    # removing one could only mean removing every update in it - a different
    # press from the one somebody thinks they are making.
    $isWindowsUpdate = ($Kind -eq 'WindowsUpdate')

    # WHICH RELEASE THE IMPORT DIALOG OPENS ON. The dialog preselects nothing
    # when it is opened from the category, deliberately: -Release is mandatory
    # because no .msu says which operating system it is for, and defaulting to
    # the first row is how a server update gets filed under a client release.
    # Right-clicking a release row is not that - it is the administrator naming
    # the release - so that one row, and only that one, arrives preselected.
    $release = ''
    if ($isUpdateRelease) { $release = $Name }

    # MDT'S Media NODE AND ITS ONE ACTION, Update Media Content.
    #
    # BOTH MEDIA ROWS OFFER IT - the category and an item under it - which is
    # the rule the boot image and selection profile rows already follow and it
    # holds here for their reason: it is one action on one thing, and which of
    # the two somebody right-clicks when there is a single media definition is
    # not worth being wrong about.
    #
    # New Media AND Remove Media ARE DELIBERATELY NOT HERE. They are
    # New-HDTMedia and Remove-HDTMedia at a prompt in this phase; the absence is
    # a deferral written down rather than an item nobody got to.
    $isMediaCategory = (($Kind -eq 'Category') -and ($Name -eq 'Media'))
    $isMedia = ($Kind -eq 'Media')
    $isMediaRow = ($isMediaCategory -or $isMedia)

    # WHICH MEDIA THE ACTION BUILDS. An item row names itself; the category
    # names nothing, because nothing has been chosen there - and the view
    # resolves the category to the ONLY media when the share has exactly one,
    # which is the case where the ambiguity does not exist.
    $mediaId = ''
    if ($isMedia) { $mediaId = $Name }

    $opens = ($offers -contains $Kind) -or $isSelectionProfile -or $isDriverRow -or $HasFolderAction

    return [pscustomobject] @{
        Opens                  = [bool] $opens
        IsSelectionProfile     = [bool] $isSelectionProfile
        SelectionProfileHeader = [string] $header
        IsDriverRow            = [bool] $isDriverRow
        DriverParent           = [string] $under
        IsUpdateRow            = [bool] $isUpdateRow
        IsWindowsUpdate        = [bool] $isWindowsUpdate
        UpdateRelease          = [string] $release
        IsMediaRow             = [bool] $isMediaRow
        MediaId                = [string] $mediaId
    }
}
