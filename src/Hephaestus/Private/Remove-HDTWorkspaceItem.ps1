function Remove-HDTWorkspaceItem {
    <#
        .SYNOPSIS
            Takes one entry out of a block sequence, and takes the key - and the
            block above it - with the last one.

        .DESCRIPTION
            AN EMPTY KEY IS NOT AN EMPTY LIST. `extraContent:` with nothing under
            it parses as a null, and the engine refuses a workspace whose
            extraContent is not a list - so a removal that left the key behind
            would produce a document that cannot be loaded, from a command whose
            whole job was to take one entry away. The key goes, and if that leaves
            bootImage: holding nothing, so does bootImage:.

            -EmptyText IS FOR THE ONE LIST WHERE ABSENT AND EMPTY MEAN DIFFERENT
            THINGS. An absent optionalComponents means "the administrator did not
            say", and takes the engine's three defaults; an explicit empty list
            means "the required six and nothing else". Removing the last declared
            component therefore has to write `optionalComponents: []` rather than
            delete the key, or the three defaults the administrator has just
            finished deleting come straight back.

            THE ENTRY IS NAMED BY POSITION, because position is how the caller
            knows which entry it means: the engine's own reader yields the entries
            in document order, so the Nth parsed entry is the Nth line range.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Path
            The sequence key's path, outermost first.

        .PARAMETER Position
            The zero-based index of the entry to remove.

        .PARAMETER EmptyText
            What the key becomes when that was its last entry, written at column
            zero. Omitted, the key is removed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Remove-HDTWorkspaceItem -Line $line -Path @('bootImage', 'extraContent') -Position 1
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
        [int] $Position,

        [Parameter()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $EmptyText = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $block = Get-HDTWorkspaceKey -Line $Line -Path $Path
    if ($null -eq $block) { return [string[]] @($Line) }

    $item = @(Get-HDTWorkspaceItem -Line $Line -Block $block)
    if ($Position -lt 0 -or $Position -ge @($item).Count) { return [string[]] @($Line) }

    # The last one takes the key with it, whatever the key then has to become.
    if (@($item).Count -eq 1) {
        return [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path $Path -Text $EmptyText)
    }

    $keep = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($i -ge [int] $item[$Position].Index -and $i -le [int] $item[$Position].End) { continue }

        [void] $keep.Add($Line[$i])
    }

    return [string[]] @(Remove-HDTBlankRun -Line ([string[]] @($keep)) -At ([int] $item[$Position].Index))
}
