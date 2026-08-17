function Set-HDTSequenceHeaderKey {
    <#
        .SYNOPSIS
            Replaces, inserts or removes one top-level key of a sequence
            document, leaving every other line byte-identical.

        .DESCRIPTION
            The splice behind Set-HDTTaskSequenceProperty, and the sequence
            equivalent of Set-HDTWorkspaceKey's simplest case: sequence.yaml's
            header is flat - schemaVersion, id, name, description - so there are
            no blocks to build.

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
            The top-level key: name or description.

        .PARAMETER Value
            The value. Empty removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTSequenceHeaderKey -Line $line -Key 'name' -Value 'Windows 11'
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
        [ValidateSet('name', 'description')]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The order a sequence header is written in. A new key lands after the last
    # of these that is actually present.
    $order = @('schemaVersion', 'id', 'name', 'description')
    $rank = [array]::IndexOf($order, $Key)

    $clear = [string]::IsNullOrWhiteSpace($Value)
    $written = '{0}: {1}' -f $Key, (Get-HDTConsoleScalarText -Value $Value)

    $at = -1
    $after = -1

    for ($i = 0; $i -lt @($Line).Count; $i++) {
        $current = [string] $Line[$i]

        # A LINE THAT OPENS A BLOCK ENDS THE HEADER. Everything below it is
        # nested, and a `name:` down there belongs to a step.
        if ($current -match '^(steps|variables)\s*:') { break }

        if ($current -match ('^{0}\s*:' -f [regex]::Escape($Key))) { $at = $i; break }

        if ($current -match '^([A-Za-z][A-Za-z0-9_]*)\s*:') {
            $seen = [array]::IndexOf($order, $Matches[1])
            if ($seen -ge 0 -and $seen -lt $rank) { $after = $i }
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt @($Line).Count; $i++) {
        if ($at -ge 0 -and $i -eq $at) {
            if (-not $clear) { [void] $result.Add($written) }
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
