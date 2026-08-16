function Move-HDTConsoleStep {
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
            Move-HDTConsoleStep -Line $line -Name 'Apply OS' -Direction Down
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

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Up', 'Down')]
        [string] $Direction
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ONE CALL TO THE LOCATOR, AND EVERYTHING FOUND INSIDE ITS RESULT. Resolving
    # the name separately would build a SECOND set of block objects, and an
    # identity comparison against the first set then matches nothing - which
    # reads as "this step is already first" for every step in the document.
    $block = @(Get-HDTConsoleStepBlock -Line $Line)

    $found = Resolve-HDTConsoleStepBlock -Line $Line -Name $Name
    $current = @($block | Where-Object { $_.Entry -eq $found.Entry })[0]

    # A SIBLING SHARES A PARENT, NOT MERELY AN INDENTATION. Every step in the
    # document sits at the same column, so matching on indentation alone would
    # make the last step of one group the neighbour of the first step of the
    # next - and Down would silently move a step across a group boundary, which
    # is the one thing this command refuses to do.
    $parent = @(Get-HDTConsoleStepParent -Block $block)

    $at = [array]::IndexOf($block, $current)
    $sibling = @($block | Where-Object { $_.Indent -eq $current.Indent -and $parent[[array]::IndexOf($block, $_)] -eq $parent[$at] })

    $at = [array]::IndexOf($sibling, $current)

    if ($Direction -eq 'Up' -and $at -le 0) {
        throw (New-HDTConsoleErrorRecord -Path $Name -Category InvalidOperation `
                -Message ("'{0}' is already the first step of its group, and moving it further up would mean moving it OUT of the group - which could mean before the group or into the one above it. Use Copy, Paste and Remove, where each half of that is visible." -f $Name))
    }

    if ($Direction -eq 'Down' -and $at -ge ($sibling.Count - 1)) {
        throw (New-HDTConsoleErrorRecord -Path $Name -Category InvalidOperation `
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
