function ConvertFrom-HDTUpdateFileList {
    <#
        .SYNOPSIS
            The entries inside a .msu, read off what dism /List-Image printed.

        .DESCRIPTION
            dism /List-Image prints a banner, a version line, a blank line and
            then one rooted path per entry, ending with a sentence. Only the
            paths are wanted, and telling them from the prose is the whole job.

            A ROW IS AN ENTRY WHEN IT STARTS WITH A BACKSLASH, which the banner
            and the closing sentence do not - and which holds regardless of the
            language DISM is running in, though Get-HDTUpdateMetadataCommand
            passes /English anyway so the rows this reads are stable.

            THE ROOT ROW IS KEPT HERE AND DROPPED DOWNSTREAM. /List-Image prints
            a bare '\' for the container itself; this returns what DISM said and
            Get-HDTUpdateExclusionText decides what to do with it, because a
            reader that silently dropped rows would make the two hard to compare
            when a package turns out to hold something unexpected.

        .PARAMETER Output
            The lines dism printed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[], one rooted path per entry, in the order DISM listed
            them.

        .EXAMPLE
            ConvertFrom-HDTUpdateFileList -Output $lines

            The seven entries of a Server cumulative update: two deployment cabs,
            the metadata cab, the servicing stack cab, the express .wim and .psf,
            and the WSUS scan cab.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        # AllowEmptyString IS LOAD-BEARING AND WAS MISSING. dism's output begins
        # with a blank line and carries several more; without this the binder
        # refuses the whole array with "Cannot bind argument to parameter
        # 'Output' because it is an empty string", Read-HDTUpdatePackage catches
        # it, and every package silently imports with no metadata at all. Found
        # by running a real import, not by a test.
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]] $Output
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $entry = foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }

        $trimmed = ([string] $line).TrimEnd()

        if (-not $trimmed.StartsWith('\')) { continue }

        $trimmed
    }

    return [string[]] @($entry)
}
