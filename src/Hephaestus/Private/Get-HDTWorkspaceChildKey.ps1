function Get-HDTWorkspaceChildKey {
    <#
        .SYNOPSIS
            Lists the keys written directly inside one block of a workspace
            document, and the lines each of them occupies.

        .DESCRIPTION
            WHAT AN INSERT NEEDS BEFORE IT CAN CHOOSE A PLACE. A new key goes
            where the document's own order puts it - name, then architecture,
            then language - and working out which sibling it belongs after means
            knowing which siblings are there and where each of them ends.

            IT LOOKS ONE LEVEL DOWN AND NO FURTHER. bootImage's own keys are its
            children; the entries of the extraContent underneath one of them are
            not, and reporting them would make an insert land inside a list.

            A BLOCK OF $null MEANS THE DOCUMENT ITSELF, whose children are the
            top-level keys. That is a real case rather than a convenience: the
            bootImage block is created by an insert at the top level, and it needs
            the same ordering answer as everything nested.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            One block from Get-HDTWorkspaceKey, or $null for the document root.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Name    the key, as written
              Index   the line the key starts on
              End     the last line it owns
              Indent  the column these keys are written at

        .EXAMPLE
            Get-HDTWorkspaceChildKey -Line $line -Block (Get-HDTWorkspaceKey -Line $line -Path @('bootImage'))
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

    $from = 0
    $to = $Line.Count - 1
    $indent = 0

    if ($null -ne $Block) {
        $from = [int] $Block.Index + 1
        $to = [int] $Block.End
        $indent = [int] $Block.ChildIndent
    }

    if ($indent -lt 0) { return [pscustomobject[]] @() }

    $found = New-Object -TypeName System.Collections.ArrayList

    for ($i = $from; $i -le $to; $i++) {
        $text = $Line[$i]

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^ *#') { continue }

        $lead = 0
        if ($text -match '^( *)') { $lead = $Matches[1].Length }

        if ($lead -ne $indent) { continue }
        if ($text -match '^ *-( |$)') { continue }
        if ($text -notmatch '^ *([A-Za-z][\w-]*):') { continue }

        [void] $found.Add([pscustomobject] @{
                Name   = $Matches[1]
                Index  = $i
                End    = $i
                Indent = $indent
            })
    }

    # -- how far each of them reaches ----------------------------------------

    for ($k = 0; $k -lt $found.Count; $k++) {
        $end = $to
        if ($k + 1 -lt $found.Count) { $end = [int] $found[$k + 1].Index - 1 }

        # A blank line or a comment between two keys belongs to neither.
        while ($end -gt [int] $found[$k].Index -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^ *#')) {
            $end--
        }

        $found[$k].End = $end
    }

    return [pscustomobject[]] @($found)
}
