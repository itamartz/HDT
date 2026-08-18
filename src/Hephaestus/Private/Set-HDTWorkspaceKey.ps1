function Set-HDTWorkspaceKey {
    <#
        .SYNOPSIS
            Replaces, inserts or removes one key of a workspace document,
            building the blocks above it when they are not there, and leaving
            every other line byte-identical.

        .DESCRIPTION
            THE SPLICE EVERY WORKSPACE EDIT COMES DOWN TO: rewrite the key's lines
            if it is there, insert them if it is not, drop them if the caller
            passed nothing. Written once, because logLevel, drivers, extraContent
            and startCommand differ only in what goes in them.

            IT BUILDS THE BLOCKS THAT ARE MISSING, and that is what makes it
            different from the rules editor's equivalent. rules.yaml always has a
            rules: list to splice into; workspace.yaml usually has NO bootImage
            block at all, because New-HDTWorkspace deliberately writes none - an
            omitted setting takes the engine's default, and a copied-out default
            goes stale the day the engine's changes. So the first boot image
            setting an administrator writes has to create bootImage:, its nested
            key, and the value, in one insert.

            A NEW KEY GOES WHERE THE DOCUMENT'S OWN ORDER PUTS IT - identity,
            then deployRoot, then logLevel, then the blocks; and inside bootImage,
            the artifact settings, then the lists, then the entry and start
            commands. That is the order every worked example and every document
            this toolkit writes uses, and it is the order an administrator
            scanning a diff expects. The key is inserted after the last key that
            precedes it in that order and is actually present.

            A NEW BLOCK AT THE TOP LEVEL GETS A BLANK LINE ABOVE IT, so it is
            spaced the way the rest of the file is rather than welded to the key
            above.

            THE TEXT ARRIVES AT COLUMN ZERO AND IS SHIFTED TO WHERE IT LANDS,
            which is the same reindenting a pasted task sequence step goes
            through and for the same reason: the block's internal shape survives,
            and the key ends up in the one column that makes it a key.

            REMOVING A KEY THAT WAS THE LAST THING IN ITS BLOCK REMOVES THE BLOCK.
            A bootImage: with nothing under it parses as a null, and the engine
            refuses a workspace whose bootImage is not a mapping - so leaving the
            husk behind would produce a document that cannot be loaded, from a
            command whose whole job was to take one setting away.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Path
            The key path, outermost first.

        .PARAMETER Text
            The lines the key becomes, written at column zero. Empty removes the
            key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Set-HDTWorkspaceKey -Line $line -Path @('logLevel') -Text @('logLevel: Debug')

        .EXAMPLE
            Set-HDTWorkspaceKey -Line $line -Path @('bootImage', 'drivers') -Text @()

            Removes the boot driver group, and the bootImage block with it when
            that was all it held.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a copy of in-memory lines. Save-HDTWorkspaceDocument is the only command that writes, and it carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The order a workspace document is written in, per container. The root list
    # matches Assert-HDTWorkspaceDocument's allowed keys, and the bootImage list
    # matches its own - a key added there and forgotten here is inserted at the
    # top of its block rather than misplaced, which is untidy and never wrong.
    $order = @{
        ''          = @('schemaVersion', 'id', 'name', 'deployRoot', 'logLevel', 'credential', 'bootImage')
        'credential' = @('username')
        'bootImage' = @('name', 'architecture', 'language', 'scratchSpaceMB', 'optionalComponents',
            'extraContent', 'drivers', 'unattend', 'background', 'timeZone', 'rootCertificates',
            'clientCertificate', 'entryCommand', 'startCommand', 'skip')
    }

    $existing = Get-HDTWorkspaceKey -Line $Line -Path $Path

    # =====================================================================
    # THE KEY IS THERE: replace its lines, or take them out.
    # =====================================================================

    if ($null -ne $existing) {
        $written = [string[]] @(Set-HDTWorkspaceIndent -Block $Text -Indent ([int] $existing.Indent))

        $result = New-Object -TypeName System.Collections.ArrayList

        for ($i = 0; $i -lt $Line.Count; $i++) {
            if ($i -ge [int] $existing.Index -and $i -le [int] $existing.End) {
                if ($i -eq [int] $existing.Index) {
                    foreach ($current in $written) { [void] $result.Add($current) }
                }

                continue
            }

            [void] $result.Add($Line[$i])
        }

        $final = [string[]] @($result)

        if (@($Text).Count -eq 0) {
            $final = [string[]] @(Remove-HDTBlankRun -Line $final -At ([int] $existing.Index))

            # THE HUSK GOES WITH IT. A bootImage: left holding nothing is a
            # document the engine refuses to load.
            for ($depth = $Path.Count - 1; $depth -ge 1; $depth--) {
                $parent = Get-HDTWorkspaceKey -Line $final -Path ([string[]] @($Path[0..($depth - 1)]))

                if ($null -eq $parent) { continue }
                if ([int] $parent.ChildIndent -ge 0) { break }

                $keep = New-Object -TypeName System.Collections.ArrayList

                for ($i = 0; $i -lt $final.Count; $i++) {
                    if ($i -ge [int] $parent.Index -and $i -le [int] $parent.End) { continue }

                    [void] $keep.Add($final[$i])
                }

                $final = [string[]] @(Remove-HDTBlankRun -Line ([string[]] @($keep)) -At ([int] $parent.Index))
            }
        }

        return [string[]] $final
    }

    if (@($Text).Count -eq 0) {
        # Nothing to remove and nothing to write.
        return [string[]] @($Line)
    }

    # =====================================================================
    # THE KEY IS NOT THERE: build it, and whatever has to hold it.
    # =====================================================================

    $parentBlock = $null
    $have = 0

    for ($n = $Path.Count - 1; $n -ge 1; $n--) {
        $candidate = Get-HDTWorkspaceKey -Line $Line -Path ([string[]] @($Path[0..($n - 1)]))

        if ($null -ne $candidate) {
            $parentBlock = $candidate
            $have = $n
            break
        }
    }

    # Wrapped from the inside out, so the innermost key keeps the shape the
    # caller composed and every container above it is two columns shallower.
    $block = [string[]] @($Text)

    for ($k = $Path.Count - 2; $k -ge $have; $k--) {
        $wrapped = New-Object -TypeName System.Collections.ArrayList
        [void] $wrapped.Add(('{0}:' -f $Path[$k]))

        foreach ($current in $block) {
            if ([string]::IsNullOrWhiteSpace($current)) {
                [void] $wrapped.Add($current)
                continue
            }

            [void] $wrapped.Add('  ' + $current)
        }

        $block = [string[]] @($wrapped)
    }

    # -- where it lands --------------------------------------------------

    $targetIndent = 0
    $insertAfter = -1
    $containerName = ''

    if ($null -ne $parentBlock) {
        $containerName = @($Path[0..($have - 1)]) -join '.'

        $targetIndent = [int] $parentBlock.ChildIndent
        if ($targetIndent -lt 0) { $targetIndent = [int] $parentBlock.Indent + 2 }

        $insertAfter = [int] $parentBlock.Index
    }

    $sibling = @(Get-HDTWorkspaceChildKey -Line $Line -Block $parentBlock)

    if ($order.ContainsKey($containerName)) {
        $rank = [array]::IndexOf($order[$containerName], [string] $Path[$have])

        foreach ($current in $sibling) {
            $at = [array]::IndexOf($order[$containerName], [string] $current.Name)

            # An unknown key keeps whatever place it has in the file rather than
            # being jumped over; the document validator is what refuses it.
            if ($at -lt 0) { $at = @($order[$containerName]).Count }

            if ($at -lt $rank -and [int] $current.End -gt $insertAfter) {
                $insertAfter = [int] $current.End
            }
        }
    }

    # A top-level key with nothing ranking before it still goes after the
    # document's own keys rather than above its header comment.
    if ($null -eq $parentBlock -and $insertAfter -lt 0 -and @($sibling).Count -gt 0) {
        $insertAfter = [int] $sibling[@($sibling).Count - 1].End
    }

    $written = [string[]] @(Set-HDTWorkspaceIndent -Block $block -Indent $targetIndent)

    # A new block at the top level is a section of its own, and reads as one.
    $spaced = ($null -eq $parentBlock -and $insertAfter -ge 0 -and
        -not [string]::IsNullOrWhiteSpace($Line[$insertAfter]))

    $result = New-Object -TypeName System.Collections.ArrayList

    if ($insertAfter -lt 0) {
        foreach ($current in $written) { [void] $result.Add($current) }
    }

    for ($i = 0; $i -lt $Line.Count; $i++) {
        [void] $result.Add($Line[$i])

        if ($i -ne $insertAfter) { continue }

        if ($spaced) { [void] $result.Add('') }

        foreach ($current in $written) { [void] $result.Add($current) }
    }

    return [string[]] @($result)
}
