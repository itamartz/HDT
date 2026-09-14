function Get-HDTConsoleOperatingSystemNode {
    <#
        .SYNOPSIS
            The Operating Systems category of one share, and every row under it.

        .DESCRIPTION
            What has been imported, as Workbench's Operating Systems node lists it.
            Everything on a row but the name and the description is a reading of the
            media rather than a decision anybody made, which is why only those two
            carry a Property and so a box that writes.

            ONE CATEGORY, ONE BUILDER - see Get-HDTConsoleShareNode, which composes
            this one with the rest in the order a share is built.

        .PARAMETER Workspace
            The share from Get-HDTConsoleWorkspace this category belongs to.
            The whole projection is passed rather than the one list this
            category draws: the rows carry the share root in their commands and
            some carry the share itself as Subject, so a narrower parameter
            would be three parameters that always travel together.

        .PARAMETER Header
            The banner every node in the tree carries, from
            Get-HDTConsoleHeader.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - the category row
            first, then every row beneath it in display order. The rows are also
            wired into the Children of their parents, so the caller adds the
            whole list to the flat reading and the first row to the tree.

        .EXAMPLE
            Get-HDTConsoleOperatingSystemNode -Workspace $workspace -Header $header
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList


    $osFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind OperatingSystems
    $osCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind OperatingSystems" -f $Workspace.Root

    # NAMED, NOT JUST LABELLED, for the same reason TaskSequences is: the window
    # hangs Import Operating System off this row and must be able to tell it
    # from the other three categories without parsing a label somebody may
    # reword.
    $osCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'OperatingSystems' `
        -Text ('Operating Systems ({0})' -f @($Workspace.OperatingSystem).Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'OperatingSystem' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $osFolder
        New-HDTConsoleField -Label 'Operating Systems' -Value @($Workspace.OperatingSystem).Count
    ) `
        -Command $osCommand -Header $Header

    [void] $node.Add($osCategory)

    $osRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($operatingSystem in @($Workspace.OperatingSystem)) {
        $image = foreach ($current in @($operatingSystem.Image)) {
            '{0,-3} {1} [{2}] {3}' -f $current.Index, $current.Name, $current.Edition, $current.Version
        }

        # THE TWO THAT CAN BE TYPED INTO, as on a task sequence: Workbench edits
        # both on an imported OS's Properties sheet, and everything below them
        # is a reading of the media rather than a decision anybody made. The id
        # is not among them - it is the folder name and what a sequence names to
        # select the image, so changing it is a move.
        $field = @(
            New-HDTConsoleField -Label 'Id' -Value $operatingSystem.Id
            New-HDTConsoleField -Label 'Name' -Value $operatingSystem.Name -Property 'name'
            New-HDTConsoleField -Label 'Description' -Value ([string] $operatingSystem.Description) -Property 'description'
            New-HDTConsoleField -Label 'Type' -Value $operatingSystem.Type
            New-HDTConsoleField -Label 'Architecture' -Value (Get-HDTConsoleDisplayText -Text $operatingSystem.Architecture -Fallback '(not recorded)')
            New-HDTConsoleField -Label 'Default index' -Value $operatingSystem.DefaultIndex
            New-HDTConsoleField -Label ('Images ({0})' -f $operatingSystem.ImageCount) -Value (@($image) -join [System.Environment]::NewLine)
            New-HDTConsoleField -Label 'Source path' -Value $operatingSystem.SourcePath
            New-HDTConsoleField -Label 'Image path' -Value $operatingSystem.ImagePath
            New-HDTConsoleField -Label 'Document' -Value $operatingSystem.Path
        )

        $text = '{0} - {1}' -f $operatingSystem.Id, $operatingSystem.Name
        if ($operatingSystem.Status -eq 'Error') {
            $text = '{0} - (unreadable)' -f $operatingSystem.Id
            $field = @(
                New-HDTConsoleField -Label 'Id' -Value $operatingSystem.Id
                New-HDTConsoleField -Label 'Document' -Value $operatingSystem.Path
                New-HDTConsoleField -Label 'Could not be read' -Value $operatingSystem.Error
            )
        }

        $row = New-HDTConsoleNode -Depth 3 -Kind 'OperatingSystem' -Status $operatingSystem.Status `
            -Text $text -Field $field `
            -Command ("Get-HDTOperatingSystem -WorkspaceRoot '{0}' -Id '{1}'" -f
                $Workspace.Root, $operatingSystem.Id) `
            -Header $Header -Subject $operatingSystem

        # THE FOLDER THE DOCUMENT NAMED, carried on the row so the grouping
        # below can read it without going back to the document.
        $row | Add-Member -MemberType NoteProperty -Name 'Folder' `
            -Value ([string] $operatingSystem.Folder) -Force

        [void] $osRow.Add($row)
    }

    $osGrouped = Group-HDTConsoleFolderRow -Row ([object[]] @($osRow)) -Depth 3 `
        -Declared ([string[]] @($Workspace.Folder.OperatingSystem)) -Category OperatingSystem -Header $Header

    foreach ($current in @($osGrouped.Node)) { [void] $node.Add($current) }
    foreach ($current in @($osGrouped.TopLevel)) { [void] $osCategory.Children.Add($current) }

    if (@($Workspace.OperatingSystem).Count -eq 0) {
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $osFolder
            New-HDTConsoleField -Label '' -Value 'There is no operating system on this share yet. Import one with Import-HDTOperatingSystem; it lands as a folder under the folder above with an os.yaml in it.'
        ) `
            -Command $osCommand -Header $Header

        [void] $node.Add($row)
        [void] $osCategory.Children.Add($row)
    }

    return [pscustomobject[]] @($node)
}
