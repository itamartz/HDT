function Set-HDTDocumentHeaderKey {
    <#
        .SYNOPSIS
            Replaces, inserts or removes one top-level key of a document,
            leaving every other line byte-identical.

        .DESCRIPTION
            The splice behind Set-HDTTaskSequenceProperty and
            Set-HDTOperatingSystemProperty, and the flat-header equivalent of
            Set-HDTWorkspaceKey's simplest case. sequence.yaml and os.yaml both
            open with a run of scalars and then a block, so there is nothing to
            build - only a line to replace, insert or drop.

            IT TAKES THE ORDER AND THE BLOCK RATHER THAN KNOWING THEM. A
            sequence header is schemaVersion, id, name, description and ends at
            steps: or variables:; an os header carries type, architecture,
            sourcePath and the rest and ends at images:. Two documents, one
            splice, and the caller says which it is holding.

            A TOP-LEVEL KEY IS ONE AT COLUMN ZERO. `name:` under a step is a
            step's name and is nested; matching on the word alone would rename
            the first step in the file instead of the sequence. The pattern is
            anchored at the start of the line for exactly that reason, and the
            search stops at the first line that begins a block - `steps:` or
            `variables:` - so nothing inside one is ever considered.

            WHERE A NEW KEY GOES IS AFTER THE ONE THAT PRECEDES IT in the order
            a sequence is written: schemaVersion, id, name, description. A
            document with no name gets one under id, where a reader looks for it,
            rather than at the top or the bottom.

            AN EMPTY VALUE REMOVES THE KEY, which is what "take the description
            away" has to mean. Writing `description:` with nothing after it would
            leave a key whose value is null.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Key
            The top-level key. A key not in the set cannot be spliced, so a
            document that declares a new editable one is added here.

        .PARAMETER Order
            The header's keys in the order the document writes them. A key that
            is not there yet lands after the last of these that is.

        .PARAMETER Block
            The keys whose line ends the header - everything below one is
            nested. As a regex alternation: 'steps|variables'.

            A DOCUMENT WITH NO NESTED BLOCK SAYS SO WITH '(?!)', the
            never-matching group, rather than with an empty string - this
            parameter is ValidateNotNullOrEmpty, so '' is refused at bind time
            and the command never runs. media.yaml is flat, and left at the
            sequence/os default a line that happened to open with 'steps:' would
            end the header early and every key below it would be INSERTED rather
            than replaced, leaving the document with two.

        .PARAMETER Value
            The value. Empty removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTDocumentHeaderKey -Line $line -Key 'name' -Value 'Windows 11'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a copy of in-memory lines. Save-HDTSequenceDocument is the only command that writes, and it carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        # THE SET IS A SURFACE. A key not named here cannot be spliced at all, so
        # a document that gains one and forgets this line has a key nothing can
        # edit. media.yaml added selectionProfile, output and enabled.
        [ValidateSet('name', 'version', 'description', 'folder',
            'selectionProfile', 'output', 'enabled')]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Order = @('schemaVersion', 'id', 'name', 'description'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Block = 'steps|variables'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A new key lands after the last of these that is actually present.
    $order = @($Order)
    $rank = [array]::IndexOf($order, $Key)

    $clear = [string]::IsNullOrWhiteSpace($Value)

    # A HEADER KEY IS ONE LINE, and a value carrying a newline is what happens
    # when one is read back out of a FOLDED block: YAML's > yields a string
    # ending in a newline, so the console hands back what it was shown and the
    # writer quoted it across three lines -
    #
    #     description: 'Deploys Windows to a bare machine: ... make it boot.
    #     folder: Clients\Bare metal
    #     '
    #
    # - which put the NEXT key inside the description and took the folder off
    # the tree. Nothing in a document header is meant to carry a paragraph, so
    # the value is collapsed rather than quoted across lines.
    #
    # \r?\n AS TWO-CHARACTER ESCAPES, NEVER AS A REAL NEWLINE PASTED INTO THE
    # PATTERN. This regex used to be written with an actual line break sitting
    # inside the single-quoted string in place of \n - which parses, and even
    # passes here, because a single-quoted string does not need an escape
    # sequence to contain one. But it makes the regex's MEANING depend on the
    # end-of-line bytes THIS SOURCE FILE happens to be saved with, and git's
    # CRLF normalisation can rewrite those bytes on checkout. A local working
    # tree edited in place kept LF and passed; a CI runner's fresh checkout
    # normalised to CRLF, the embedded newline stopped matching what it used
    # to, the collapse silently did nothing, and Import-HDTSequenceDocument
    # died on 'did not find expected key' - the exact failure this comment
    # block above already describes, reintroduced by the fix for it. Found
    # 2026-09-04 from a CI-only failure that would not reproduce locally.
    $oneLine = ($Value -replace '\s*\r?\n\s*', ' ').Trim()
    $written = '{0}: {1}' -f $Key, (Get-HDTConsoleScalarText -Value $oneLine)

    $at = -1
    $after = -1

    for ($i = 0; $i -lt @($Line).Count; $i++) {
        $current = [string] $Line[$i]

        # A LINE THAT OPENS A BLOCK ENDS THE HEADER. Everything below it is
        # nested, and a `name:` down there belongs to a step.
        if ($current -match ('^({0})\s*:' -f $Block)) { break }

        if ($current -match ('^{0}\s*:' -f [regex]::Escape($Key))) { $at = $i; break }

        if ($current -match '^([A-Za-z][A-Za-z0-9_]*)\s*:') {
            $seen = [array]::IndexOf($order, $Matches[1])
            if ($seen -ge 0 -and $seen -lt $rank) { $after = $i }
        }
    }

    # WHERE THE KEY'S VALUE ENDS, WHICH IS NOT ALWAYS ITS OWN LINE. The template
    # writes the description as a folded block:
    #
    #     description: >
    #       Deploys Windows to a bare machine: validate it, lay out the disk
    #       for its firmware, apply the image ...
    #
    # and replacing only the 'description: >' line left those continuation lines
    # behind with nothing to belong to - so the next key parsed as part of a
    # scalar and the whole document came back as "found invalid mapping". It was
    # reported from the console as a description that kept resetting: the write
    # was refused and the pane refilled from the file.
    #
    # A CONTINUATION IS AN INDENTED LINE, and a blank one inside the block
    # belongs to it too - but a blank line at the END is the separator before
    # the next key, so the run stops at the last indented line rather than at
    # the next key.
    $end = $at

    if ($at -ge 0) {
        $last = $at

        for ($i = $at + 1; $i -lt @($Line).Count; $i++) {
            $current = [string] $Line[$i]

            if ([string]::IsNullOrWhiteSpace($current)) { continue }
            if ($current -notmatch '^\s') { break }

            $last = $i
        }

        $end = $last
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt @($Line).Count; $i++) {
        if ($at -ge 0 -and $i -ge $at -and $i -le $end) {
            if ($i -eq $at -and -not $clear) { [void] $result.Add($written) }
            continue
        }

        [void] $result.Add($Line[$i])

        if ($at -lt 0 -and -not $clear -and $i -eq $after) { [void] $result.Add($written) }
    }

    # NOTHING TO REPLACE AND NOWHERE TO PUT IT is a document with no header keys
    # at all, which the validator refuses elsewhere. Written at the top rather
    # than dropped silently.
    if ($at -lt 0 -and $after -lt 0 -and -not $clear) {
        [void] $result.Insert(0, $written)
    }

    return [string[]] @($result)
}
