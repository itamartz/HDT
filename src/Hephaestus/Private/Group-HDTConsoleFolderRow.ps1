function Group-HDTConsoleFolderRow {
    <#
        .SYNOPSIS
            Turns the folder each row named into the levels the tree draws.

        .DESCRIPTION
            THE ONLY PLACE HDT'S FOLDERS EXIST. Deployment Workbench nests task
            sequences, operating systems and applications into real directories
            under Control\; HDT's cannot be, because the folder would then be
            part of the path the engine resolves an id from - so the folder is a
            label on the document and the TREE is where it becomes a level.

            ONE FUNCTION FOR ALL THREE CATEGORIES. They differ in what a row
            SAYS and not at all in how 'Clients\Laptops' becomes two levels, and
            a second copy of this would be a second place for them to disagree.

            IT TAKES ROWS AND RETURNS ROWS. Nothing here reads a document or
            decides what a row shows: it is handed rows that already know their
            subject, each carrying the folder that subject named, and it returns
            what the category should hold.

            A SHARE THAT NEVER USED FOLDERS LOOKS EXACTLY AS IT DID - which is
            every share that exists today. No row carries a folder, nothing is
            nested, and the depths come back untouched.

            LOOSE ROWS COME AFTER THE FOLDERS, which is where Workbench puts
            them, and folders are drawn in name order so the tree does not
            reshuffle itself when a document is edited.

        .PARAMETER Row
            The rows, each with a Folder property. A row without one is treated
            as loose rather than refused: the property is added by the caller
            from a document key that most documents do not carry.

        .PARAMETER Depth
            The depth the rows came in at, which is the depth the top level
            keeps. Every level below it is one deeper.

        .PARAMETER Declared
            Folders the share declares in workspace.yaml, drawn whether or not a
            row is in them. This is what makes New Folder possible: a folder
            nothing is in yet cannot be produced from the rows, and without it
            the next refresh would silently delete the folder somebody had just
            made. A folder both declared and named by a row is drawn once.

        .PARAMETER Category
            Which category these rows are, so a folder node can say which list
            it belongs to. 'Clients' under task sequences and 'Clients' under
            operating systems are different folders, and a menu acting on one
            has to name which.

        .PARAMETER Header
            The banner the nodes carry, as everywhere else in the tree.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

              TopLevel  what the category holds: folders then loose rows
              Node      every node once, parents before their children, in the
                        order the tree draws them
    #>
    # $Depth AND $Header ARE used - inside the $ensure closure below, which is
    # where every folder node is built and so the only place they are needed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [int] $Depth,

        [Parameter()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Declared = @(),

        [Parameter()]
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application')]
        [string] $Category = 'TaskSequence',

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $folderOf = {
        param($Item)

        if ($null -eq $Item.PSObject.Properties['Folder']) { return '' }
        return ([string] $Item.Folder).Trim()
    }

    $loose = @($Row | Where-Object { [string]::IsNullOrWhiteSpace((& $folderOf $_)) })
    $filed = @($Row | Where-Object { -not [string]::IsNullOrWhiteSpace((& $folderOf $_)) })
    $empty = @($Declared | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if (@($filed).Count -eq 0 -and @($empty).Count -eq 0) {
        # A SHARE WITH NO FOLDERS STILL OFFERS Move To, with a box to type the
        # first one into - which is how the first folder gets made from an item.
        foreach ($current in @($Row)) {
            $current | Add-Member -MemberType NoteProperty -Name 'FolderChoice' -Value ([string[]] @()) -Force
            $current | Add-Member -MemberType NoteProperty -Name 'FolderCategory' -Value $Category -Force
        }

        return [pscustomobject] @{
            TopLevel = [object[]] @($Row)
            Node     = [object[]] @($Row)
        }
    }

    # EVERY FOLDER NODE, BY ITS FULL PATH, so 'Clients' is built once however
    # many of 'Clients\Laptops' and 'Clients\Desktops' arrive.
    $made = @{}
    $topFolder = New-Object -TypeName System.Collections.ArrayList

    $ensure = {
        param([string] $Path)

        if ($made.ContainsKey($Path)) { return $made[$Path] }

        $part = @($Path -split '\\')
        $leaf = [string] $part[$part.Count - 1]
        $level = $part.Count - 1

        # A FOLDER RUNS NOTHING, so it names the command that would list what is
        # in it - the node factory refuses an empty one, and rightly: every
        # other row in this tree can be reproduced from what it shows.
        #
        # AND THE COMMENT GOES ABOVE THE CALL, not inside it: a comment between
        # two backtick continuations ends the statement, and the rest of the
        # arguments become a command of their own.
        $node = New-HDTConsoleNode -Depth ($Depth + $level) -Kind 'Folder' -Status 'Ok' `
            -Text $leaf `
            -Field @(New-HDTConsoleField -Label 'Folder' -Value $Path) `
            -Command ('Get-HDTConsoleWorkspace -Path ''{0}''' -f [string] $Header.Root) `
            -Header $Header -Icon (Get-HDTConsoleIcon -Kind 'Folder' -Status 'Ok')

        # THE FULL PATH, CARRIED. A window offering "move into this folder" has
        # to name the whole path, and the node's text is only its last level.
        $node | Add-Member -MemberType NoteProperty -Name 'FolderPath' -Value $Path -Force

        # AND WHICH CATEGORY IT IS A FOLDER OF. The node's own Kind is 'Folder'
        # in all three, and a menu that deleted a task sequence folder because
        # the pointer was over an operating system's would be a bad afternoon.
        $node | Add-Member -MemberType NoteProperty -Name 'FolderCategory' -Value $Category -Force

        $made[$Path] = $node

        if ($level -eq 0) {
            [void] $topFolder.Add($node)
        } else {
            $parent = & $ensure ([string]::Join('\', $part[0..($part.Count - 2)]))
            [void] $parent.Children.Add($node)
        }

        return $node
    }

    # THE DECLARED ONES FIRST, so a folder with nothing in it is built before any
    # row can decide the order - and $ensure builds each path once, so a folder
    # that is both declared and named by a row is one node.
    foreach ($current in @($empty | Sort-Object)) { [void] (& $ensure ([string] $current).Trim()) }

    foreach ($current in @($filed | Sort-Object -Property @{ Expression = { & $folderOf $_ } }, Text)) {
        $path = & $folderOf $current
        $parent = & $ensure $path

        $current.Depth = [int] $parent.Depth + 1
        [void] $parent.Children.Add($current)
    }

    # NAME ORDER, AT EVERY LEVEL, so editing a document does not reshuffle the
    # tree - the order rows arrive in is the order the share enumerated them.
    $ordered = @($topFolder | Sort-Object -Property Text)

    foreach ($node in @($made.Values)) {
        $sorted = @($node.Children | Sort-Object -Property @{ Expression = { [string] $_.Kind -ne 'Folder' } }, Text)

        $node.Children.Clear()
        foreach ($child in $sorted) { [void] $node.Children.Add($child) }
    }

    $top = [object[]] @(@($ordered) + @($loose))

    # EVERY FOLDER IN THIS CATEGORY, ON EVERY ROW OF IT. A right-click offering
    # "move into" has to name the folders, and reading the share when the menu
    # opens costs 400ms on the lab share - measured - in front of a menu that is
    # supposed to appear under the pointer. The tree is built once; the list is
    # known here.
    $choice = [string[]] @(@($made.Keys) | Sort-Object)

    # PARENTS BEFORE THEIR CHILDREN, which is the order the tree draws and the
    # order the flat list has to be in for a selection to find its row.
    $flat = New-Object -TypeName System.Collections.ArrayList

    $walk = {
        param($Node)

        [void] $flat.Add($Node)
        foreach ($child in @($Node.Children)) { & $walk $child }
    }

    foreach ($node in $top) { & $walk $node }

    foreach ($node in @($flat)) {
        $node | Add-Member -MemberType NoteProperty -Name 'FolderChoice' -Value $choice -Force
        $node | Add-Member -MemberType NoteProperty -Name 'FolderCategory' -Value $Category -Force
    }

    return [pscustomobject] @{
        TopLevel = [object[]] @($top)
        Node     = [object[]] @($flat)
    }
}
