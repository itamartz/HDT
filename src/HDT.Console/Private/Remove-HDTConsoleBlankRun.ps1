function Remove-HDTConsoleBlankRun {
    <#
        .SYNOPSIS
            Collapses a run of consecutive blank lines left behind by a splice.

        .DESCRIPTION
            A removed block leaves the blank line that separated it from the
            block below sitting directly beneath the blank line that separated
            it from the block above. Left alone, a file grows one blank line
            every time a step is deleted, and after a few edits the spacing no
            longer means anything.

            IT ONLY EVER REMOVES BLANK LINES, and only where two or more are
            adjacent at the point an edit happened. It never touches a blank
            line elsewhere in the document, so the header's own spacing and any
            deliberate gap the author left are exactly as they were.

        .PARAMETER Line
            The document after a splice.

        .PARAMETER At
            The index the splice happened at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Remove-HDTConsoleBlankRun -Line $line -At 42
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a copy of in-memory lines. Save-HDTConsoleSequence is the only command that writes, and it carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [int] $At
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = @($Line)

    if ($At -le 0 -or $At -ge $result.Count) {
        return [string[]] $result
    }

    # One blank is spacing; two in a row at the seam is the gap the removal left.
    if ([string]::IsNullOrWhiteSpace($result[$At]) -and
        [string]::IsNullOrWhiteSpace($result[$At - 1])) {

        $keep = New-Object -TypeName System.Collections.ArrayList

        for ($i = 0; $i -lt $result.Count; $i++) {
            if ($i -eq $At) { continue }

            [void] $keep.Add($result[$i])
        }

        return [string[]] @($keep)
    }

    return [string[]] $result
}
