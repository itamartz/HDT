function Set-HDTConsoleExpandedPath {
    <#
        .SYNOPSIS
            Reopens the branches that were open before the tree was rebuilt.

        .DESCRIPTION
            THE OTHER HALF OF Get-HDTConsoleExpandedPath. The tree is rebuilt
            from scratch after every edit and the console now opens FOLDED, so
            without this a rename would fold the tree back up around the person
            doing it.

            IT SETS AND NEVER CLEARS. A branch the list does not name is left as
            the builder made it, which is folded on the first build and whatever
            it already was on a rebuild. Clearing would fight the -Collapsed
            switch on the first build and undo a chevron somebody clicked on
            every one after it.

            A BRANCH THAT NO LONGER EXISTS IS NOT AN ERROR. Deleting a folder is
            an ordinary reason for a path to stop matching, and a refusal there
            would turn a successful delete into a message about the tree.

        .PARAMETER Node
            The rebuilt root rows.

        .PARAMETER Path
            What Get-HDTConsoleExpandedPath returned before the rebuild.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Int32 - how many branches were reopened, which is what a test
            asserts on.

        .EXAMPLE
            $open = Get-HDTConsoleExpandedPath -Node $tree.ItemsSource
            $rebuilt = Get-HDTConsoleTreeNode -Workspace $workspace
            [void] (Set-HDTConsoleExpandedPath -Node $rebuilt -Path $open)
    #>
    # IT CHANGES A CHEVRON, NOT THE SYSTEM. The only thing this writes is
    # IsExpanded on rows the caller has just built and not yet shown; there is
    # nothing on disk, on a share or on a machine to confirm before doing it, and
    # a -WhatIf that declined to open a branch would be a prompt about a
    # triangle.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets IsExpanded on in-memory view rows; touches nothing outside the window.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Node,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $wanted = @{}
    foreach ($one in @($Path)) {
        if ([string]::IsNullOrEmpty($one)) { continue }
        $wanted[[string] $one] = $true
    }

    if ($wanted.Count -eq 0) { return 0 }

    $opened = 0
    $walk = New-Object -TypeName System.Collections.Stack

    foreach ($row in @($Node)) {
        if ($null -eq $row) { continue }
        $walk.Push([pscustomobject] @{ Row = $row; Path = [string] $row.Text })
    }

    while ($walk.Count -gt 0) {
        $current = $walk.Pop()
        $row = $current.Row

        if ($wanted.ContainsKey([string] $current.Path)) {
            if ($null -ne $row.PSObject.Properties['IsExpanded']) {
                $row.IsExpanded = $true
                $opened++
            }
        }

        if ($null -eq $row.PSObject.Properties['Children']) { continue }

        foreach ($child in @($row.Children)) {
            if ($null -eq $child) { continue }

            $walk.Push([pscustomobject] @{
                    Row  = $child
                    Path = ('{0}\{1}' -f [string] $current.Path, [string] $child.Text)
                })
        }
    }

    return [int] $opened
}
