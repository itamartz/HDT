function Resolve-HDTBootImageDriverPath {
    <#
        .SYNOPSIS
            The folders a boot image's drivers: key names, whether it names a
            selection profile or a plain folder.

        .DESCRIPTION
            THE KEY CHANGED MEANING AND NO EXISTING SHARE MAY BREAK. bootImage's
            drivers: used to be one folder under Drivers\; it is now a selection
            profile id, which is what lets ONE boot image carry a Dell WinPE pack
            and an HP WinPE pack together. A share written before profiles
            existed still says 'drivers: winpe-nic' and still means the folder.

            So it answers in this order, and the order is the compatibility
            promise:

              1. a selection profile with that id - built in or authored;
              2. failing that, a folder of that name directly under Drivers\,
                 which is exactly what the key used to mean;
              3. failing both, nothing, with a sentence saying so.

            A PROFILE WINS A TIE. An administrator who authored a profile called
            winpe-nic did it deliberately and after the folder already existed;
            the folder is what they were replacing.

            A FOLDER A PROFILE NAMES BUT THE SHARE HAS NOT GOT IS DROPPED AND
            REPORTED. This is the dangerous case: the image builds, one vendor's
            drivers are simply absent, and it is found on a bench with a laptop
            that cannot see its disk. Silence here is what makes that take a day.

            IT WARNS, IT NEVER THROWS - including when the profile document is
            unreadable. The caller is nine steps into a build with a WIM mounted;
            abandoning a mounted image over a document that Get-HDTSelectionProfile
            will refuse again at the next console load is a worse outcome than a
            boot image with no drivers and a warning saying why.

        .PARAMETER WorkspaceRoot
            The deployment share root.

        .PARAMETER Name
            What bootImage.drivers says. Empty means no drivers at all.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with:

              Path     the folders to inject, in the order they were declared
              Kind     None, Profile, Folder or Missing
              Warning  what to tell the administrator, or an empty string

        .EXAMPLE
            Resolve-HDTBootImageDriverPath -WorkspaceRoot 'C:\HDTLab\Share' -Name 'boot-critical'

            Both vendor packs, as two folders.

        .EXAMPLE
            (Resolve-HDTBootImageDriverPath -WorkspaceRoot 'C:\HDTLab\Share' -Name 'winpe-nic').Kind

            'Folder' on a share written before selection profiles existed.

        .LINK
            Expand-HDTSelectionProfile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject] @{ Path = [string[]] @(); Kind = 'None'; Warning = '' }
    }

    # -- 1. a selection profile ----------------------------------------------

    $expanded = $null

    try {
        $expanded = @(Expand-HDTSelectionProfile -Root $WorkspaceRoot -Id $Name -FileSystem $FileSystem)
    } catch {
        # Either there is no profile by that name, or the document is unreadable.
        # Both fall through to the folder, which is what an old share means and
        # what a share with a broken document still has on disk.
        $expanded = $null
    }

    if ($null -ne $expanded) {
        $present = @($expanded | Where-Object { $_.Present })
        $absent = @($expanded | Where-Object { -not $_.Present })

        $warning = ''

        if (@($absent).Count -gt 0) {
            $warning = ("The selection profile '{0}' includes {1} that {2} not on the share, so {3} were not injected: {4}. A boot image missing one vendor's drivers looks like a working build until a machine cannot see its disk." -f
                $Name,
                (& { if (@($absent).Count -eq 1) { 'a folder' } else { ('{0} folders' -f @($absent).Count) } }),
                (& { if (@($absent).Count -eq 1) { 'is' } else { 'are' } }),
                (& { if (@($absent).Count -eq 1) { 'its drivers' } else { 'their drivers' } }),
                (@($absent | ForEach-Object { $_.Path }) -join ', '))
        }

        return [pscustomobject] @{
            Path    = [string[]] @($present | ForEach-Object { [string] $_.FullPath })
            Kind    = 'Profile'
            Warning = $warning
        }
    }

    # -- 2. a folder under Drivers\, which is what the key used to mean -------

    $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Drivers -ChildPath $Name

    if ($FileSystem.TestPath($folder)) {
        return [pscustomobject] @{ Path = [string[]] @($folder); Kind = 'Folder'; Warning = '' }
    }

    # -- 3. neither ------------------------------------------------------------

    return [pscustomobject] @{
        Path    = [string[]] @()
        Kind    = 'Missing'
        Warning = ("'{0}' is declared as the boot image's drivers but it is neither a selection profile on this share nor a folder at '{1}', so no drivers were injected. Create the profile, or import drivers into that folder, or clear the drivers: key." -f $Name, $folder)
    }
}
