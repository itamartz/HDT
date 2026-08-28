function Get-HDTStepNeighbourTarget {
    <#
        .SYNOPSIS
            What Up and Down mean once a step can go anywhere: the row to land
            beside, and which side of it.

        .DESCRIPTION
            UP AND DOWN USED TO MEAN "SWAP WITH A SIBLING", so a step at the edge
            of a group had a dark button and nowhere to go. Move-HDTStep refused
            the move because "before the group" and "the last step of the group
            above" are both plausible and it would not guess - which was the
            wrong answer to a real ambiguity. A step may go anywhere in the
            tree, and somebody looking at it knows which of the two they meant.

            THEY NOW MEAN WHAT THE TREE SHOWS. The row moves one place in the
            list a technician can SEE, crossing a group boundary wherever the
            list does, and this works out which block that lands it beside.

            DOWN ONTO A GROUP IS THE ONE WORTH EXPLAINING. The next visible row
            below a step that sits above a group is the group's own HEADER, and
            landing after that header means landing after everything inside it -
            so one keypress would jump the step over the whole group. Down puts
            it in as the group's first child instead, which is where the eye
            expects it to go. A group with no children has nothing to go before,
            so the answer there is after the group itself.

            A BLOCK NEVER LANDS INSIDE ITSELF. A group's own descendants are
            skipped when looking for its neighbour, because they are inside the
            range the move is about to lift out - Move-HDTStep refuses that, and
            a button that produced a refusal would be a button that looks broken.

            IT IS PURE, AND THAT IS THE POINT. The console's click handler passes
            this answer straight to Move-HDTStep and decides nothing. A WPF
            handler is the one place in this repository that nothing can test, so
            it is the last place a decision should live.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to move.

        .PARAMETER Occurrence
            Which of the same-named blocks, 1-based, in document order.

        .PARAMETER Direction
            Up or Down.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Target,
            TargetOccurrence and Position - or nothing at all when the row is
            already at that end of the document, which is what a dark button
            means.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'))
            $to = Get-HDTStepNeighbourTarget -Line $line -Name 'Prepare Boot' -Direction Down
            Move-HDTStep -Line $line -Name 'Prepare Boot' -Target $to.Target -Position $to.Position

            The whole of what the console's Down button does.

        .EXAMPLE
            if ($null -eq (Get-HDTStepNeighbourTarget -Line $line -Name 'Gather' -Direction Up)) { }

            How the toolbar knows to go dark: there is nowhere above it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Up', 'Down')]
        [string] $Direction
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $block = @(Get-HDTStepBlock -Line $Line)
    if (@($block).Count -eq 0) { return }

    $found = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence
    $at = -1

    for ($i = 0; $i -lt @($block).Count; $i++) {
        if ($block[$i].Entry -eq $found.Entry) { $at = $i; break }
    }

    if ($at -lt 0) { return }

    # WHICH OCCURRENCE A BLOCK IS, counted the way Resolve-HDTStepBlock counts:
    # across groups AND steps, in document order. Two tables that disagreed
    # about what "the second one" means would send a move to the wrong row.
    $occurrenceOf = {
        param([int] $Index)

        $wanted = [string] $block[$Index].Name
        $seen = 0

        for ($j = 0; $j -le $Index; $j++) {
            if ([string] $block[$j].Name -eq $wanted) { $seen++ }
        }

        return $seen
    }

    # THE NEIGHBOUR, SKIPPING ANYTHING INSIDE THE BLOCK ITSELF. A group's
    # children live between its Start and its End, and a group asked to move
    # beside its own child is a group asked to move inside itself.
    $step = -1
    if ($Direction -eq 'Down') { $step = 1 }

    $neighbour = -1

    for ($i = $at + $step; $i -ge 0 -and $i -lt @($block).Count; $i += $step) {
        if ($block[$i].Entry -ge $found.Start -and $block[$i].Entry -le $found.End) { continue }

        $neighbour = $i
        break
    }

    # NOTHING BELOW IT IN THE TEXT IS NOT THE SAME AS NOWHERE TO GO. A step at
    # the bottom of the last group has no block after it - and it still has
    # somewhere to be: OUT of the group, at the top level, after the group
    # itself. A slot is a position AND a depth, and the end of the document
    # carries one at every depth the block is currently nested in.
    #
    # ONE LEVEL PER PRESS, which is what a technician expects of a button that
    # moves things one place: a step three groups deep leaves one group at a
    # time and can be watched doing it.
    if ($neighbour -lt 0 -and $Direction -eq 'Down') {

        $parent = @(Get-HDTStepParent -Block $block)
        $parentAt = $parent[$at]

        if ($parentAt -ge 0) {
            return [pscustomobject] @{
                Target           = [string] $block[$parentAt].Name
                TargetOccurrence = [int] (& $occurrenceOf $parentAt)
                Position         = 'After'
            }
        }
    }

    # AND NOW IT REALLY IS NOWHERE. The caller darkens the button rather than
    # offering a press that produces an error box.
    if ($neighbour -lt 0) { return }

    $target = $block[$neighbour]
    $position = 'Before'

    # AN EMPTY GROUP IS ENTERED, NOT STEPPED OVER. It has no child to land
    # before or after, so a technician who moved the last step out had no way to
    # put anything back - the row simply hopped past the group in both
    # directions. Into is the only way in, and this is where it is offered.
    $hasChild = $false
    foreach ($inner in @($block)) {
        if ($inner.Entry -gt $target.Entry -and $inner.Entry -le $target.End) { $hasChild = $true; break }
    }

    if ([string] $target.Kind -eq 'Group' -and -not $hasChild) {
        return [pscustomobject] @{
            Target           = [string] $target.Name
            TargetOccurrence = [int] (& $occurrenceOf $neighbour)
            Position         = 'Into'
        }
    }

    if ($Direction -eq 'Up' -and $target.Indent -gt $found.Indent) {

        # ENTERING A GROUP FROM BELOW JOINS IT AT THE END. The row above a
        # top-level step is the LAST CHILD of the group above it, which is
        # deeper - and landing BEFORE that child would jump the step over
        # everything else in the group in a single press.
        #
        # WATCHED IN THE CONSOLE: step 11 moved up into the group and came back
        # as step 10, with the step that had been 10 renumbered to 11. It had
        # overtaken it rather than fallen in behind it. Its place on screen must
        # not change - only its depth.
        $position = 'After'
    }

    if ($Direction -eq 'Down') {

        # AFTER THE ROW BELOW - unless that row is a GROUP, whose End is the end
        # of everything inside it. See the header: one press must not vault a
        # step over an entire group.
        $position = 'After'

        if ([string] $target.Kind -eq 'Group') {

            $child = -1
            for ($i = $neighbour + 1; $i -lt @($block).Count; $i++) {
                if ($block[$i].Entry -gt $target.End) { break }

                $child = $i
                break
            }

            if ($child -ge 0) {
                $neighbour = $child
                $target = $block[$child]
                $position = 'Before'
            }
        }
    }

    return [pscustomobject] @{
        Target           = [string] $target.Name
        TargetOccurrence = [int] (& $occurrenceOf $neighbour)
        Position         = $position
    }
}
