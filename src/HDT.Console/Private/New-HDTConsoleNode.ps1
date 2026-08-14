function New-HDTConsoleNode {
    <#
        .SYNOPSIS
            Builds one display row for the console window.

        .DESCRIPTION
            One row shape, built in one place, so the host can treat every row
            identically and no caller can invent a row missing the member the
            window binds to.

            DISPLAY IS BUILT HERE AND NOT IN THE WINDOW. The list is a flat
            ListBox in a monospaced font, and Display is Text with its
            indentation already applied - four spaces per level. The alternative
            is a TreeView built by the host, or a Margin binding with a value
            converter, and both put layout decisions inside the one component
            that cannot be unit tested. Indentation is a string, and a string is
            assertable.

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

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Depth, Kind,
            Status, Text, Display, Detail, Command, HeaderTitle, HeaderRoot and
            HeaderDeployRoot.

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
        [object] $Header
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
        HeaderTitle      = [string] $Header.Title
        HeaderRoot       = [string] $Header.Root
        HeaderDeployRoot = [string] $Header.DeployRoot
    }
}
