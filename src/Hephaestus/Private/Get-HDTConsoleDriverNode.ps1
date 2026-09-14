function Get-HDTConsoleDriverNode {
    <#
        .SYNOPSIS
            The Drivers category of one share, and the folders its store holds.

        .DESCRIPTION
            The store's own folders, one row per folder at any depth, each showing its
            whole path - because the path on the row is what a selection profile
            includes, so it is what somebody has to be able to read off the screen.

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
            Get-HDTConsoleDriverNode -Workspace $workspace -Header $header
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

    # THE FOLDER, AND AN HONEST SENTENCE ABOUT THE REST. DESIGN 7 describes a
    # driver store and the engine has not built one - there is no Get-HDTDriver
    # and no driver schema. The category is here because this is where it
    # belongs in the order, and because an administrator looking for drivers
    # should find out they are not supported yet from the console rather than
    # from a deployment that silently installs none.

    $driverCommand = "Get-HDTWorkspacePath -Root '{0}' -Kind Drivers" -f $Workspace.Root

    # NAMED AND CARRYING THE SHARE. The window tells this category from the other
    # five by NAME to hang New Folder and Import Drivers off it, and both of
    # those need the share root - which arrives as Subject. Without it the
    # handlers read an empty root and return, so right-clicking offered two items
    # that did nothing.
    $driverCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' -Text 'Drivers' `
        -Name 'Drivers' `
        -Icon (Get-HDTConsoleIcon -Kind 'DriverStore' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $Workspace.Driver.Folder
        New-HDTConsoleField -Label 'Folder exists' -Value (Get-HDTConsoleFlagText -Value $Workspace.Driver.Present)
    ) `
        -Command $driverCommand -Header $Header -Subject $Workspace.Root

    [void] $node.Add($driverCategory)

    # THE FOLDERS THE STORE ACTUALLY HAS. This row used to read '(not supported
    # yet)' and it was true: nothing could read the folder and nothing could
    # inject from it. Both exist now - Import-HDTDriver fills it, a selection
    # profile names a folder in it, and Update-HDTBootImage injects that folder.
    #
    # THE TREE IS FLAT HERE, ONE ROW PER FOLDER AT ANY DEPTH, and each row shows
    # its whole path. A share with 'Dell\Latitude 7450' under 'Drivers\' is two
    # rows in Workbench and two rows here; the path on the row is what a profile
    # includes, so it is what somebody has to be able to read off the screen.
    $driverParent = @{}

    if (@($Workspace.Driver.Tree).Count -eq 0) {
        $emptyText = '(no drivers imported yet)'
        if (-not [bool] $Workspace.Driver.Present) { $emptyText = '(no Drivers folder on this share)' }

        $driverEmptyRow = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text $emptyText `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $Workspace.Driver.Folder
            New-HDTConsoleField -Label 'Folder exists' -Value (Get-HDTConsoleFlagText -Value $Workspace.Driver.Present)
            New-HDTConsoleField -Label '' -Value ('Right-click Drivers to make a folder and import a vendor pack into it. A selection profile then names that folder, and the boot image injects it.')
        ) `
            -Command $driverCommand `
            -Header $Header -Subject $Workspace.Root

        [void] $node.Add($driverEmptyRow)
        [void] $driverCategory.Children.Add($driverEmptyRow)
    }

    foreach ($folder in @($Workspace.Driver.Tree)) {
        # 'Drivers\WinPE\Dell WinPE 11 x64' is depth 2 under Drivers\, and the
        # row's Depth has to put it under its parent rather than under the
        # category - or a two-level store draws as a flat list.
        # THE COMMAND THAT PRODUCED THE ROW, which is DESIGN 12's rule and which
        # this row broke: it showed an Import-HDTDriver line with '<the extracted
        # pack>' in it - a placeholder, so not runnable, and not what produced
        # the row either. Every other row here echoes a real read.
        #
        # WORKED OUT ABOVE THE CALL, NOT INSIDE IT. A comment after a line
        # continuation ENDS the continuation, so the parameters below it stop
        # being part of the call - which is exactly what happened here, and the
        # console failed to draw at all with "missing mandatory parameters:
        # Command Header".
        $folderCommand = "Get-HDTShareContentFolder -Root '{0}' | Where-Object {{ `$_.Path -eq '{1}' }}" -f
        $Workspace.Root, [string] $folder.Path

        $folderRow = New-HDTConsoleNode -Depth (2 + [int] $folder.Depth) -Kind 'DriverFolder' -Status 'Ok' `
            -Name ([string] $folder.Path) `
            -Text ('{0} ({1})' -f [string] $folder.Name, [int] $folder.InfCount) `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value ([string] $folder.Path)
            New-HDTConsoleField -Label 'Drivers' -Value ([int] $folder.InfCount)
            New-HDTConsoleField -Label 'On disk' -Value ([System.IO.Path]::Combine($Workspace.Root, [string] $folder.Path))
        ) `
            -Command $folderCommand `
            -Header $Header -Subject $Workspace.Root

        [void] $node.Add($folderRow)

        $parentPath = [string] (Split-Path -Path ([string] $folder.Path) -Parent)

        if ($driverParent.ContainsKey($parentPath)) {
            [void] $driverParent[$parentPath].Children.Add($folderRow)
        } else {
            [void] $driverCategory.Children.Add($folderRow)
        }

        $driverParent[[string] $folder.Path] = $folderRow
    }

    return [pscustomobject[]] @($node)
}
