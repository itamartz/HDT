function Test-HDTConsoleLineChange {
    <#
        .SYNOPSIS
            Whether an edit actually changed the document.

        .DESCRIPTION
            EVERY PAGE ON THE EDITOR COMMITS BY ITSELF - there is no Apply button
            anywhere - so its writes run on leaving a box and on leaving a STEP,
            not only when somebody asked for one. Walking through a sequence and
            reading it runs the same code path as editing it.

            SO MARKING THE WINDOW DIRTY UNCONDITIONALLY IS WRONG TWICE OVER. It
            lights Save up for somebody who only looked, and then Save writes a
            file with no edit in it - re-serialising a document whose comments
            and ordering are the entire reason this editor splices lines instead
            of round-tripping YAML.

            THE COMPARISON IS ORDINAL AND LINE BY LINE, because the splice is
            textual. A document differing only in case is a different document,
            and a line that gained trailing whitespace changed. Anything looser
            would let a real edit through as "unchanged", which is the failure
            that loses work rather than the one that annoys.

            LENGTH FIRST, because it is the cheap answer and the common one: a
            step added or removed changes the count, and there is no point
            walking two arrays to discover it.

        .PARAMETER Before
            The lines as they were before the attempt.

        .PARAMETER After
            The lines as they are now.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether anything changed.

        .EXAMPLE
            Test-HDTConsoleLineChange -Before $before -After $book.Line

        .EXAMPLE
            if (-not (Test-HDTConsoleLineChange -Before $before -After $book.Line)) { return }
            $book.Dirty = $true
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # AllowEmptyString IS NOT THE SAME PERMISSION AS AllowEmptyCollection,
        # and the difference cost every partition edit in the console. The
        # collection may be empty; so may a LINE in it, because every sequence
        # this toolkit writes has blank lines - between groups, around the
        # commentary the templates carry. Without this, the whole document was
        # refused at the parameter with "Cannot bind argument to parameter
        # 'Before' because it is an empty string", and that sentence was printed
        # on the strip where the command should have been.
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Before,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $After
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A NULL SIDE IS AN EMPTY DOCUMENT, NOT A ONE-LINE ONE. @($null) is an array
    # holding one $null, so wrapping without this would report a change between
    # two documents that are both absent.
    #
    # AND NOT `$was = if (...) { @() } else { ... }`. An empty array returned
    # from a scriptblock UNROLLS TO NOTHING, the assignment lands $null, and
    # .Count on $null is a terminating error under StrictMode - the same trap
    # Get-HDTShareAccessRule's unary comma exists for.
    $was = @()
    if ($null -ne $Before) { $was = @($Before) }

    $now = @()
    if ($null -ne $After) { $now = @($After) }

    # LENGTH FIRST. See the note above.
    if ($was.Count -ne $now.Count) { return $true }

    for ($i = 0; $i -lt $was.Count; $i++) {
        if ([string] $now[$i] -cne [string] $was[$i]) { return $true }
    }

    return $false
}
