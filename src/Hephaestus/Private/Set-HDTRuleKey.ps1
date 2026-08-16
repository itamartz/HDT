function Set-HDTRuleKey {
    <#
        .SYNOPSIS
            Replaces, inserts or removes one key of one rule, leaving every other
            line byte-identical.

        .DESCRIPTION
            THE THREE-WAY SPLICE EVERY RULE EDIT COMES DOWN TO: rewrite the key's
            lines if it is there, insert them if it is not, drop them if the
            caller passed nothing. Written once, because when:, set: and setFrom:
            differ only in what goes in them.

            A NEW KEY GOES WHERE A RULE IS WRITTEN, which is name, then when,
            then set or setFrom. That is the order the engine's own documents and
            every worked example use, and it is the order an administrator
            scanning a diff expects: what the rule is called, when it applies,
            what it does. The key is inserted after the last key that precedes it
            in that order and is actually present, so a rule that has no when:
            still gets its set: in the right place.

            IT NEVER TOUCHES THE ENTRY LINE. `- name: X` is a list item whose
            first key happens to be the name; rewriting it as a plain key would
            fold the rule into the one above it. Renaming is done by the cmdlet
            that knows it is renaming.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            The rule's block, from Get-HDTRuleBlock, resolved against this
            same Line.

        .PARAMETER Key
            The key to write - 'when', 'set' or 'setFrom'.

        .PARAMETER Text
            The lines the key becomes. Empty removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTRuleKey -Line $line -Block $block -Key 'set' -Text $written

        .EXAMPLE
            Set-HDTRuleKey -Line $line -Block $block -Key 'when' -Text @()

            Removes the rule's conditions, so it always applies.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a copy of in-memory lines. Save-HDTRuleDocument is the only command that writes, and it carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
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
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The order a rule is written in, and therefore the order a new key is
    # inserted into.
    $order = @('name', 'when', 'set', 'setFrom')

    # Named for what it holds rather than $key: PowerShell variable names are
    # case-insensitive, so a local $key IS the $Key parameter.
    $declared = @(Get-HDTRuleKey -Line $Line -Block $Block)
    $found = @($declared | Where-Object { $_.Name -eq $Key })

    $replaceFrom = -1
    $replaceTo = -1
    $insertAfter = [int] $Block.Entry

    if (@($found).Count -gt 0) {
        $replaceFrom = [int] $found[0].Index
        $replaceTo = [int] $found[0].End
    } else {
        $rank = [array]::IndexOf($order, $Key)

        foreach ($current in $declared) {
            $at = [array]::IndexOf($order, [string] $current.Name)

            # An unknown key keeps whatever place it has in the file rather than
            # being jumped over; the document validator is what refuses it.
            if ($at -lt 0) { $at = $order.Count }

            if ($at -lt $rank -and [int] $current.End -gt $insertAfter) {
                $insertAfter = [int] $current.End
            }
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($replaceFrom -ge 0 -and $i -ge $replaceFrom -and $i -le $replaceTo) {
            if ($i -eq $replaceFrom) {
                foreach ($current in $Text) { [void] $result.Add($current) }
            }

            continue
        }

        [void] $result.Add($Line[$i])

        if ($replaceFrom -lt 0 -and $i -eq $insertAfter) {
            foreach ($current in $Text) { [void] $result.Add($current) }
        }
    }

    return [string[]] @($result)
}
