function Rename-HDTDriverFolder {
    <#
        .SYNOPSIS
            Renames a driver folder, and everything that names it.

        .DESCRIPTION
            THE CONSOLE COULD MAKE A DRIVER FOLDER AND DELETE ONE, AND NOT
            RENAME ONE. MDT's Workbench renames a driver folder from the tree,
            and an administrator who has to leave the console for Explorer to
            fix a typo is an administrator who will do it in Explorer - which is
            the case this command exists to make safe.

            A RENAME IN EXPLORER IS NOT THE SAME OPERATION. A driver folder is
            named by three other things, and moving the directory alone breaks
            all of them silently:

              Control\selection-profiles.yaml   include paths, which decide what
                                                a boot image injects. A profile
                                                pointing at the old name injects
                                                NOTHING and says nothing.
              Control\driver-state.yaml         the drivers somebody turned OFF,
                                                recorded by path. Renamed around,
                                                a disabled driver quietly comes
                                                back on the next build.
              workspace.yaml bootImage.drivers  the folder or profile the boot
                                                image builds from.

            None of those fails loudly. They fail as a boot image that cannot
            see a disk, found on a bench.

            THE DOCUMENTS ARE SPLICED, NEVER RE-SERIALISED. An administrator's
            comments and ordering are the reason those files are YAML rather
            than JSON, and a round trip through ConvertFrom/ConvertTo-Yaml
            destroys both.

            IT RENAMES A LEAF, NOT A PATH. -NewName is a folder name, so this
            cannot be used to move a folder somewhere else in the tree - that is
            a different operation with different consequences and it should look
            different at the call site.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            The folder to rename, relative to the driver store - the same shape
            Remove-HDTDriverFolder takes, e.g. 'Win11\Dell Inc\Latitude 5420'.

        .PARAMETER NewName
            The new folder name. A leaf: no separators, no '..'.

        .PARAMETER FileSystem
            The IFileSystem to work through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, NewPath,
            FullPath, Renamed, ProfileUpdated and StateUpdated.

        .EXAMPLE
            Rename-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'Win11\Dell Inc\Latitude 5420' -NewName 'Latitude 5430'

            Renames the folder and rewrites every selection profile and disabled
            driver that named it.

        .EXAMPLE
            Rename-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell' -NewName 'Dell WinPE' -WhatIf

            What it would touch, without touching it.

        .LINK
            New-HDTDriverFolder

        .LINK
            Remove-HDTDriverFolder
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $NewName,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $relative = $Path.Trim().TrimStart('\', '/').TrimEnd('\', '/')
    $leaf = $NewName.Trim()

    # -- the new name has to be a name ----------------------------------------
    #
    # A separator here would move the folder rather than rename it, and '..'
    # would move it OUT of the store. Both are refused by shape rather than by
    # resolving and hoping.
    if ($leaf -match '[\\/]' -or $leaf -eq '.' -or $leaf -eq '..') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $NewName `
                    -Category InvalidArgument `
                    -Message ("'{0}' is a path, not a folder name. Rename-HDTDriverFolder renames a folder where it is; moving one somewhere else is a different operation." -f $NewName)))
    }

    if ($leaf -match '[:*?"<>|]') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $NewName `
                    -Category InvalidArgument `
                    -Message ("'{0}' contains a character a folder name cannot hold." -f $NewName)))
    }

    # -- the same guards Remove-HDTDriverFolder uses --------------------------

    $failure = Get-HDTSelectionProfilePathFailure `
        -Include ([System.IO.Path]::Combine('Drivers', $relative)) `
        -ContentFolder @('Drivers')

    if (-not [string]::IsNullOrEmpty($failure)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("'{0}' is not a driver folder that can be renamed: {1}" -f $Path, $failure)))
    }

    if ([string]::IsNullOrWhiteSpace($relative)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message 'that is the driver store itself, not a folder in it.'))
    }

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers
    $full = [System.IO.Path]::Combine($store, $relative)

    $fullNormal = [System.IO.Path]::GetFullPath($full).TrimEnd('\')
    $storeNormal = [System.IO.Path]::GetFullPath($store).TrimEnd('\')

    if (-not $fullNormal.StartsWith($storeNormal + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $full `
                    -Message ("'{0}' does not resolve to a folder inside '{1}'." -f $full, $store)))
    }

    if (-not $FileSystem.TestPath($fullNormal)) {
        return [pscustomobject] @{
            Path = $relative; NewPath = ''; FullPath = $fullNormal
            Renamed = $false; ProfileUpdated = $false; StateUpdated = $false
        }
    }

    # -- where it is going ----------------------------------------------------

    $parent = [string] (Split-Path -Path $relative -Parent)

    $newRelative = $leaf
    if (-not [string]::IsNullOrEmpty($parent)) {
        $newRelative = [System.IO.Path]::Combine($parent, $leaf)
    }

    $newFull = [System.IO.Path]::Combine($store, $newRelative)

    # SAME NAME, NOTHING TO DO - and not an error. Somebody pressing Rename and
    # then OK without typing has not made a mistake.
    if ($newRelative -eq $relative) {
        return [pscustomobject] @{
            Path = $relative; NewPath = $relative; FullPath = $fullNormal
            Renamed = $false; ProfileUpdated = $false; StateUpdated = $false
        }
    }

    # A CASE-ONLY RENAME IS STILL A RENAME on Windows - 'dell inc' to 'Dell Inc'
    # - and TestPath would call the destination occupied by the source itself.
    if ($newRelative -ne $relative -and
        -not $newRelative.Equals($relative, [System.StringComparison]::OrdinalIgnoreCase) -and
        $FileSystem.TestPath($newFull)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $newFull `
                    -Category ResourceExists `
                    -Message ("'{0}' already exists. Renaming onto it would merge two driver folders into one." -f $newRelative)))
    }

    $count = Measure-HDTDriverInf -Path $fullNormal -FileSystem $FileSystem

    if (-not $PSCmdlet.ShouldProcess($fullNormal, ("Rename to '{0}', and rewrite every profile and disabled driver naming it ({1} driver(s))" -f $leaf, $count))) {
        return [pscustomobject] @{
            Path = $relative; NewPath = $newRelative; FullPath = $fullNormal
            Renamed = $false; ProfileUpdated = $false; StateUpdated = $false
        }
    }

    $FileSystem.MoveItem($fullNormal, $newFull)

    # -- and everything that named it -----------------------------------------
    #
    # AFTER the move, so a failed move leaves the documents describing what is
    # actually on the share rather than where it was going.

    $oldInclude = [System.IO.Path]::Combine('Drivers', $relative)
    $newInclude = [System.IO.Path]::Combine('Drivers', $newRelative)

    $profileUpdated = Update-HDTDriverFolderReference -Root $Root `
        -Kind Control -Document 'selection-profiles.yaml' `
        -Old $oldInclude -New $newInclude -FileSystem $FileSystem

    # driver-state.yaml counts from INSIDE the store, so its paths carry no
    # 'Drivers\' prefix - the one difference between the two documents, and the
    # reason this is two calls rather than a loop.
    $stateUpdated = Update-HDTDriverFolderReference -Root $Root `
        -Kind Control -Document 'driver-state.yaml' `
        -Old $relative -New $newRelative -FileSystem $FileSystem

    return [pscustomobject] @{
        Path           = $relative
        NewPath        = $newRelative
        FullPath       = [System.IO.Path]::GetFullPath($newFull).TrimEnd('\')
        Renamed        = $true
        ProfileUpdated = $profileUpdated
        StateUpdated   = $stateUpdated
    }
}
