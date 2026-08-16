function Get-HDTWorkspaceItem {
    <#
        .SYNOPSIS
            Finds the lines each entry of a block sequence occupies.

        .DESCRIPTION
            WHAT LETS ONE extraContent ENTRY BE REMOVED WITHOUT THE OTHERS MOVING.
            An entry is not a line: a source and a destination are two, and a
            multi-line entry is more. Removing one means knowing where it starts
            and where it stops, and nothing else in the file may shift.

            THE ENTRIES ARE RETURNED IN DOCUMENT ORDER AND ONLY IN DOCUMENT
            ORDER. Which entry is which is settled by counting - the engine's own
            reader yields the same list in the same order, so the caller matches
            the parsed entry to the line range by position rather than by
            re-implementing a scalar parser here and getting the quoting subtly
            different.

            A DASH AT THE KEY'S CONTENT COLUMN IS AN ENTRY, AND NOTHING DEEPER IS.
            A nested list inside an entry is the entry's own business.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            The sequence's key, from Get-HDTWorkspaceKey.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Index   the line the entry's dash sits on
              End     the last line the entry owns
              Indent  the column the dashes are written at

        .EXAMPLE
            Get-HDTWorkspaceItem -Line $line -Block (Get-HDTWorkspaceKey -Line $line -Path @('bootImage', 'extraContent'))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [object] $Block
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Block) { return [pscustomobject[]] @() }

    $indent = [int] $Block.ChildIndent
    if ($indent -lt 0) { return [pscustomobject[]] @() }

    $from = [int] $Block.Index + 1
    $to = [int] $Block.End

    $found = New-Object -TypeName System.Collections.ArrayList

    for ($i = $from; $i -le $to; $i++) {
        $text = $Line[$i]

        if ($text -notmatch '^( *)-( |$)') { continue }
        if ($Matches[1].Length -ne $indent) { continue }

        [void] $found.Add([pscustomobject] @{
                Index  = $i
                End    = $i
                Indent = $indent
            })
    }

    for ($k = 0; $k -lt $found.Count; $k++) {
        $end = $to
        if ($k + 1 -lt $found.Count) { $end = [int] $found[$k + 1].Index - 1 }

        while ($end -gt [int] $found[$k].Index -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^ *#')) {
            $end--
        }

        $found[$k].End = $end
    }

    return [pscustomobject[]] @($found)
}
