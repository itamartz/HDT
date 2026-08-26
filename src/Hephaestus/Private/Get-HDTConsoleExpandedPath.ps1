function Get-HDTConsoleExpandedPath {
    <#
        .SYNOPSIS
            Which branches of the console tree are open, as paths that survive a
            rebuild.

        .DESCRIPTION
            THE TREE IS REBUILT FROM SCRATCH AFTER EVERY EDIT, because what is on
            screen has to be what the ENGINE reads back rather than a patched
            copy of what it read before. Every node is a new object, so
            IsExpanded - which the window binds TwoWay and a person changes by
            clicking a chevron - is lost with the objects it was set on.

            THAT DID NOT SHOW WHILE EVERY BRANCH OPENED EXPANDED. The console
            now opens folded, which is Workbench's shape and the point of the
            change; without this, renaming a task sequence would fold the tree
            back up around the person doing it.

            A PATH AND NOT AN OBJECT, for the same reason the selection is
            restored by name: the object is gone. 'Deployment Shares (1)\HDT
            deployment share\Drivers' names a branch in a tree nobody has built
            yet, which is exactly what is needed.

            THE TEXT IS THE KEY, INCLUDING ITS COUNT. A category's row says
            'Applications (2)', and after adding one it says 'Applications (3)' -
            so a branch whose count changed comes back folded. That is the honest
            trade for a key that needs nothing stamped on the row, and the
            alternative - keying on Kind and Name - collapses two folders called
            'Clients' under different categories into one.

        .PARAMETER Node
            The root rows the tree is bound to. Children are walked from each.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - one path per expanded branch, parents first.

        .EXAMPLE
            $open = Get-HDTConsoleExpandedPath -Node $tree.ItemsSource
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Node
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $found = New-Object -TypeName System.Collections.ArrayList

    # RECURSION BY HAND. A nested function would not be reachable from the
    # scriptblock the console calls this through, and the tree is four deep.
    $walk = New-Object -TypeName System.Collections.Stack

    foreach ($row in @($Node)) {
        if ($null -eq $row) { continue }
        $walk.Push([pscustomobject] @{ Row = $row; Path = [string] $row.Text })
    }

    while ($walk.Count -gt 0) {
        $current = $walk.Pop()
        $row = $current.Row

        $open = $false
        if ($null -ne $row.PSObject.Properties['IsExpanded']) { $open = [bool] $row.IsExpanded }

        if ($open) { [void] $found.Add([string] $current.Path) }

        if ($null -eq $row.PSObject.Properties['Children']) { continue }

        foreach ($child in @($row.Children)) {
            if ($null -eq $child) { continue }

            $walk.Push([pscustomobject] @{
                    Row  = $child
                    Path = ('{0}\{1}' -f [string] $current.Path, [string] $child.Text)
                })
        }
    }

    return [string[]] @($found)
}
