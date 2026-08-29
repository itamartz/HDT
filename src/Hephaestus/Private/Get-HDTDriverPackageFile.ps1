function Get-HDTDriverPackageFile {
    <#
        .SYNOPSIS
            Every file in a driver package, with the .inf files marked.

        .DESCRIPTION
            ONE WALK, THREE CALLERS, AND EACH OF THEM NEEDED IT.

              THE COUNT A TECHNICIAN READS. The Latitude 5490 pack on the lab
              share is 126 .inf files, 1302 files and 3.72 GB, and the driver
              step's log reported only the 1302, a total that counts every
              binary, catalogue, library and release note the vendor shipped
              alongside them. The number that maps to DEVICES is the .inf
              count, and it was the one number the log did not have.

              THE DENOMINATOR FOR PROGRESS. The staging copy ran 48 seconds in
              silence on a real deployment because nothing knew how many files
              there were to copy. Walking the tree first is directory metadata -
              cheap against the 48 seconds of actual copying - and it turns
              "still working" into a percentage that is exact rather than
              guessed from elapsed time.

              THE STAGED .inf FILES, FOR THE CROSS-MATCH. After staging, the
              report reads the .inf files from the LOCAL copy on the OS volume
              rather than back across SMB.

            IT TELLS A FILE FROM A DIRECTORY BY ASKING FOR ITS LENGTH, which is
            the only way through an interface that does not say - a directory has
            none and the call throws. Copy-HDTDriverPackage does the same, and
            this is where that walk now lives so the two cannot disagree about
            what is in a package.

            A FOLDER THAT IS NOT THERE IS AN EMPTY WALK, not an error. Whether a
            missing package is a failure is the caller's decision to make and to
            word; a walk of nothing is simply nothing.

            BREADTH FIRST WITH AN ArrayList, not recursion into a variable: '&'
            gives a scriptblock its own scope, so a counter it assigns to is
            lost. This is the same shape Get-HDTDriver's walk uses.

        .PARAMETER Path
            The package root.

        .PARAMETER FileSystem
            An IFileSystem to walk through.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per file, with FullPath,
            RelativePath, Length and IsInf.

        .EXAMPLE
            Get-HDTDriverPackageFile -Path 'W:\Drivers\Win11\Dell Inc.\Latitude 5490' -FileSystem $fileSystem

        .EXAMPLE
            $file = Get-HDTDriverPackageFile -Path $package -FileSystem $fileSystem
            @($file | Where-Object { $_.IsInf }).Count

            How many drivers the pack actually contains, as opposed to how many
            files it ships.
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

    if (-not $FileSystem.TestPath($Path)) { return [pscustomobject[]] @() }

    $found = New-Object -TypeName System.Collections.ArrayList

    $pending = New-Object -TypeName System.Collections.ArrayList
    [void] $pending.Add([pscustomobject] @{ Path = $Path.TrimEnd('\', '/'); Relative = '' })

    while ($pending.Count -gt 0) {
        $current = $pending[0]
        $pending.RemoveAt(0)

        foreach ($child in @($FileSystem.GetChildItem($current.Path))) {
            $leaf = Split-Path -Path $child -Leaf

            $relative = $leaf
            if (-not [string]::IsNullOrEmpty([string] $current.Relative)) {
                $relative = '{0}\{1}' -f $current.Relative, $leaf
            }

            # A DIRECTORY HAS NO LENGTH, which is how this tells them apart
            # through an interface that does not say.
            $length = $null
            try {
                $length = [long] $FileSystem.GetLength($child)
            } catch {
                $length = $null
            }

            if ($null -eq $length) {
                [void] $pending.Add([pscustomobject] @{ Path = [string] $child; Relative = $relative })
                continue
            }

            # CASE-INSENSITIVE, because a vendor ships NET.INF as readily as
            # net.inf and a count that missed the shouted ones would be wrong in
            # the direction that looks fine.
            $isInf = (([System.IO.Path]::GetExtension($leaf)).ToLowerInvariant() -eq '.inf')

            [void] $found.Add([pscustomobject] @{
                    FullPath     = [string] $child
                    RelativePath = [string] $relative
                    Length       = [long] $length
                    IsInf        = [bool] $isInf
                })
        }
    }

    return [pscustomobject[]] @($found)
}
