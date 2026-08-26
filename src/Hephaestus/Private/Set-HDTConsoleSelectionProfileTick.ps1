function Set-HDTConsoleSelectionProfileTick {
    <#
        .SYNOPSIS
            What the include list becomes when one tick box is clicked.

        .DESCRIPTION
            THE THIRD HALF OF THE TICK BOX TREE, and the only one that has to
            think. Get-HDTConsoleSelectionProfileTree turns an include list into
            ticks and Get-HDTConsoleSelectionProfileInclude turns ticks back into
            a list; neither knows what a CLICK means, and the window had nothing
            behind the box at all - IsChecked was bound straight to the node's
            State with no handler. So ticking 'Drivers\WinPE' set that one box
            and left Dell and HP blank underneath it, while Save included the
            whole branch. The tree was describing a different injection from the
            one that would happen.

            TICKING ON IS NEARLY FREE. An include already means the folder and
            everything under it, so anything included BELOW the folder is now
            said twice and comes out; and if an ancestor is already included,
            this folder is already in and the list does not change at all.

            TICKING OFF IS THE ONE THAT NEEDS WORK, because when an ANCESTOR is
            the thing in the list there is nothing to remove. 'Drivers\WinPE' is
            included and somebody unticks HP: what the profile now means is Dell
            and not HP, and the only way to say that is to stop naming the parent
            and start naming the children that stay - at every level between the
            included ancestor and the folder being turned off.

            IT NEVER COLLAPSES SIBLINGS BACK INTO A PARENT, which is
            Get-HDTConsoleSelectionProfileInclude's rule and matters here for its
            reason: a parent includes whatever is added to it later, so a vendor
            pack dropped into Drivers\WinPE next month would arrive in the boot
            image unasked. Naming Dell means Dell.

            IT IS PURE, and it takes the FOLDER LIST rather than the tree so a
            test can decide what a click means with no window, no share and no
            node objects to build.

        .PARAMETER Folder
            Every content folder on the share, as Get-HDTShareContentFolder
            answers - each with Path, Name and Depth.

        .PARAMETER Include
            The profile's include list as it stands.

        .PARAMETER Path
            The folder whose box was clicked, share-relative.

        .PARAMETER State
            $true for ticked, $false for cleared.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the new include list, in the share's own order.

        .EXAMPLE
            Set-HDTConsoleSelectionProfileTick -Folder $folder -Include @('Drivers\WinPE') `
                -Path 'Drivers\WinPE\HP' -State $false

            Drivers\WinPE\Dell - the parent expanded into what is left.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new include list; it writes nothing and touches nothing.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Folder,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Include,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 3)]
        [bool] $State
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE SHARE'S OWN ORDER, kept: a saved profile reads down the page the way
    # the tree does, and the same ticks always produce the same document.
    $order = @{}
    $at = 0

    foreach ($current in @($Folder)) {
        if ($null -eq $current) { continue }
        $order[[string] $current.Path] = $at
        $at++
    }

    $sort = {
        param([object[]] $Path)

        return @($Path | Sort-Object -Property @{ Expression = {
                    if ($order.ContainsKey([string] $_)) { return [int] $order[[string] $_] }
                    return [int]::MaxValue
                }
            }, @{ Expression = { [string] $_ } })
    }

    $under = {
        param([string] $Parent, [string] $Child)

        return ([string] $Child).StartsWith(([string] $Parent) + '\')
    }

    $current = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in @($Include)) {
        if ([string]::IsNullOrWhiteSpace($one)) { continue }
        if ($current -notcontains ([string] $one)) { [void] $current.Add([string] $one) }
    }

    if ($State) {
        # ALREADY IN, THROUGH AN ANCESTOR: nothing to say.
        foreach ($one in @($current)) {
            if (& $under ([string] $one) $Path) { return [string[]] @(& $sort $current) }
        }

        # SAID TWICE OTHERWISE: everything under it comes out, and it goes in.
        $kept = @($current | Where-Object { -not (& $under $Path ([string] $_)) -and ([string] $_) -ne $Path })

        $result = New-Object -TypeName System.Collections.ArrayList
        foreach ($one in @($kept)) { [void] $result.Add([string] $one) }
        [void] $result.Add($Path)

        return [string[]] @(& $sort $result)
    }

    # -- clearing -------------------------------------------------------------

    # IN THE LIST IN ITS OWN RIGHT, or covered by an ancestor. Anything under it
    # goes too: it cannot stay included by a branch that is being turned off.
    $ancestor = @($current | Where-Object { & $under ([string] $_) $Path })

    $kept = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in @($current)) {
        $text = [string] $one

        if ($text -eq $Path) { continue }
        if (& $under $Path $text) { continue }
        if ($ancestor -contains $text) { continue }

        [void] $kept.Add($text)
    }

    # THE ANCESTORS EXPANDED, one level at a time down the chain toward the
    # folder being cleared. At each level every sibling that is NOT on that chain
    # stays included by name; the one that is gets walked into.
    foreach ($one in @($ancestor)) {
        $chain = [string] $one

        while ($chain -ne $Path) {
            # THE NEXT LEVEL DOWN THAT LEADS TO $Path. Its siblings are what the
            # profile still wants, said by name because the parent no longer
            # says it for them.
            $next = ''

            foreach ($candidate in @($Folder)) {
                if ($null -eq $candidate) { continue }

                $each = [string] $candidate.Path

                if (-not (& $under $chain $each)) { continue }
                if (($each -ne $Path) -and -not (& $under $each $Path)) { continue }

                # A DIRECT CHILD OF $chain, and nothing deeper.
                $tail = $each.Substring($chain.Length + 1)
                if ($tail.Contains('\')) { continue }

                $next = $each
                break
            }

            # THE SHARE DOES NOT HOLD THE CHAIN. Nothing sensible is left to
            # expand into, so the ancestor simply goes and the branch is out.
            if ([string]::IsNullOrEmpty($next)) { break }

            foreach ($candidate in @($Folder)) {
                if ($null -eq $candidate) { continue }

                $each = [string] $candidate.Path

                if (-not (& $under $chain $each)) { continue }

                $tail = $each.Substring($chain.Length + 1)
                if ($tail.Contains('\')) { continue }
                if ($each -eq $next) { continue }

                if ($kept -notcontains $each) { [void] $kept.Add($each) }
            }

            $chain = $next
        }
    }

    return [string[]] @(& $sort $kept)
}
