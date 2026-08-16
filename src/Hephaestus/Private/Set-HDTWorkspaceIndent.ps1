function Set-HDTWorkspaceIndent {
    <#
        .SYNOPSIS
            Shifts a composed block to the column it is being written at.

        .DESCRIPTION
            YAML IS WHITESPACE-SIGNIFICANT, so a key composed at column zero and
            dropped into a nested block arrives two columns out - and the
            difference between that and a document the engine refuses is a couple
            of spaces the administrator cannot see.

            EVERY LINE SHIFTS BY THE SAME AMOUNT, which is what preserves the
            block's own internal shape: a sequence entry stays where it was
            relative to its key, and a two-line entry stays one entry.

            THE SHIFT IS TAKEN FROM THE FIRST NON-BLANK LINE, which for a mapping
            key is the key line itself. Set-HDTBlockIndent - the task sequence
            editor's equivalent - measures from the DASH line instead, because a
            step is a sequence entry and its first line is usually a comment.
            Neither anchor works for the other's blocks: a `key:` block whose
            first entry is a dash would be shifted by that dash's column and land
            two columns short.

        .PARAMETER Block
            The composed lines, written at column zero.

        .PARAMETER Indent
            The column the first line should end up at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTWorkspaceIndent -Block @('drivers: boot-critical') -Indent 2
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

    $current = -1

    foreach ($line in $Block) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^( *)') { $current = $Matches[1].Length }
        break
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
        if ($line -match '^( *)') { $lead = $Matches[1].Length }

        [void] $result.Add($line.Substring([Math]::Min(-$shift, $lead)))
    }

    return [string[]] @($result)
}
