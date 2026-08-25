function Get-HDTConsoleSelectionProfileInclude {
    <#
        .SYNOPSIS
            The include list a ticked tree means.

        .DESCRIPTION
            THE OTHER HALF OF THE TICK BOX TREE. Get-HDTConsoleSelectionProfileTree
            turns an include list into ticks; this turns ticks back into an
            include list, and Save writes what it returns.

            IT RETURNS THE SHALLOWEST TICKED FOLDERS AND NOTHING BELOW THEM. An
            include already means "this folder and everything under it", so
            listing a ticked child of a ticked parent would be a second way to
            say the same thing - and the two would disagree the moment somebody
            edited one of them by hand.

            A PARENT WHOSE CHILDREN ARE ALL TICKED IS NOT ITSELF TICKED, which
            is what the tree's square rule already established and this relies
            on. Collapsing "every child" up into "the parent" would change what
            the profile MEANS: the parent includes anything added to it later,
            and a vendor pack dropped into Drivers\WinPE next month would arrive
            in the boot image unasked.

            IT KEEPS THE TREE'S ORDER, which is the share's own order, so a
            saved profile reads down the page the way the tree does. Driver
            injection order is the author's and a profile that listed a storage
            pack before a network pack meant that - but a tree cannot express
            order, so what it can offer is stability: the same ticks always
            produce the same document.

            IT IS PURE, so Pester decides what a Save would write with no window
            and no share.

        .PARAMETER Tree
            The tree roots, as Get-HDTConsoleSelectionProfileTree returned them -
            each node carrying State and Children.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - share-relative paths, parents before children,
            never both.

        .EXAMPLE
            Get-HDTConsoleSelectionProfileInclude -Tree $view.Tree

        .EXAMPLE
            Set-HDTSelectionProfile -Line $line -Id 'boot-critical' -Include (Get-HDTConsoleSelectionProfileInclude -Tree $view.Tree)

            What the Save button runs.

        .LINK
            Get-HDTConsoleSelectionProfileTree
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Tree
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $path = New-Object -TypeName System.Collections.ArrayList

    $walk = {
        param([object[]] $Node)

        foreach ($current in @($Node)) {
            # $true stops the descent: everything below it is already included.
            # $null - the square - is the case that has ticks further down.
            # $false has nothing below it worth walking, because the tree only
            # gives a parent $false when no descendant is ticked.
            if ($true -eq $current.State) {
                [void] $path.Add([string] $current.Path)
                continue
            }

            if ($null -eq $current.State) {
                & $walk ([object[]] @($current.Children))
            }
        }
    }

    & $walk ([object[]] @($Tree))

    return [string[]] @($path)
}
