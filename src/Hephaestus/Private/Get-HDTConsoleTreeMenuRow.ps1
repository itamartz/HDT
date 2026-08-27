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
            IsSelectionProfile and SelectionProfileHeader.

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
    $offers = @('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem',
        'Application', 'BootImage', 'Folder', 'MonitorRun')

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

    $opens = ($offers -contains $Kind) -or $isSelectionProfile -or $isDriverRow -or $HasFolderAction

    return [pscustomobject] @{
        Opens                  = [bool] $opens
        IsSelectionProfile     = [bool] $isSelectionProfile
        SelectionProfileHeader = [string] $header
        IsDriverRow            = [bool] $isDriverRow
        DriverParent           = [string] $under
    }
}
