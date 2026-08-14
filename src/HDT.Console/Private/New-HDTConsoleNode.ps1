function New-HDTConsoleNode {
    <#
        .SYNOPSIS
            Builds one display row for the console window.

        .DESCRIPTION
            One row shape, built in one place, so the host can treat every row
            identically and no caller can invent a row missing the member the
            window binds to.

            THE ROWS ARE BOTH A TREE AND A LIST, AND BOTH ARE BUILT HERE. The
            window is a WPF TreeView - it expands, it collapses, and each row
            carries an icon, because that is what Deployment Workbench looks like
            and DESIGN 12 asks for muscle memory rather than a novel shape. The
            TreeView needs nesting, so every node carries Children; a test, a
            Format-Table and a screenshot want a flat ordered reading, so every
            node also carries Depth and Display, which is Text with its
            indentation already applied.

            NEITHER SHAPE IS BUILT BY THE HOST. The host binds Children through a
            HierarchicalDataTemplate and reads Icon, Text and IsExpanded from the
            row - it never works out what nests inside what, which node is open,
            or which picture belongs to a task sequence. That is what keeps the
            one component with no tests free of decisions.

            THE HEADER TRAVELS ON THE ROW. The banner above the tree names the
            share the selected row belongs to, and with several shares open that
            changes as the selection moves. Carrying it here means the host sets
            three more text properties from the selected row and still decides
            nothing - the alternative is the host working out which share a row
            came from, which is a branch, in the one component with no tests.

        .PARAMETER Depth
            0 for the root, 1 for a share, 2 for a category, 3 for an item.

        .PARAMETER Kind
            What the row is: Root, Share, Category, TaskSequence,
            OperatingSystem, BootImage or Empty.

        .PARAMETER Status
            Ok, Error or Missing. The window shows the row either way.

        .PARAMETER Text
            The row itself, without indentation.

        .PARAMETER Detail
            The multi-line text the detail pane shows for this row.

        .PARAMETER Command
            The module command that produced the row (DESIGN 12).

        .PARAMETER Header
            What the banner says while this row is selected - Title, Root and
            DeployRoot, as Get-HDTConsoleHeader builds them.

        .PARAMETER Collapsed
            Starts the row closed. Omitted, a row with children opens - C1 has
            one screen's worth of tree and an administrator should see it, not
            hunt for it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Depth, Kind,
            Status, Text, Display, Detail, Command, Icon, IsExpanded, Children,
            HeaderTitle, HeaderRoot and HeaderDeployRoot.

        .EXAMPLE
            New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status 'Ok' -Text 'DEMO-M4 - Deploy Windows 11' -Detail $detail -Command $command -Header $header
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a display row object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 8)]
        [int] $Depth,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'BootImage', 'Empty')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Ok', 'Error', 'Missing')]
        [string] $Status,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Detail,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Header,

        [Parameter()]
        [switch] $Collapsed
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        Depth            = $Depth
        Kind             = $Kind
        Status           = $Status
        Text             = $Text
        Display          = ((' ' * (4 * $Depth)) + $Text)
        Detail           = $Detail
        Command          = $Command
        Icon             = (Get-HDTConsoleIcon -Kind $Kind -Status $Status)
        IsExpanded       = (-not $Collapsed.IsPresent)

        # An ArrayList rather than an array: the tree is assembled by adding to
        # a parent that already exists, and a PowerShell array would be copied
        # on every add, leaving the bound collection behind.
        Children         = [System.Collections.ArrayList]::new()

        HeaderTitle      = [string] $Header.Title
        HeaderRoot       = [string] $Header.Root
        HeaderDeployRoot = [string] $Header.DeployRoot
    }
}
