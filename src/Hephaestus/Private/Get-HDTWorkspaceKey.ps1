function Get-HDTWorkspaceKey {
    <#
        .SYNOPSIS
            Finds the exact lines one key of a workspace document occupies,
            following a path down through the nested blocks.

        .DESCRIPTION
            THE FOUNDATION OF EVERY EDIT MADE TO WORKSPACE.YAML, the way
            Get-HDTRuleBlock is for rules.yaml. Every authoring command is a
            splice of a whole line range, so nothing round-trips through the YAML
            parser - the parser yields a dictionary and a dictionary has no
            comments in it. A workspace.yaml is created with a comment header
            explaining deployRoot and the engine defaults, and an administrator
            adds their own notes beside every key they set; a save that
            re-serialised a model would delete all of it.

            IT TAKES A PATH, NOT A NAME. workspace.yaml is a mapping of mappings -
            bootImage, extraContent - so 'the key' is only meaningful as
            @('bootImage', 'extraContent'). Each level is searched only inside the
            range the level above owns, which is what stops a top-level name:
            being mistaken for bootImage's own name:.

            A KEY OWNS EVERY DEEPER LINE UNDER IT, AND ITS BLOCK SEQUENCE
            WHEREVER YAML LETS IT SIT. A sequence may be indented under its key or
            written at the key's own column, and ConvertTo-HDTYaml - what
            New-HDTWorkspace writes the first workspace.yaml of every share with -
            emits the second. Reading a dash at the parent's column as the next
            key would end the block before its first entry, which is how the rules
            editor once managed to be unable to touch the file the toolkit itself
            writes.

            A TRAILING BLANK LINE OR COMMENT IS NOT PART OF A KEY. Taking the
            blank would collapse the file's spacing a little further with every
            edit; taking a comment would let one key's removal delete the sentence
            written above the next.

            ChildIndent IS THE COLUMN THE KEY'S CONTENTS ARE WRITTEN AT, and -1
            when it has none - a scalar, or an empty block. It is what an insert
            has to match, and what tells a removal that the block it just emptied
            should go too.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Path
            The key path, outermost first - @('logLevel') or
            @('bootImage', 'extraContent').

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            $null when the path is not in the document, otherwise
            System.Management.Automation.PSCustomObject:

              Name         the key, as written
              Index        the line the key starts on
              End          the last line it owns, blanks and trailing comments
                           excluded
              Indent       the column the key itself sits at
              ChildIndent  the column its contents sit at, or -1

        .EXAMPLE
            Get-HDTWorkspaceKey -Line $line -Path @('bootImage', 'extraContent')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]   # a blank line IS an empty string, and this is a whole document
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $from = 0
    $to = $Line.Count - 1
    $indent = 0
    $result = $null

    foreach ($name in @($Path)) {
        # A level whose parent had no contents cannot hold anything.
        if ($indent -lt 0) { return $null }

        $at = -1

        for ($i = $from; $i -le $to; $i++) {
            $text = $Line[$i]

            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($text -match '^ *#') { continue }

            $lead = 0
            if ($text -match '^( *)') { $lead = $Matches[1].Length }

            # Shallower than this level means the parent's region has ended.
            if ($lead -lt $indent) { break }
            if ($lead -ne $indent) { continue }

            # A dash at this column is a sequence entry, never a key.
            if ($text -match '^ *-( |$)') { continue }

            if ($text -match '^ *([A-Za-z][\w-]*):') {
                if ($Matches[1] -eq $name) {
                    $at = $i
                    break
                }
            }
        }

        if ($at -lt 0) { return $null }

        # -- how far the key reaches -----------------------------------------

        $end = $to

        for ($j = $at + 1; $j -le $to; $j++) {
            $text = $Line[$j]

            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($text -match '^ *#') { continue }

            $lead = 0
            if ($text -match '^( *)') { $lead = $Matches[1].Length }

            if ($lead -gt $indent) { continue }

            # THE SEQUENCE AT THE PARENT'S OWN COLUMN. Both spellings are legal
            # and the engine's reader takes both, so this has to as well.
            if ($lead -eq $indent -and $text -match '^ *-( |$)') { continue }

            $end = $j - 1
            break
        }

        while ($end -gt $at -and
            ([string]::IsNullOrWhiteSpace($Line[$end]) -or $Line[$end] -match '^ *#')) {
            $end--
        }

        # -- the column its contents are written at ---------------------------

        $childIndent = -1

        for ($j = $at + 1; $j -le $end; $j++) {
            $text = $Line[$j]

            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($text -match '^ *#') { continue }

            if ($text -match '^( *)') { $childIndent = $Matches[1].Length }
            break
        }

        $result = [pscustomobject] @{
            Name        = [string] $name
            Index       = $at
            End         = $end
            Indent      = $indent
            ChildIndent = $childIndent
        }

        $from = $at + 1
        $to = $end
        $indent = $childIndent
    }

    return $result
}
