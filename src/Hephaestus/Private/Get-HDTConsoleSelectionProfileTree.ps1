function Get-HDTConsoleSelectionProfileTree {
    <#
        .SYNOPSIS
            The share's folders as a tick box tree, ticked against one profile's
            include list.

        .DESCRIPTION
            THE SQUARE IS THE WHOLE REASON THIS IS TRI-STATE. Ticking
            Drivers\WinPE and leaving Drivers\Dell alone has to LOOK different
            from ticking Drivers, because those two are a hundred .inf files and
            six hundred - and one of them is a boot image that takes four minutes
            to transfer to every machine that PXE boots. A tick box with two
            states cannot say "some of this", so an administrator would have to
            open every branch to find out what they had actually selected.

            The three states, and what each one means:

              $true   this folder is in the include list, or an ancestor is - so
                      it and everything under it is injected
              $null   some descendant is included and this folder is not - the
                      square
              $false  nothing in this branch is included

            AN INCLUDE MEANS THE FOLDER AND EVERYTHING UNDER IT, which is why an
            ancestor being in the list ticks the children: that is what
            Expand-HDTSelectionProfile hands the build, and what
            Add-WindowsDriver -Recurse then does with it. A tree that showed the
            children unticked would be describing a different injection from the
            one that will happen.

            THE BRANCHES THAT LEAD TO A TICK OPEN THEMSELVES. A window that came
            up with everything shut would hide the ticks that are the reason it
            was opened - and on a share with five content folders and a driver
            store under one of them, "expand until you find it" is several clicks
            to learn something the tree already knows.

            IT IS PURE. The folders arrive from Get-HDTShareContentFolder, which
            is the half that needs an IFileSystem; this decides state and shape,
            so Pester reaches all of it with no share.

        .PARAMETER Folder
            The flat folder list, as Get-HDTShareContentFolder returned it.

        .PARAMETER Include
            The profile's include paths. Empty ticks nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per ROOT, each carrying
            Children - which is what a WPF HierarchicalDataTemplate binds to.
            Handing a window the flat list instead draws every node twice.

            Each node has Path, Name, Depth, State, Detail, IsExpanded and
            Children.

        .EXAMPLE
            Get-HDTConsoleSelectionProfileTree -Folder $folder -Include 'Drivers\WinPE'

        .EXAMPLE
            (Get-HDTConsoleSelectionProfileTree -Folder $folder -Include @('Drivers\WinPE')) |
                Where-Object { $_.Name -eq 'Drivers' } | Select-Object -ExpandProperty State

            $null - the square that says "some of Drivers, not all of it".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Folder,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Include = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $included = @($Include | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ([string] $_).Trim('\', '/') })

    # -- one node per folder, not yet joined up -------------------------------

    $byPath = @{}
    $order = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Folder)) {
        $path = [string] $current.Path

        $detail = ''
        if (-not [bool] $current.Present) {
            $detail = 'not on the share'
        } elseif ([bool] $current.Truncated) {
            $detail = 'more folders below - name them by hand if you need one'
        }

        # SELF OR ANCESTOR. 'Drivers\WinPE' includes 'Drivers\WinPE\Dell ...',
        # and the separator in the comparison is what stops 'Drivers\WinPE2'
        # matching it.
        $isOn = $false
        foreach ($one in $included) {
            if (($path -eq $one) -or $path.StartsWith($one + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $isOn = $true
                break
            }
        }

        $node = [pscustomobject] @{
            Path       = $path
            Name       = [string] $current.Name
            Depth      = [int] $current.Depth
            State      = $isOn
            Detail     = $detail
            IsExpanded = $false
            Children   = New-Object -TypeName System.Collections.ArrayList
        }

        $byPath[$path] = $node
        [void] $order.Add($node)
    }

    # -- join them up ---------------------------------------------------------

    $root = New-Object -TypeName System.Collections.ArrayList

    foreach ($node in $order) {
        if ($node.Depth -eq 0) {
            [void] $root.Add($node)
            continue
        }

        $parentPath = [string] (Split-Path -Path $node.Path -Parent)

        if ($byPath.ContainsKey($parentPath)) {
            [void] $byPath[$parentPath].Children.Add($node)
        } else {
            # A share whose tree was handed over in pieces still draws.
            [void] $root.Add($node)
        }
    }

    # -- the square, and the branches that open -------------------------------
    #
    # DEEPEST FIRST, so a parent is decided after every child of it already has
    # been. Walking the flat list backwards gives that for free: the reader
    # emitted parents before children, so the reverse is children before parents.
    for ($i = $order.Count - 1; $i -ge 0; $i--) {
        $node = $order[$i]
        $child = @($node.Children)

        if (@($child).Count -eq 0) { continue }

        # A folder already ticked in its own right stays ticked; its children
        # were ticked by the ancestor rule and cannot disagree.
        if (-not [bool] $node.State) {
            $on = @($child | Where-Object { $true -eq $_.State }).Count
            $square = @($child | Where-Object { $null -eq $_.State }).Count

            if (($square -gt 0) -or (($on -gt 0) -and ($on -lt @($child).Count))) {
                $node.State = $null
            } elseif (($on -gt 0) -and ($on -eq @($child).Count)) {
                # EVERY CHILD TICKED IS STILL A SQUARE, not a tick. The folder
                # itself is not in the include list, and showing it ticked would
                # invite a Save that wrote the parent instead of the children -
                # which injects anything added to it later, unasked.
                $node.State = $null
            }
        }

        # Open a branch that has anything ticked or part-ticked below it.
        if (@($child | Where-Object { $false -ne $_.State }).Count -gt 0) {
            $node.IsExpanded = $true
        }
    }

    # ArrayList binds to WPF, but a test asserting on .Count of an empty one
    # reads better as an array - and the window only ever enumerates.
    foreach ($node in $order) {
        $node.Children = [pscustomobject[]] @($node.Children)
    }

    return [pscustomobject[]] @($root)
}
