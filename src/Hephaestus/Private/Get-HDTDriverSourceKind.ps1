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

    $none = [pscustomobject] @{ Kind = 'Empty'; Archive = '' }

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
            return [pscustomobject] @{
                Kind    = (& { if ($extension -eq '.cab') { 'Cab' } elseif ($extension -eq '.zip') { 'Zip' } else { 'Exe' } })
                Archive = $Path
            }
        }

        return $none
    }

    # A TREE WINS OVER AN ARCHIVE BESIDE IT.
    if ((Measure-HDTDriverInf -Path $Path -FileSystem $FileSystem) -gt 0) {
        return [pscustomobject] @{ Kind = 'Folder'; Archive = '' }
    }

    $found = @($FileSystem.GetChildItem($Path) | Where-Object {
            $archiveExtension -contains ([System.IO.Path]::GetExtension([string] $_)).ToLowerInvariant()
        })

    if (@($found).Count -eq 1) {
        return Get-HDTDriverSourceKind -Path ([string] @($found)[0]) -FileSystem $FileSystem
    }

    return $none
}
