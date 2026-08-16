function Add-HDTWorkspaceItem {
    <#
        .SYNOPSIS
            Inserts one entry into a block sequence that already exists, at the
            column that sequence is written at.

        .DESCRIPTION
            WHY AN ADD IS NOT A REWRITE OF THE LIST. Composing the whole
            optionalComponents or extraContent key from the parsed document and
            writing it back would be far simpler, and it would silently delete
            every trailing comment an administrator had put beside an entry -
            `- WinPE-SecureStartup    # BitLocker` is in the sample workspace this
            repository ships. So an add touches exactly the lines it adds.

            THE COLUMN COMES FROM THE ENTRIES ALREADY THERE, never from a
            convention. YAML lets a block sequence sit at its key's own column or
            one level in, and both spellings appear in real documents - the second
            in every hand-written sample here, the first in every file
            ConvertTo-HDTYaml writes.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Block
            The sequence's key, from Get-HDTWorkspaceKey.

        .PARAMETER Text
            The entry's lines, written at column zero with the dash first.

        .PARAMETER First
            Insert above the existing entries rather than below them. For a list
            whose order is what it does - startCommand runs top to bottom.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Add-HDTWorkspaceItem -Line $line -Block $block -Text @('- source: Tools\VNC', '  destination: \HDT\Tools\VNC')
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
        [ValidateNotNull()]
        [object] $Block,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,

        [Parameter()]
        [switch] $First
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $item = @(Get-HDTWorkspaceItem -Line $Line -Block $Block)

    $indent = [int] $Block.ChildIndent
    if ($indent -lt 0) { $indent = [int] $Block.Indent + 2 }

    $written = [string[]] @(Set-HDTWorkspaceIndent -Block $Text -Indent $indent)

    $at = [int] $Block.Index
    $before = $true

    if (@($item).Count -gt 0) {
        if ($First) {
            $at = [int] $item[0].Index
        } else {
            $at = [int] $item[@($item).Count - 1].End
            $before = $false
        }
    } else {
        # An empty sequence key: the entry goes directly under it.
        $before = $false
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($before -and $i -eq $at) {
            foreach ($current in $written) { [void] $result.Add($current) }
        }

        [void] $result.Add($Line[$i])

        if (-not $before -and $i -eq $at) {
            foreach ($current in $written) { [void] $result.Add($current) }
        }
    }

    return [string[]] @($result)
}
