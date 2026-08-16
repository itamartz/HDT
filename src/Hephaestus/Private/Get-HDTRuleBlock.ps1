function Get-HDTRuleBlock {
    <#
        .SYNOPSIS
            Finds the exact lines each rule occupies in a rules document.

        .DESCRIPTION
            THE FOUNDATION OF EVERY EDIT MADE TO RULES.YAML. Add, Set and Remove
            are splices of whole line ranges, and Save is then writing the string
            back unchanged everywhere else. Nothing round-trips through the YAML
            parser, because the parser yields a dictionary and a dictionary has
            no comments in it - a rules.yaml is created with a comment header
            carrying a worked example, and an administrator adds their own
            explanation beside every rule they write. A save that re-serialised a
            model would delete all of it.

            A COMMENT ABOVE A RULE BELONGS TO THAT RULE, so Start reaches back
            over it while Entry stays on the dash line. The comment above a rule
            is what says why the rule is there and why it sits where it does;
            deleting the rule and leaving the explanation behind, now attached to
            whatever took its place, makes the file state something untrue.

            ONLY ENTRIES AT THE RULE COLUMN ARE RULES. A set: value may be a
            list, and a list item is a dash line too - taking those for rules
            would report a document of four rules as a document of seven.

            A TRAILING BLANK LINE IS NOT PART OF A BLOCK, and neither is the
            document header. Taking the blank would collapse the file's spacing a
            little further with every edit; taking the header would let a rule
            removal delete the explanation of the whole file.

        .PARAMETER Line
            The document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Name    the rule name
              Indent  the column the dash sits at, which an insert must match
              Entry   the index of the '- ' line
              Start   Entry, or the first line of the comment above it
              End     the last line the rule owns, blanks excluded

        .EXAMPLE
            Get-HDTRuleBlock -Line ($text -split "`r?`n")
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]   # a blank line IS an empty string, and this is a whole document
        [string[]] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $found = New-Object -TypeName System.Collections.ArrayList

    # -- the rules: region -------------------------------------------------

    $rulesAt = -1

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^rules:\s*$') {
            $rulesAt = $i
            break
        }
    }

    if ($rulesAt -lt 0) {
        return [pscustomobject[]] @()
    }

    # It runs to the next top-level key, or to the end of the document.
    $regionEnd = $Line.Count - 1

    for ($i = $rulesAt + 1; $i -lt $Line.Count; $i++) {
        $text = $Line[$i]

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^\s*#') { continue }

        # A DASH AT COLUMN ZERO IS A RULE, NOT THE NEXT KEY. YAML lets a block
        # sequence sit at its parent's own indentation, and ConvertTo-HDTYaml -
        # what New-HDTWorkspace writes the first rules.yaml with - emits exactly
        # that. Reading '- name: Fallback' as a new top-level key ended the
        # region before the first rule and left the document looking like one
        # with no rules in it, which is a file this editor could not touch at
        # all. Both spellings are valid and the engine's reader takes both, so
        # this has to as well.
        if ($text -match '^-(\s|$)') { continue }

        if ($text -match '^\S') {
            $regionEnd = $i - 1
            break
        }
    }

    # -- the column the rules are written at -------------------------------

    $ruleIndent = -1

    for ($i = $rulesAt + 1; $i -le $regionEnd; $i++) {
        if ($Line[$i] -match '^(\s*)-\s+\S') {
            $ruleIndent = $Matches[1].Length
            break
        }
    }

    if ($ruleIndent -lt 0) {
        return [pscustomobject[]] @()
    }

    # -- every rule in it --------------------------------------------------

    # Only dash lines at the rule column. A deeper one is an item of a list a
    # rule assigns, which the rule owns and which is not a rule.
    $entry = New-Object -TypeName System.Collections.ArrayList

    for ($i = $rulesAt + 1; $i -le $regionEnd; $i++) {
        if ($Line[$i] -match '^(\s*)-\s+\S' -and $Matches[1].Length -eq $ruleIndent) {
            [void] $entry.Add($i)
        }
    }

    # -- each rule's span and name -----------------------------------------

    for ($e = 0; $e -lt $entry.Count; $e++) {
        $at = [int] $entry[$e]

        $end = $regionEnd
        if ($e + 1 -lt $entry.Count) { $end = [int] $entry[$e + 1] - 1 }

        # Blank lines and the next rule's comments are not this rule's.
        while ($end -gt $at -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^\s*#')) {
            $end--
        }

        # A comment directly above the dash line explains this rule. The guard
        # stops at the first line of the region, so the document header - which
        # explains the file rather than any rule in it - belongs to no rule.
        $start = $at

        while ($start -gt ($rulesAt + 1) -and $Line[$start - 1] -match '^\s*#') {
            $start--
        }

        # -- what it is called

        $name = ''

        for ($s = $at; $s -le $end; $s++) {
            if ($Line[$s] -match '^\s*(?:-\s+)?name:\s*(.+?)\s*$') {
                $name = $Matches[1]

                # A trailing comment is not part of the name, but a '#' inside a
                # quoted name is.
                if ($name -notmatch '^["'']' -and $name -match '^(.*?)\s+#') {
                    $name = $Matches[1]
                }

                $name = $name.Trim().Trim('"', "'")
                break
            }
        }

        [void] $found.Add([pscustomobject] @{
                Name   = $name
                Indent = $ruleIndent
                Entry  = $at
                Start  = $start
                End    = $end
            })
    }

    return [pscustomobject[]] @($found)
}
