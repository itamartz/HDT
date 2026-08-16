function Get-HDTConsoleStepKey {
    <#
        .SYNOPSIS
            Finds one key inside a step's own lines, and the line a new key
            would go after.

        .DESCRIPTION
            THE SHARED HALF OF EVERY "SET A PROPERTY" EDIT. Setting `disabled`,
            `continueOnError` or `condition` is the same three-way splice each
            time - rewrite the line if the key is there, insert one if it is
            not, and know exactly which lines count as this step's - so it is
            written once and the cmdlets above it only decide the value.

            A GROUP'S OWN KEYS STOP AT ITS `steps:`. Get-HDTConsoleStepBlock
            hands back a block that covers the whole group INCLUDING the steps
            nested inside it, which is right for moving and copying and wrong
            for this: a group whose first step already carries `disabled: true`
            would otherwise look like a group that is already switched off, and
            setting the group's flag would rewrite the step's line instead.
            The scan therefore stops at the first nested entry or at `steps:`,
            whichever comes first.

            A NEW KEY GOES DIRECTLY UNDER `type:`, WHERE THE ENGINE'S OWN
            DOCUMENTS PUT IT. What a step is comes first, how it behaves comes
            next, and the per-type properties follow - which is the order every
            sample sequence in this repository is written in, and the order an
            administrator scanning a diff expects. A group has no `type:`, so
            its key goes after the last line that is still the group's own.

            IT RETURNS AN INDEX, NOT A LINE. The caller does the splicing,
            because the caller is the one that knows whether it is inserting,
            rewriting or removing - and a helper that did all three would be a
            second copy of the three cmdlets that call it.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            One block from Get-HDTConsoleStepBlock.

        .PARAMETER Key
            The YAML key to find, exactly as it is written in the file.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Index   the line the key is on, or -1 when the step has no such key
              Insert  the line a new one would go directly after
              Indent  the column this step's keys are written at

        .EXAMPLE
            Get-HDTConsoleStepKey -Line $line -Block $block -Key 'disabled'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Block,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Key
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A key sits two columns in from the dash that opened the entry, which is
    # what `- name: X` / `  type: Y` means as an indentation.
    $indent = [int] $Block.Indent + 2

    $index = -1
    $typeAt = -1
    $lastOwn = [int] $Block.Entry

    for ($i = [int] $Block.Entry; $i -le [int] $Block.End; $i++) {
        $text = $Line[$i]

        # The nested list a group holds is not the group's own text, and neither
        # is anything after it.
        if ($i -gt [int] $Block.Entry -and $text -match '^\s*-\s') { break }
        if ($text -match '^\s*steps:\s*$') { break }

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^\s*#') { continue }

        # Either the entry line itself (`- name: X`) or a key under it.
        $name = ''

        if ($i -eq [int] $Block.Entry -and $text -match '^\s*-\s+([A-Za-z][\w-]*):') {
            $name = $Matches[1]
        } elseif ($text -match ('^\s{{{0}}}([A-Za-z][\w-]*):' -f $indent)) {
            $name = $Matches[1]
        } else {
            # Deeper than this step's keys - a nested mapping's contents, which
            # this step owns but does not name.
            continue
        }

        $lastOwn = $i

        if ($name -eq $Key) { $index = $i }
        if ($name -eq 'type') { $typeAt = $i }
    }

    $insert = $lastOwn
    if ($typeAt -ge 0) { $insert = $typeAt }

    return [pscustomobject] @{
        Index  = $index
        Insert = $insert
        Indent = $indent
    }
}
