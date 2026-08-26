function Move-HDTWorkspaceFolder {
    <#
        .SYNOPSIS
            Moves a console folder up or down among the folders beside it.

        .DESCRIPTION
            A FOLDER IS A LABEL IN AN ORDERED LIST, NOT A DIRECTORY.
            C:\HDTLab\Share\OperatingSystems holds Win11-LTSC-2024 and
            WS2025-Std and no 'Windows' folder at all - that name is one entry in
            workspace.yaml's folders.operatingSystems, and the documents filed
            under it say so themselves. So the order already exists in a list
            somebody wrote, and moving a folder means moving an entry in it: no
            sortIndex on five document types, no order file beside the share,
            nothing that can disagree with what is on disk.

            THE TREE HONOURS THAT ORDER, which it did not until this shipped.
            Group-HDTConsoleFolderRow sorted every level by name and threw the
            declaration away, so there was nothing on screen for Up and Down to
            change. Folders now draw in declared order, and a folder nobody
            declared - one that exists because a document names it - falls in
            after them alphabetically, because nobody ever positioned it.

            SIBLINGS ONLY. 'Clients' and 'Servers' are both at the top and swap
            with each other; 'Clients\Laptops' moves among the other folders
            inside Clients. Nothing here can reparent a folder - that is
            Move To Folder, a different question with a different answer.

            IT TAKES ITS CHILDREN WITH IT when they are written directly beneath
            it, which is how Add-HDTWorkspaceFolder leaves them. The display
            would be right either way - each level is ranked on its own - but a
            document listing Clients\Laptops three entries above Clients is one
            nobody can read, and this file is meant to be read.

            AT EITHER END IT DOES NOTHING, and that is not an error. The button
            is pressed at the end of a list by anybody finding out where the end
            is; a refusal there would be a message about nothing.

            IT SPLICES. Comments die at parse time, so the lines are moved and
            every one this does not own comes back exactly as it went in.

        .PARAMETER Line
            The workspace document's lines, as read.

        .PARAMETER Category
            Which category's folders to move within. 'Clients' under task
            sequences and 'Clients' under operating systems are different
            folders.

        .PARAMETER Folder
            The folder's full path - 'Clients\Laptops'.

        .PARAMETER Direction
            Up or Down, among its own siblings.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\workspace.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            $line = Move-HDTWorkspaceFolder -Line $line -Category TaskSequence -Folder 'Servers' -Direction Up
            Save-HDTWorkspaceDocument -Path $path -Line $line

            Puts Servers above Clients in the console's Task Sequences node.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\workspace.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            Move-HDTWorkspaceFolder -Line $line -Category OperatingSystem `
                -Folder 'Windows' -Direction Down -WhatIf

            Says what it would do and changes nothing, which is how to check the
            folder is spelled the way the document spells it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('TaskSequence', 'OperatingSystem', 'Application')]
        [string] $Category,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Folder,

        [Parameter(Mandatory = $true, Position = 3)]
        [ValidateSet('Up', 'Down')]
        [string] $Direction
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $key = Get-HDTWorkspaceFolderKey -Category $Category
    $block = Get-HDTWorkspaceKey -Line $Line -Path @('folders', $key)

    $entry = @()
    if ($null -ne $block) { $entry = @(Get-HDTWorkspaceItem -Line $Line -Block $block) }

    # THE PATH EACH ENTRY DECLARES, beside the lines it occupies. The list is
    # scalars, so an entry is its dash line - but Get-HDTWorkspaceItem already
    # knows where one ends, and reading End rather than assuming one line is what
    # keeps this right if a folder ever grows a property.
    $declared = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($entry)) {
        $text = [string] $Line[[int] $current.Index]

        if ($text -notmatch '^\s*-\s*(.+?)\s*$') { continue }

        $path = [string] $Matches[1]

        if ($path.Length -ge 2 -and $path.StartsWith('"') -and $path.EndsWith('"')) {
            $path = $path.Substring(1, $path.Length - 2)
        } elseif ($path.Length -ge 2 -and $path.StartsWith("'") -and $path.EndsWith("'")) {
            $path = $path.Substring(1, $path.Length - 2)
        }

        [void] $declared.Add([pscustomobject] @{
                Path  = $path
                Start = [int] $current.Index
                End   = [int] $current.End
            })
    }

    $mine = @($declared | Where-Object { $_.Path -eq $Folder })

    if (@($mine).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category ObjectNotFound `
                    -Message ("this share declares no {0} folder called '{1}', so there is nothing to move. A folder that exists only because a document names it has no declared position - make it with Add-HDTWorkspaceFolder first." -f
                        $Category, $Folder)))
    }

    # WHO IT SITS BESIDE. Everything sharing its parent path, in the order the
    # document lists them - 'Clients\Laptops' is a sibling of 'Clients\Desktops'
    # and not of 'Servers'.
    $parent = ''
    if ($Folder -match '^(.*)\\[^\\]+$') { $parent = [string] $Matches[1] }

    $sibling = @($declared | Where-Object {
            $each = [string] $_.Path
            $its = ''
            if ($each -match '^(.*)\\[^\\]+$') { $its = [string] $Matches[1] }

            $its -eq $parent
        })

    $at = -1
    for ($index = 0; $index -lt @($sibling).Count; $index++) {
        if ($sibling[$index].Path -eq $Folder) { $at = $index; break }
    }

    $other = $at - 1
    if ($Direction -eq 'Down') { $other = $at + 1 }

    if ($other -lt 0 -or $other -ge @($sibling).Count) { return [string[]] @($Line) }

    if (-not $PSCmdlet.ShouldProcess($Folder, ('Move {0} among the {1} folders' -f $Direction.ToLowerInvariant(), $Category))) {
        return [string[]] @($Line)
    }

    # THE FOLDER AND WHATEVER OF ITS OWN IS WRITTEN DIRECTLY BENEATH IT. Anything
    # further down the file stays where it is: the levels are ranked separately,
    # so the tree is right either way, and hauling scattered lines together would
    # rewrite more of somebody's document than they asked for.
    $span = {
        param([object] $Entry)

        $start = [int] $Entry.Start
        $end = [int] $Entry.End

        foreach ($candidate in @($declared)) {
            if ([int] $candidate.Start -ne ($end + 1)) { continue }
            if (-not ([string] $candidate.Path).StartsWith(([string] $Entry.Path) + '\')) { continue }

            $end = [int] $candidate.End
        }

        return [pscustomobject] @{ Start = $start; End = $end }
    }

    $first = & $span $sibling[$at]
    $second = & $span $sibling[$other]

    # IN DOCUMENT ORDER, whichever way the move was asked for: the splice walks
    # the file forwards and has to meet the earlier one first.
    if ([int] $first.Start -gt [int] $second.Start) {
        $swap = $first
        $first = $second
        $second = $swap
    }

    $result = New-Object -TypeName System.Collections.ArrayList
    $index = 0

    while ($index -lt @($Line).Count) {

        if ($index -ne [int] $first.Start) {
            [void] $result.Add([string] $Line[$index])
            $index++
            continue
        }

        for ($take = [int] $second.Start; $take -le [int] $second.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = [int] $first.End + 1; $take -lt [int] $second.Start; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = [int] $first.Start; $take -le [int] $first.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        $index = [int] $second.End + 1
    }

    return [string[]] @($result)
}
