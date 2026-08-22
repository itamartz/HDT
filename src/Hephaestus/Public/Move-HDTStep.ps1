function Move-HDTStep {
    <#
        .SYNOPSIS
            Moves a step or group up or down past its neighbour, carrying the
            comment that explains it.

        .DESCRIPTION
            The Up and Down buttons, and the cmdlet an administrator can type
            instead.

            REORDERING IS MOST OF WHAT EDITING A TASK SEQUENCE IS, and it is the
            operation a text splice makes least obvious: a move is a removal and
            an insertion of the SAME lines, which is why it creates and destroys
            nothing and the line count is unchanged.

            THE COMMENT MOVES WITH THE STEP. Every comment in DEMO-M4 explains
            the step beneath it - why minRamMB is 2048, what ConfigureBoot does
            to the firmware boot order. A move that took only the dash line
            would leave that explanation attached to whatever slid up into its
            place, and the file would then assert something false about a step
            nobody edited.

            IT MOVES PAST A SIBLING, NOT OUT OF A GROUP. Up on the first step in
            a group is refused rather than interpreted, because "before the
            group" and "the last step of the group above" are both plausible and
            the console must not guess - the same refusal DiskPartition makes
            about an ambiguous target. Moving a step between groups
            is Copy, Paste and Remove, where each half is visible.

            A GROUP MOVES WHOLE. Its block spans its steps, so they travel with
            it and their order inside it is untouched.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to move.

        .PARAMETER Direction
            Up or Down.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the block moved.

        .EXAMPLE
            Move-HDTStep -Line $line -Name 'Apply OS' -Direction Down
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # WHICH OF THE SAME-NAMED STEPS, 1-BASED, IN DOCUMENT ORDER. Omitted, an
        # ambiguous name is refused rather than guessed at. The console passes
        # it because it has a selected row; a person typing a name has not said
        # which one they mean, and is told so.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0,

        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = 'Direction')]
        [ValidateSet('Up', 'Down')]
        [string] $Direction,

        # THE BLOCK TO LAND BESIDE, AND WHICH SIDE OF IT.
        #
        # -Direction can only swap a block with a SIBLING, so the last step of a
        # group had nowhere to go: "before the group" and "the last step of the
        # group above" are both plausible and the command refused rather than
        # guess. Refusing was the wrong answer to a real ambiguity - MDT lets an
        # administrator put a step anywhere, and somebody looking at the tree
        # knows which of the two they meant.
        #
        # NAMING THE TARGET IS HOW THEY SAY IT. Every destination in the
        # document becomes expressible - into a group, out of one, across two
        # boundaries at once - and none of it is guessed.
        [Parameter(Mandatory = $true, ParameterSetName = 'Target')]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [Parameter(ParameterSetName = 'Target')]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $TargetOccurrence = 0,

        # Into IS FOR THE GROUP THAT HAS NOTHING IN IT. Before and After name a
        # block to land beside, so an EMPTY group cannot be named at all - and a
        # group whose last step was moved out is exactly the group somebody wants
        # to put a step back into. Watched in the console: two steps taken out of
        # a group, and no way to return either of them.
        [Parameter(Mandatory = $true, ParameterSetName = 'Target')]
        [ValidateSet('Before', 'After', 'Into')]
        [string] $Position
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ONE CALL TO THE LOCATOR, AND EVERYTHING FOUND INSIDE ITS RESULT. Resolving
    # the name separately would build a SECOND set of block objects, and an
    # identity comparison against the first set then matches nothing - which
    # reads as "this step is already first" for every step in the document.
    $block = @(Get-HDTStepBlock -Line $Line)

    $found = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence
    $current = @($block | Where-Object { $_.Entry -eq $found.Entry })[0]

    # A SIBLING SHARES A PARENT, NOT MERELY AN INDENTATION. Every step in the
    # document sits at the same column, so matching on indentation alone would
    # make the last step of one group the neighbour of the first step of the
    # next - and Down would silently move a step across a group boundary, which
    # is the one thing this command refuses to do.
    $parent = @(Get-HDTStepParent -Block $block)

    $at = [array]::IndexOf($block, $current)
    $sibling = @($block | Where-Object { $_.Indent -eq $current.Indent -and $parent[[array]::IndexOf($block, $_)] -eq $parent[$at] })

    # -- the positional move, which has no edges to be stopped at ----------
    if ($PSCmdlet.ParameterSetName -eq 'Target') {

        $landing = Resolve-HDTStepBlock -Line $Line -Name $Target -Occurrence $TargetOccurrence
        $destination = @($block | Where-Object { $_.Entry -eq $landing.Entry })[0]

        # A BLOCK CANNOT LAND INSIDE ITSELF, and a group asked to is the case
        # that would silently eat the document: its children are inside its own
        # range, so the splice would remove the lines it was about to insert.
        if ($destination.Entry -ge $current.Start -and $destination.Entry -le $current.End) {
            throw (New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                    -Message ("'{0}' cannot be moved inside itself - '{1}' is part of it." -f $Name, $Target))
        }

        if ($Position -eq 'Into' -and [string] $destination.Kind -ne 'Group') {
            throw (New-HDTErrorRecord -Path $Target -Category InvalidArgument `
                    -Message ("'{0}' is a step, not a group, so there is nothing to move into. Use -Position Before or After to put '{1}' beside it." -f $Target, $Name))
        }

        if (-not $PSCmdlet.ShouldProcess($Name, ('Move {0} {1}' -f $Position, $Target))) {
            return [string[]] @($Line)
        }

        # WHAT COLUMN A CHILD OF THAT GROUP SITS AT.
        #
        # DERIVED FROM THE DOCUMENT, NOT ASSUMED. A share written at a different
        # nesting width would otherwise have every step land at the wrong column
        # - and the file would still PARSE, because YAML accepts a consistent
        # depth of its own, so nothing would catch it until a diff looked wrong.
        # Any group that still has a child answers the question; four is the
        # fallback for a document where no group has one.
        $childIndent = $destination.Indent + 4

        if ($Position -eq 'Into') {
            foreach ($other in @($block)) {
                if ([string] $other.Kind -ne 'Group') { continue }

                foreach ($inner in @($block)) {
                    if ($inner.Entry -le $other.Entry -or $inner.Entry -gt $other.End) { continue }
                    if ($inner.Indent -le $other.Indent) { continue }

                    $childIndent = $destination.Indent + ($inner.Indent - $other.Indent)
                    break
                }

                if ($childIndent -ne ($destination.Indent + 4)) { break }
            }
        }

        # THE GROUP'S OWN steps: KEY, FOUND BEFORE ANYTHING IS TAKEN OUT. It is
        # the only line that says where a group's children begin, and it is what
        # Into inserts under - which is why Before and After cannot reach inside
        # an empty group at all.
        #
        # LOOKED UP HERE, NOT WHERE IT IS USED. The removal loop below reads it
        # too, and StrictMode makes a variable set after its first reader an
        # error rather than a subtle bug - which is exactly what it caught.
        $stepsAt = -1

        if ($Position -eq 'Into') {
            for ($i = $destination.Entry; $i -le $destination.End -and $i -lt $Line.Count; $i++) {
                if ($Line[$i] -match '^\s*steps:') { $stepsAt = $i; break }
            }

            if ($stepsAt -lt 0) {
                throw (New-HDTErrorRecord -Path $Target -Category InvalidData `
                        -Message ("'{0}' declares no steps key, so there is nowhere inside it to put '{1}'. A group declares one even when it is empty: write 'steps: []'." -f $Target, $Name))
            }
        }

        # THE BLOCK, RE-INDENTED TO WHERE IT IS GOING. Every line of it moves by
        # the same amount, so a group's children keep their shape relative to
        # the group and a step's comment stays above the step.
        #
        # ONLY LEADING SPACES ARE TOUCHED, and a blank line is left blank rather
        # than turned into a line of spaces - this document is compared against
        # its own bytes by the tests that guard splicing.
        $shift = $destination.Indent - $current.Indent
        if ($Position -eq 'Into') { $shift = $childIndent - $current.Indent }
        $moving = New-Object -TypeName System.Collections.ArrayList

        foreach ($text in @($Line[$current.Start..$current.End])) {

            if ([string]::IsNullOrWhiteSpace($text)) {
                [void] $moving.Add($text)
                continue
            }

            if ($shift -gt 0) {
                [void] $moving.Add((' ' * $shift) + $text)
                continue
            }

            if ($shift -lt 0) {
                # NEVER PAST COLUMN ZERO. A line with less leading space than
                # the shift would lose characters rather than indentation, which
                # is a corrupted document rather than a badly indented one.
                $lead = $text.Length - $text.TrimStart(' ').Length
                $take = [System.Math]::Min($lead, -$shift)

                [void] $moving.Add($text.Substring($take))
                continue
            }

            [void] $moving.Add($text)
        }

        # THE DOCUMENT WITHOUT THE BLOCK, so the destination is found in what
        # remains rather than in what it used to be.
        $kept = New-Object -TypeName System.Collections.ArrayList

        for ($i = 0; $i -lt $Line.Count; $i++) {
            if ($i -ge $current.Start -and $i -le $current.End) { continue }

            # See above: an inline empty list cannot take a block item under it.
            if ($Position -eq 'Into' -and $i -eq $stepsAt -and $Line[$i] -match '^\s*steps:\s*\[\s*\]\s*$') {
                [void] $kept.Add(($Line[$i] -replace '\[\s*\]\s*$', ''). TrimEnd())
                continue
            }

            [void] $kept.Add($Line[$i])
        }

        # WHERE IT GOES, MEASURED AFTER THE REMOVAL.
        #
        # THE TEST IS AGAINST THE INSERTION POINT, NOT AGAINST THE DESTINATION'S
        # START, and the difference is a document this got wrong. Moving a step
        # to just after ITS OWN GROUP - which is how a step leaves a group - puts
        # the source INSIDE the destination: the source starts after the group
        # starts, so a check on Start said "no adjustment", while the hole the
        # removal left was inside the group and had already pulled the group's
        # own End upwards. The block landed a few lines late, in the middle of
        # the next group's header, and the result reported 'State Restore
        # declares no steps key' - a splice failure wearing a parser's message.
        #
        # EVERY ORIGINAL INDEX PAST THE HOLE MOVES BACK BY ITS SIZE. That is the
        # whole rule, and it covers above, below and inside alike.
        $removed = ($current.End - $current.Start) + 1
        $insertAt = $destination.Start
        if ($Position -eq 'After') { $insertAt = $destination.End + 1 }

        # INTO LANDS UNDER THE GROUP'S OWN steps: KEY, which is the only line
        # that says where a group's children begin. An empty group has that key
        # and nothing after it, which is precisely why Before and After cannot
        # reach inside one.
        #
        # AND 'steps: []' BECOMES 'steps:', because a list written inline cannot
        # have a block item added under it - the document would parse as a group
        # with an empty list AND a stray step.
        if ($Position -eq 'Into') { $insertAt = $stepsAt + 1 }

        if ($insertAt -gt $current.End) { $insertAt -= $removed }

        if ($insertAt -lt 0) { $insertAt = 0 }
        if ($insertAt -gt $kept.Count) { $insertAt = $kept.Count }

        $result = New-Object -TypeName System.Collections.ArrayList

        for ($i = 0; $i -lt $insertAt; $i++) { [void] $result.Add($kept[$i]) }
        foreach ($text in @($moving)) { [void] $result.Add($text) }
        for ($i = $insertAt; $i -lt $kept.Count; $i++) { [void] $result.Add($kept[$i]) }

        return [string[]] @($result)
    }

    $at = [array]::IndexOf($sibling, $current)

    if ($Direction -eq 'Up' -and $at -le 0) {
        throw (New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                -Message ("'{0}' is already the first step of its group, and moving it further up would mean moving it OUT of the group - which could mean before the group or into the one above it. Use Copy, Paste and Remove, where each half of that is visible." -f $Name))
    }

    if ($Direction -eq 'Down' -and $at -ge ($sibling.Count - 1)) {
        throw (New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                -Message ("'{0}' is already the last step of its group, and moving it further down would mean moving it OUT of the group. Use Copy, Paste and Remove, where each half of that is visible." -f $Name))
    }

    if (-not $PSCmdlet.ShouldProcess($Name, ('Move {0}' -f $Direction))) {
        return [string[]] @($Line)
    }

    $other = $sibling[$at - 1]
    if ($Direction -eq 'Down') { $other = $sibling[$at + 1] }

    # The two blocks, in document order, and the lines each owns.
    $first = $current
    $second = $other
    if ($current.Start -gt $other.Start) {
        $first = $other
        $second = $current
    }

    $firstText = @($Line[$first.Start..$first.End])
    $secondText = @($Line[$second.Start..$second.End])

    # Whatever sits BETWEEN them - the blank line, and nothing else - stays
    # between them, so the spacing is the same after the swap as before it.
    $between = @()
    if (($second.Start - 1) -ge ($first.End + 1)) {
        $between = @($Line[($first.End + 1)..($second.Start - 1)])
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $first.Start; $i++) { [void] $result.Add($Line[$i]) }

    foreach ($text in $secondText) { [void] $result.Add($text) }
    foreach ($text in $between) { [void] $result.Add($text) }
    foreach ($text in $firstText) { [void] $result.Add($text) }

    for ($i = $second.End + 1; $i -lt $Line.Count; $i++) { [void] $result.Add($Line[$i]) }

    return [string[]] @($result)
}
