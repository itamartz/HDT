function Expand-HDTSelectionProfile {
    <#
        .SYNOPSIS
            The folders a selection profile actually names, resolved against a
            share.

        .DESCRIPTION
            The half of a selection profile that a build consumes. Get- answers
            what an administrator authored; this answers what
            Update-HDTBootImage will hand Add-WindowsDriver, and what media will
            copy.

            IT DOES NOT RECURSE, AND THAT IS THE CONTRACT. An include means "this
            folder and everything under it", and the recursion belongs to the
            consumer - Add-WindowsDriver -Recurse for a boot image,
            Copy-HDTContentTree for media. Walking the tree here would mean
            enumerating a driver store of tens of thousands of files to answer a
            question whose answer is two folder names.

            A MISSING FOLDER COMES BACK AS Present = $false RATHER THAN AS
            NOTHING. Dropping it silently is how a boot image gets built with one
            vendor's drivers in it after somebody renamed the other vendor's
            folder, and nobody finds out until an HP laptop cannot see its disk on
            a bench. The console shows the row struck through; the build warns.

            THE DECLARED ORDER IS KEPT, not sorted. Driver injection order is the
            author's, and a profile that lists a storage pack before a network
            pack meant that.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Id
            The profile to expand.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per included folder, in
            declared order, with Path (share-relative, as authored), FullPath and
            Present.

            Nothing at all for a profile that includes nothing, which is what the
            Nothing built-in is.

        .EXAMPLE
            Expand-HDTSelectionProfile -Root 'C:\HDTLab\Share' -Id 'boot-critical'

            The Dell and HP WinPE packs, as two folders on the share.

        .EXAMPLE
            Expand-HDTSelectionProfile -Root 'C:\HDTLab\Share' -Id 'boot-critical' |
                Where-Object { -not $_.Present }

            What the build warns about before it spends two and a half minutes
            producing an image without them.

        .LINK
            Get-HDTSelectionProfile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $selection = Get-HDTSelectionProfile -Root $Root -Id $Id -FileSystem $FileSystem

    $folder = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($selection.Include)) {
        $relative = [string] $current

        # [IO.Path]::Combine rather than Join-Path, for Get-HDTWorkspacePath's
        # reason: a share root is routinely a UNC path or a volume that is not
        # mounted in the session doing the authoring, and Join-Path throws
        # "Cannot find drive" for one. Building a path must not require it to
        # exist.
        $full = [System.IO.Path]::Combine($Root, $relative.TrimStart('\', '/'))

        [void] $folder.Add([pscustomobject] @{
                Path     = $relative
                FullPath = $full
                Present  = [bool] $FileSystem.TestPath($full)
            })
    }

    return [pscustomobject[]] @($folder)
}
