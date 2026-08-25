function Get-HDTSelectionProfileLineMap {
    <#
        .SYNOPSIS
            Where each profile's lines are in a selection profile document.

        .DESCRIPTION
            WHAT MAKES New, Set AND Remove SPLICES RATHER THAN REWRITES. Parsing
            selection-profiles.yaml and writing it back would lose every comment
            in it, and this is a file an administrator explains their fleet in -
            "the HP pack is the G11 one, the G10 needs the old driver". So the
            three editors find the lines they mean and touch only those, and this
            is what finds them.

            IT READS THE TEXT, NOT THE PARSED DOCUMENT, because the parsed
            document has no line numbers on it. The YAML parser hands back an
            object graph and drops the file's shape on the floor - that is the
            same reason Assert-HDTSelectionProfileDocument names a profile id
            rather than a line.

            AN ENTRY RUNS FROM ITS DASH TO THE LINE BEFORE THE NEXT ONE, with
            trailing blank lines and trailing comments handed BACK to whatever
            follows. A comment sitting above a profile belongs to that profile in
            the reader's mind, but a comment sitting below the last include of one
            is nearly always about the next - and removing a profile must never
            silently take an administrator's sentence about a different one with
            it.

            THE LIST'S OWN INDENT IS READ, NOT ASSUMED. Two spaces is what this
            toolkit writes, but a document somebody hand-wrote with four still has
            to be editable, and a splicer that assumed two would insert an entry
            that parses as part of the one above it.

            'profiles: []' IS A LIST WITH NO ENTRIES, not an absent one. It is
            what Remove- leaves behind after the last profile goes, and New- has
            to be able to insert into it.

        .PARAMETER Line
            The document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with:

              ListIndex   the index of the 'profiles:' line, or -1
              ListInline  $true when it is written 'profiles: []'
              Indent      the column the entries' dashes sit at
              InsertAt    the index a new entry's first line goes at
              Entry       one object per profile, with Id, Start and End,
                          both inclusive

        .EXAMPLE
            (Get-HDTSelectionProfileLineMap -Line $line).Entry |
                Where-Object { $_.Id -eq 'boot-critical' }

            The lines Set- and Remove- rewrite.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string[]] @($Line)

    $listIndex = -1
    $listIndent = 0
    $listInline = $false

    for ($i = 0; $i -lt $text.Count; $i++) {
        if ($text[$i] -match '^(\s*)profiles\s*:(.*)$') {
            $listIndex = $i
            $listIndent = $Matches[1].Length
            $listInline = -not [string]::IsNullOrWhiteSpace($Matches[2])
            break
        }
    }

    $entry = New-Object -TypeName System.Collections.ArrayList

    if ($listIndex -lt 0) {
        return [pscustomobject] @{
            ListIndex  = -1
            ListInline = $false
            Indent     = ($listIndent + 2)
            InsertAt   = $text.Count
            Entry      = [pscustomobject[]] @()
        }
    }

    # -- walk the list --------------------------------------------------------

    $dashIndent = -1
    $current = $null
    $lastContent = $listIndex

    for ($i = $listIndex + 1; $i -lt $text.Count; $i++) {
        $raw = $text[$i]

        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $indent = ($raw -replace '^(\s*).*$', '$1').Length
        $trimmed = $raw.Trim()

        # A comment carries no indent an author can be held to - one flush left
        # above a nested entry is ordinary - so it never ends the list and never
        # ends an entry.
        if ($trimmed.StartsWith('#')) { continue }

        # A line at or left of 'profiles:' is the next top-level key, and the
        # list stopped at the last thing that was in it - which $lastContent is
        # already holding.
        if ($indent -le $listIndent) { break }

        if ($trimmed.StartsWith('-')) {
            if ($dashIndent -lt 0) { $dashIndent = $indent }

            if ($indent -eq $dashIndent) {
                if ($null -ne $current) {
                    $current.End = $lastContent
                    [void] $entry.Add($current)
                }

                $current = [pscustomobject] @{ Id = ''; Start = $i; End = $i }
            }
        }

        # The id, whether it is on the dash line or a key below it.
        if ($null -ne $current) {
            if ($trimmed -match '^(-\s*)?id\s*:\s*(.+)$') {
                $value = $Matches[2].Trim()

                # An inline comment after the value is not part of it.
                if ($value -match "^([^#]*?)\s+#") { $value = $Matches[1].Trim() }

                $current.Id = [string] ($value.Trim("'", '"'))
            }
        }

        $lastContent = $i
    }

    if ($null -ne $current) {
        $current.End = $lastContent
        [void] $entry.Add($current)
    }

    if ($dashIndent -lt 0) { $dashIndent = $listIndent + 2 }

    # WHERE A NEW ENTRY GOES: after the last line that belongs to the list, which
    # is the last entry's last content line - not $end, which may be several
    # blank lines and a comment about the NEXT block further down.
    $insertAt = $listIndex + 1
    if (@($entry).Count -gt 0) { $insertAt = @($entry)[-1].End + 1 }

    return [pscustomobject] @{
        ListIndex  = $listIndex
        ListInline = $listInline
        Indent     = $dashIndent
        InsertAt   = $insertAt
        Entry      = [pscustomobject[]] @($entry)
    }
}
