function Get-HDTDriverSourceKind {
    <#
        .SYNOPSIS
            What an import source actually is: a driver tree, or an archive that
            has to be expanded first.

        .DESCRIPTION
            VENDORS DO NOT SHIP .inf TREES. Dell's WinPE packs arrive as a .cab;
            HP's arrive as a self-extracting SoftPaq .exe. Pointing an import at
            the download is not a mistake an administrator makes once - it is the
            ordinary case, and the first version of this refused it as "no .inf
            files", which is true and useless.

            IT ANSWERS FOUR THINGS:

              Folder  the path holds .inf files somewhere in it - import copies
              Cab     a .cab, expanded with expand.exe
              Exe     a self-extracting installer, expanded by running it
              Empty   none of the above, which is a genuine mistake

            A FOLDER HOLDING ONE ARCHIVE COUNTS AS THAT ARCHIVE. Somebody who
            downloaded a SoftPaq into its own folder and picked the folder meant
            the SoftPaq, and a browse dialog makes picking the folder the easier
            gesture.

            A FOLDER WITH .inf FILES IS A FOLDER EVEN IF AN ARCHIVE SITS BESIDE
            THEM. An expanded pack often keeps its original .cab; the tree is
            what matters, and expanding again would nest a copy inside itself.

            IT IS PURE - it asks the file system what is there and decides. What
            to RUN is Get-HDTDriverExpandCommand's, and the running is the
            process adapter's.

        .PARAMETER Path
            The folder or file the administrator chose.

        .PARAMETER FileSystem
            The IFileSystem to look with.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Kind and Archive.
            Archive is the file to expand, or an empty string.

        .EXAMPLE
            Get-HDTDriverSourceKind -Path 'D:\packs\WinPE11.0-Drivers-A10-XCXDW.cab' -FileSystem $fs

        .EXAMPLE
            (Get-HDTDriverSourceKind -Path 'D:\packs\sp150000.exe' -FileSystem $fs).Kind

            'Exe' - an HP SoftPaq.

        .LINK
            Get-HDTDriverExpandCommand
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $none = [pscustomobject] @{ Kind = 'Empty'; Archive = ''; Vendor = '' }

    # WHO MADE IT, WHICH ONLY MATTERS FOR AN .exe. A Dell Update Package and an
    # HP SoftPaq are both a self-extracting .exe and take INCOMPATIBLE switches;
    # a .cab goes through expand.exe whoever built it, so reading a version
    # block for one would be work with nothing behind it.
    #
    # THE FILE'S OWN VERSION BLOCK, NOT ITS NAME. 'sp150000.exe' is a convention
    # somebody can rename; CompanyName 'Dell Inc.' is a field the vendor set.
    $readVendor = {
        param([string] $ExePath)

        try {
            $info = $FileSystem.GetVersionInfo($ExePath)
        } catch {
            return ''
        }

        $said = '{0} {1} {2}' -f [string] $info.CompanyName, [string] $info.ProductName, [string] $info.FileDescription

        if ($said -match '(?i)\bdell\b') { return 'Dell' }
        if ($said -match '(?i)\b(hp|hewlett)\b') { return 'Hp' }

        return ''
    }

    if (-not $FileSystem.TestPath($Path)) { return $none }

    $archiveExtension = @('.cab', '.exe', '.zip')

    # THE PATH ITSELF MAY BE THE ARCHIVE. GetLength throws for a directory in
    # both implementations, which is how a file is told from a folder here -
    # the same test Copy-HDTContentTree uses.
    $isFile = $true
    try { [void] $FileSystem.GetLength($Path) } catch { $isFile = $false }

    if ($isFile) {
        $extension = ([System.IO.Path]::GetExtension($Path)).ToLowerInvariant()

        if ($archiveExtension -contains $extension) {
            $kind = (& { if ($extension -eq '.cab') { 'Cab' } elseif ($extension -eq '.zip') { 'Zip' } else { 'Exe' } })

            $vendor = ''
            if ($kind -eq 'Exe') { $vendor = [string] (& $readVendor $Path) }

            return [pscustomobject] @{
                Kind    = $kind
                Archive = $Path
                Vendor  = $vendor
            }
        }

        return $none
    }

    # A TREE WINS OVER AN ARCHIVE BESIDE IT.
    if ((Measure-HDTDriverInf -Path $Path -FileSystem $FileSystem) -gt 0) {
        return [pscustomobject] @{ Kind = 'Folder'; Archive = ''; Vendor = '' }
    }

    $found = @($FileSystem.GetChildItem($Path) | Where-Object {
            $archiveExtension -contains ([System.IO.Path]::GetExtension([string] $_)).ToLowerInvariant()
        })

    if (@($found).Count -eq 1) {
        return Get-HDTDriverSourceKind -Path ([string] @($found)[0]) -FileSystem $FileSystem
    }

    return $none
}
