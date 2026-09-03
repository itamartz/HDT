function Test-HDTFileSystemFile {
    <#
        .SYNOPSIS
            Whether a path an IFileSystem can see is a file rather than a
            directory.

        .DESCRIPTION
            IFileSystem HAS NINE METHODS AND NONE OF THEM IS TestDirectory;
            TestPath answers for both. A DIRECTORY IS TOLD FROM A FILE BY
            GetLength: both the real adapter and the fake throw
            System.IO.FileNotFoundException for a path that is not a file, and
            that error parity is a contract assertion
            (tests/helpers/README.md section 5) - so this classification behaves
            identically against either implementation.

            Widening the service interface in order to answer it would have been
            the larger change, and Copy-HDTContentTree already records that
            decision. This is that function's inline try/catch, lifted out
            because Update-HDTMediaContent needs the same answer for the children
            of Control\ - and two copies of a try/catch that READS like a bug
            would not survive the first person to tidy one of them.

            IT ASSUMES THE PATH EXISTS, because both callers hand it something
            GetChildItem just returned. A path that is not there answers false,
            which is the same answer a directory gives and is why the callers
            check TestPath first when it matters.

        .PARAMETER Path
            The path to classify.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production, the fake in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            if (Test-HDTFileSystemFile -Path $child -FileSystem $fs) { $fs.CopyItem($child, $target) }

        .LINK
            Copy-HDTContentTree
    #>
    [CmdletBinding()]
    [OutputType([bool])]
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

    try {
        [void] $FileSystem.GetLength($Path)
    } catch {
        return $false
    }

    return $true
}
