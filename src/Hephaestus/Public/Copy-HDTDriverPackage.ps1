function Copy-HDTDriverPackage {
    <#
        .SYNOPSIS
            Copies one driver package onto the deployed machine.

        .DESCRIPTION
            Copies a driver folder - the .inf and every file beside and below
            it - to a folder on the applied OS volume, and answers with how many
            files it moved. ApplyDrivers stages each matched package this way
            and the answer file's DriverPaths points Windows at the result, so
            the drivers install at first boot from the machine's own disk.

            IT COPIES INSTEAD OF INJECTING, AND THE DIFFERENCE IS MEASURED. The
            step used to call Add-WindowsDriver once per driver; every call
            opens the offline image, adds one package and commits it. On a
            Latitude 5490 that was 82 drivers in 649 seconds, a median of nine
            seconds each - almost all of it the servicing session rather than
            the driver. A file copy of the same packages is seconds, and it is
            what MDT's ZTIDrivers has always done.

            THE WHOLE FOLDER, BECAUSE THAT IS WHAT A DRIVER IS. An .inf names
            the .sys, .cat and .dll files beside it and in its architecture
            subfolders. Copying the .inf alone stages something Windows cannot
            install and reports success for it.

            IT WALKS RATHER THAN RECURSES, because IFileSystem.CopyItem takes
            one file and GetChildItem does not recurse - the same breadth-first
            walk Copy-HDTLog uses to mirror a log tree, and for the same reason:
            a directory is told apart from a file by asking for its length.

        .PARAMETER Source
            The package folder on the share.

        .PARAMETER Destination
            Where it lands on the OS volume.

        .PARAMETER FileSystem
            An IFileSystem.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Source,
            Destination and FileCount.

        .EXAMPLE
            Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' -Destination 'W:\Drivers\Win11\Dell\Net'

            Source      : Z:\Deploy\Drivers\Win11\Dell\Net
            Destination : W:\Drivers\Win11\Dell\Net
            FileCount   : 4

        .EXAMPLE
            $staged = Copy-HDTDriverPackage -Source 'Z:\Deploy\Drivers\Win11\Dell\Net' `
                -Destination 'W:\Drivers\Win11\Dell\Net' -FileSystem (New-HDTFileSystem)

            if ($staged.FileCount -eq 0) { 'nothing was staged' }

            A package that copied nothing will not install, and the count is
            what says so.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        # NOT MANDATORY - DESIGN 13.2.1. An injected service defaults to the real
        # adapter so a plain Import-Module session can call this; making it
        # mandatory would mean every caller had to build one to copy a folder.
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category ObjectNotFound `
                    -Message 'the driver package is not on the share, so nothing would be staged and the machine would deploy without it.'))
    }

    $root = $Destination.TrimEnd('\', '/')
    $FileSystem.CreateDirectory($root)

    $pending = New-Object -TypeName System.Collections.ArrayList
    [void] $pending.Add([pscustomobject] @{ Path = $Source; Relative = '' })

    $fileCount = 0

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
            # through an interface that does not say. Copy-HDTLog does the same.
            $isFile = $true
            try {
                [void] $FileSystem.GetLength($child)
            } catch {
                $isFile = $false
            }

            if ($isFile) {
                $FileSystem.CopyItem($child, ('{0}\{1}' -f $root, $relative))
                $fileCount++
            } else {
                [void] $pending.Add([pscustomobject] @{ Path = $child; Relative = $relative })
            }
        }
    }

    return [pscustomobject] @{
        Source      = $Source
        Destination = $root
        FileCount   = $fileCount
    }
}
