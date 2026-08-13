function Copy-HDTContentTree {
    <#
        .SYNOPSIS
            Copies a directory tree through the injected filesystem service.

        .DESCRIPTION
            What -Copy on Import-HDTOperatingSystem does: bring a media tree into
            the workspace. It goes through IFileSystem and nothing else, so
            importing 4 GB of media is provable under Pester with nothing on disk
            (PROJECT constraint 4).

            IT REFUSES TO COPY A TREE INTO ITSELF. A destination underneath the
            source is the loop that fills a disk: every pass copies what the
            previous pass wrote. The check compares normalised paths and requires
            a separator, so C:\media\Win11-copy is correctly NOT inside
            C:\media\Win11 - a bare StartsWith would say it was.

            A DIRECTORY IS TOLD FROM A FILE BY GetLength. IFileSystem has nine
            methods and none of them is TestDirectory; TestPath answers for both.
            Both the real adapter and the fake throw
            System.IO.FileNotFoundException for a path that is not a file, and
            that error parity is a contract assertion (tests/helpers/README.md
            section 5), so the classification behaves identically against either
            implementation. Widening a service interface 04-01 fixed, in order to
            copy a directory, would have been the larger change.

        .PARAMETER Source
            The directory to copy. Must exist.

        .PARAMETER Destination
            Where to copy it. Created if absent, along with every subdirectory.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .OUTPUTS
            System.Int32 - the number of files copied.

        .EXAMPLE
            Copy-HDTContentTree -Source 'C:\media\Win11' -Destination $osFolder -FileSystem $fs
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller owns the ShouldProcess decision; this runs only after it was made.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Message 'the source tree does not exist, so there is nothing to copy into the workspace.' `
                    -Category ObjectNotFound))
    }

    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')

    if ($destinationFull -eq $sourceFull -or
        $destinationFull.StartsWith(($sourceFull + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Message ("the destination '{0}' is inside the source tree, so copying it would copy what the copy is writing. Choose a destination outside the source." -f $Destination)))
    }

    $FileSystem.CreateDirectory($Destination)

    $copied = 0

    foreach ($child in @($FileSystem.GetChildItem($Source))) {
        $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
        $target = [System.IO.Path]::Combine($Destination, $leaf)

        $isFile = $true
        try {
            [void] $FileSystem.GetLength($child)
        } catch {
            # Not a file. Both implementations throw FileNotFoundException here,
            # and the child came from GetChildItem so it certainly exists.
            $isFile = $false
        }

        if ($isFile) {
            $FileSystem.CopyItem($child, $target)
            $copied++
            continue
        }

        $copied += Copy-HDTContentTree -Source $child -Destination $target -FileSystem $FileSystem
    }

    return $copied
}
