function Get-HDTRuleKey {
    <#
        .SYNOPSIS
            Finds each key a rule declares, and the exact lines it occupies.

        .DESCRIPTION
            THE SHARED HALF OF EVERY EDIT MADE INSIDE A RULE. A rule's when: and
            set: are not single lines - a block mapping runs over as many lines
            as it has entries, and a list value runs over more - so replacing one
            means knowing where it starts and where it stops. Nothing else in the
            file may move.

            IT RETURNS A RANGE PER KEY, NOT A VALUE. The caller does the splicing,
            because the caller is the one that knows whether it is replacing,
            inserting or removing.

            IT HANDLES BOTH SPELLINGS OF A MAPPING. A hand-written when: is
            usually one flow line, { HDTModel: 'Latitude*' }, and a generated one
            is a key per line; both are just a range, so neither is a special
            case and neither is reformatted when the other is edited.

            A KEY IS A LINE AT THE RULE'S OWN COLUMN. Anything deeper belongs to
            the key above it - the entries of a set:, the items of a list - which
            is what makes the range the whole mapping rather than its first line.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            One block from Get-HDTRuleBlock.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Name    the key, exactly as it is written in the file
              Index   the line the key starts on
              End     the last line the key owns, blanks and trailing comments
                      excluded
              Indent  the column this rule's keys are written at

        .EXAMPLE
            Get-HDTRuleKey -Line $line -Block $block
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Block
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A key sits two columns in from the dash that opened the rule, which is what
    # `- name: X` / `  when: ...` means as an indentation.
    $indent = [int] $Block.Indent + 2

    $entry = [int] $Block.Entry
    $last = [int] $Block.End

    $found = New-Object -TypeName System.Collections.ArrayList

    for ($i = $entry; $i -le $last; $i++) {
        $text = $Line[$i]

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^\s*#') { continue }

        $name = ''

        if ($i -eq $entry -and $text -match '^\s*-\s+([A-Za-z][\w-]*):') {
            $name = $Matches[1]
        } elseif ($text -match ('^\s{{{0}}}([A-Za-z][\w-]*):' -f $indent)) {
            $name = $Matches[1]
        } else {
            # Deeper than this rule's keys - a mapping's entries or a list's
            # items, which the key above owns and does not name.
            continue
        }

        [void] $found.Add([pscustomobject] @{
                Name   = $name
                Index  = $i
                End    = $i
                Indent = $indent
            })
    }

    # -- each key's span ---------------------------------------------------

    for ($k = 0; $k -lt $found.Count; $k++) {
        $end = $last
        if ($k + 1 -lt $found.Count) { $end = [int] $found[$k + 1].Index - 1 }

        # A blank line or a comment between two keys belongs to neither.
        while ($end -gt [int] $found[$k].Index -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^\s*#')) {
            $end--
        }

        $found[$k].End = $end
    }

    return [pscustomobject[]] @($found)
}
