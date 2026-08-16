function Get-HDTStepBlock {
    <#
        .SYNOPSIS
            Finds the exact lines each step and group occupies in a sequence
            document.

        .DESCRIPTION
            THE FOUNDATION OF EVERY EDIT THE CONSOLE MAKES. Add, Remove, Up,
            Down and Paste are all splices of whole line ranges, and Save is
            then writing the string back unchanged everywhere else. Nothing
            round-trips through the YAML parser, because ConvertFrom-HDTYaml
            yields a dictionary and a dictionary has no comments in it - DEMO-M4
            on the lab share is 107 lines of which about 60 are a comment header
            recording findings from the lab, and a save that re-serialised a model
            would delete every one: "a UI that reformats the file
            breaks git review, which is one of the reasons config-as-code fails
            in practice."

            A COMMENT ABOVE A STEP BELONGS TO THAT STEP, so Start reaches back
            over it while Entry stays on the dash line. Every comment in DEMO-M4
            explains the step beneath it - why minRamMB is 2048, why wipe: true
            is the sequence declaring the disk expendable. Moving a step and
            leaving its explanation behind, now attached to whatever took its
            place, would be worse than not moving it.

            A TRAILING BLANK LINE IS NOT PART OF A BLOCK. Taking it would
            collapse the file's spacing a little more with every edit until the
            document became one dense wall.

            THE DOCUMENT HEADER BELONGS TO NO BLOCK. It explains the file rather
            than any step in it, so nothing here can move or delete it.

        .PARAMETER Line
            The document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Kind    'Step' or 'Group'
              Name    the step or group name
              Indent  the column the dash sits at, which an insert must match
              Entry   the index of the '- ' line
              Start   Entry, or the first line of the comment above it
              End     the last line the block owns, blanks excluded

        .EXAMPLE
            Get-HDTStepBlock -Line ($text -split "`r?`n")
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

    # -- the steps: region -------------------------------------------------

    $stepsAt = -1

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^steps:\s*$') {
            $stepsAt = $i
            break
        }
    }

    if ($stepsAt -lt 0) {
        return [pscustomobject[]] @()
    }

    # It runs to the next top-level key, or to the end of the document.
    $regionEnd = $Line.Count - 1

    for ($i = $stepsAt + 1; $i -lt $Line.Count; $i++) {
        $text = $Line[$i]

        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^\s*#') { continue }

        if ($text -match '^\S' ) {
            $regionEnd = $i - 1
            break
        }
    }

    # -- every entry in it -------------------------------------------------

    $entry = New-Object -TypeName System.Collections.ArrayList

    for ($i = $stepsAt + 1; $i -le $regionEnd; $i++) {
        if ($Line[$i] -match '^(\s*)-\s+\S') {
            [void] $entry.Add([pscustomobject] @{
                    Index  = $i
                    Indent = $Matches[1].Length
                })
        }
    }

    # -- each entry's span, kind and name ----------------------------------

    for ($e = 0; $e -lt $entry.Count; $e++) {
        $current = $entry[$e]

        # The block ends where the next entry at the same or shallower
        # indentation begins. A group therefore covers its own steps, which sit
        # deeper than it does.
        $end = $regionEnd

        for ($n = $e + 1; $n -lt $entry.Count; $n++) {
            if ($entry[$n].Indent -le $current.Indent) {
                $end = $entry[$n].Index - 1
                break
            }
        }

        # Blank lines and the next block's comments are not this block's.
        while ($end -gt $current.Index -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^\s*#')) {
            $end--
        }

        # A comment directly above the dash line explains this block.
        $start = $current.Index

        while ($start -gt ($stepsAt + 1) -and $Line[$start - 1] -match '^\s*#') {
            $start--
        }

        # -- what it is, and what it is called

        $kind = 'Step'
        $name = ''

        for ($s = $current.Index; $s -le $end; $s++) {
            if ($Line[$s] -match '^\s*(?:-\s+)?(name|group):\s*(.+?)\s*$') {
                $kind = 'Step'
                if ($Matches[1] -eq 'group') { $kind = 'Group' }

                $name = $Matches[2].Trim('"', "'")
                break
            }
        }

        [void] $found.Add([pscustomobject] @{
                Kind   = $kind
                Name   = $name
                Indent = $current.Indent
                Entry  = $current.Index
                Start  = $start
                End    = $end
            })
    }

    return [pscustomobject[]] @($found)
}
