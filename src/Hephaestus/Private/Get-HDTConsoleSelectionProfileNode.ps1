function Get-HDTConsoleSelectionProfileNode {
    <#
        .SYNOPSIS
            The Selection Profiles category of one share, and every profile in it.

        .DESCRIPTION
            Where MDT puts them: Advanced Configuration, because a profile is
            SHARE-WIDE. DESIGN 13 calls standalone media a content projection of the
            share and a selection profile is that projection's filter, so the same
            document that picks two vendor WinPE packs for a boot image picks which
            applications go on a USB stick.

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
            Get-HDTConsoleSelectionProfileNode -Workspace $workspace -Header $header
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

    # WHERE MDT PUTS THEM: Advanced Configuration, not the Windows PE tab,
    # because a profile is SHARE-WIDE. DESIGN 13 calls standalone media a content
    # projection of the share and a selection profile is that projection's
    # filter, so the same document that picks two vendor WinPE packs for a boot
    # image picks which applications go on a USB stick.
    #
    # THIS IS THE BRANCH THE DRIVERS NODE CANNOT BE. There is still no driver
    # catalog and Drivers\ says so; a profile is a document with a reader behind
    # it, so every row here is something an administrator can act on.

    $profileCommand = "Show-HDTSelectionProfileWindow -Root '{0}'" -f $Workspace.Root

    $profileCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'SelectionProfiles' `
        -Text ('Selection Profiles ({0})' -f @($Workspace.SelectionProfile).Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'SelectionProfile' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Document' -Value (Get-HDTWorkspacePath -Root $Workspace.Root -Kind Control -ChildPath 'selection-profiles.yaml')
        New-HDTConsoleField -Label 'Profiles' -Value @($Workspace.SelectionProfile).Count
    ) `
        -Command $profileCommand -Header $Header -Subject $Workspace.Root

    [void] $node.Add($profileCategory)

    # A DOCUMENT WITH A TYPO IN IT GETS A ROW SAYING SO rather than an empty
    # branch that reads as "you have no profiles".
    if (-not [string]::IsNullOrEmpty([string] $Workspace.SelectionProfileFailure)) {
        $profileFailureRow = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Error' `
            -Text '(the document could not be read)' `
            -Field @(
            New-HDTConsoleField -Label 'Error' -Value ([string] $Workspace.SelectionProfileFailure)
        ) `
            -Command $profileCommand -Header $Header -Subject $Workspace.Root

        [void] $node.Add($profileFailureRow)
        [void] $profileCategory.Children.Add($profileFailureRow)
    }

    foreach ($selection in @($Workspace.SelectionProfile)) {
        # THE PATHS ARE ON THE ROW, because "which folders is this one" is the
        # only question anybody opens this branch to answer.
        $includeText = '(nothing yet)'
        if (@($selection.Include).Count -gt 0) {
            $includeText = (@($selection.Include) -join '; ')
        }

        $kindText = 'authored'
        if ([bool] $selection.IsBuiltIn) { $kindText = 'built in' }

        $profileRow = New-HDTConsoleNode -Depth 3 -Kind 'SelectionProfile' -Status 'Ok' `
            -Name ([string] $selection.Id) `
            -Text ([string] $selection.Name) `
            -Field @(
            New-HDTConsoleField -Label 'Id' -Value ([string] $selection.Id)
            New-HDTConsoleField -Label 'Kind' -Value $kindText
            New-HDTConsoleField -Label 'Included folders' -Value $includeText
        ) `
            -Command $profileCommand -Header $Header -Subject $Workspace.Root

        [void] $node.Add($profileRow)
        [void] $profileCategory.Children.Add($profileRow)
    }

    return [pscustomobject[]] @($node)
}
