function Set-HDTConsoleBlockIndent {
    <#
        .SYNOPSIS
            Shifts a copied block to the indentation of where it is being
            pasted.

        .DESCRIPTION
            YAML IS WHITESPACE-SIGNIFICANT, so a block copied from inside a
            group and pasted beside a top-level step arrives two columns out -
            and the difference between that and a parse error is a couple of
            spaces the administrator cannot see.

            EVERY LINE SHIFTS BY THE SAME AMOUNT, which is what preserves the
            block's own internal shape: the properties stay indented relative to
            their dash line, and a comment above it stays aligned with it.

            THE SHIFT IS TAKEN FROM THE DASH LINE, not from the first line of
            the block. A block usually starts with a comment, and a comment may
            legally sit at any column; measuring from it would move the step to
            wherever the comment happened to be.

            IT NEVER SHIFTS A LINE LEFT PAST COLUMN ZERO. A block pasted from a
            deep group into a shallow one would otherwise produce negative
            indentation, which in practice means the line loses characters.

        .PARAMETER Block
            The copied lines.

        .PARAMETER Indent
            The column the dash line should end up at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTConsoleBlockIndent -Block $block -Indent 6
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns reindented copies of in-memory lines; it changes no state.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Block,

        [Parameter(Mandatory = $true, Position = 1)]
        [int] $Indent
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The dash line is the block's anchor; a leading comment may sit anywhere.
    $current = -1

    foreach ($line in $Block) {
        if ($line -match '^(\s*)-\s+\S') {
            $current = $Matches[1].Length
            break
        }
    }

    if ($current -lt 0 -or $current -eq $Indent) {
        return [string[]] @($Block)
    }

    $shift = $Indent - $current
    $result = New-Object -TypeName System.Collections.ArrayList

    foreach ($line in $Block) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            [void] $result.Add($line)
            continue
        }

        if ($shift -gt 0) {
            [void] $result.Add((' ' * $shift) + $line)
            continue
        }

        # Never past column zero: the line would start losing characters.
        $lead = 0
        if ($line -match '^(\s*)') { $lead = $Matches[1].Length }

        $take = [Math]::Min(-$shift, $lead)

        [void] $result.Add($line.Substring($take))
    }

    return [string[]] @($result)
}
