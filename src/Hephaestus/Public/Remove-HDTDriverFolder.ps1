function Remove-HDTDriverFolder {
    <#
        .SYNOPSIS
            Removes a folder from the share's driver store, and everything in it.

        .DESCRIPTION
            Deployment Workbench's Delete on an Out-of-Box Drivers folder. The
            commonest reason to want it is the commonest mistake: a folder
            imported from the wrong source - a vendor's .cab rather than the tree
            inside it - which has to come off the share before a profile ticks it.

            THIS DELETES A REAL DIRECTORY, RECURSIVELY, so it is the most
            carefully bounded command in this module. Four refusals stand between
            a caller and Remove-Item, and they are checked in this order:

              1. the path must be a legal driver folder - the same traversal
                 rules a selection profile's include obeys, so '..' and a rooted
                 path are gone before anything else runs;
              2. it must not be the driver store ITSELF. 'Delete Drivers\' is a
                 keystroke away from 'delete this vendor folder' and would take
                 every pack on the share with it;
              3. the resolved path must still sit UNDER <Root>\Drivers after
                 normalisation, checked against the normalised root - belt and
                 braces over rule 1, because a path that survives a textual check
                 and then resolves somewhere else is exactly the bug this kind of
                 command is famous for;
              4. it must exist.

            IT DELETES BY EXPLICIT -LiteralPath, and the path it passes is one it
            built itself from -Root and -Path. Nothing here enumerates a parent
            to decide what to remove.

            ConfirmImpact IS High. It destroys content somebody imported, and
            there is no undo but the vendor's download.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            The folder to remove, relative to Drivers\.

        .PARAMETER FileSystem
            The IFileSystem to delete through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FullPath and
            Removed.

        .EXAMPLE
            Remove-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell\WinPE11.0-Drivers-A10-XCXDW-2026-05-29'

            The folder left behind by an import that copied a .cab.

        .EXAMPLE
            Remove-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell' -WhatIf

            What it would remove, without removing it.

        .LINK
            New-HDTDriverFolder

        .LINK
            Import-HDTDriver
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $relative = $Path.Trim().TrimStart('\', '/').TrimEnd('\', '/')

    # -- 1. a legal driver folder ---------------------------------------------

    $failure = Get-HDTSelectionProfilePathFailure `
        -Include ([System.IO.Path]::Combine('Drivers', $relative)) `
        -ContentFolder @('Drivers')

    if (-not [string]::IsNullOrEmpty($failure)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("'{0}' is not a driver folder that can be removed: {1}" -f $Path, $failure)))
    }

    # -- 2. not the store itself ----------------------------------------------

    if ([string]::IsNullOrWhiteSpace($relative)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message 'that is the driver store itself, not a folder in it. Removing it would take every driver on this share.'))
    }

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers
    $full = [System.IO.Path]::Combine($store, $relative)

    # -- 3. still under the store once normalised -----------------------------
    #
    # A textual check and a resolved path can disagree, and this kind of command
    # is exactly where that costs somebody their share.
    $fullNormal = [System.IO.Path]::GetFullPath($full).TrimEnd('\')
    $storeNormal = [System.IO.Path]::GetFullPath($store).TrimEnd('\')

    if (-not $fullNormal.StartsWith($storeNormal + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $full `
                    -Message ("'{0}' does not resolve to a folder inside '{1}', so it will not be removed." -f $full, $store)))
    }

    # -- 4. it has to be there ------------------------------------------------

    if (-not $FileSystem.TestPath($fullNormal)) {
        return [pscustomobject] @{ Path = $relative; FullPath = $fullNormal; Removed = $false }
    }

    $count = Measure-HDTDriverInf -Path $fullNormal -FileSystem $FileSystem

    if (-not $PSCmdlet.ShouldProcess($fullNormal, ("Remove this driver folder and the {0} driver(s) in it" -f $count))) {
        return [pscustomobject] @{ Path = $relative; FullPath = $fullNormal; Removed = $false }
    }

    $FileSystem.RemoveItem($fullNormal, $true)

    return [pscustomobject] @{ Path = $relative; FullPath = $fullNormal; Removed = $true }
}
