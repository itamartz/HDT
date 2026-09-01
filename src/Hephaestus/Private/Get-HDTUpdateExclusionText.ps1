function Get-HDTUpdateExclusionText {
    <#
        .SYNOPSIS
            The DISM configuration file that extracts one entry from a .msu and
            leaves the other four point seven gigabytes where they are.

        .DESCRIPTION
            DISM HAS NO SINGLE-FILE EXTRACT, and that is the whole problem this
            solves. Reading a package's metadata means getting
            onepackage.AggregatedMetadata.cab out of the container, and the only
            supported way into a WIM is /Apply-Image, which unpacks everything -
            4.76 GB for the Windows 11 cumulative update, on an import that wants
            22 KB.

            SO THE EXCLUSION LIST IS INVERTED. wimscript.ini's [ExclusionList]
            names what to leave out, and there is no "keep only this"; but the
            entries are enumerable with /List-Image, so naming every entry EXCEPT
            the one wanted is exactly equivalent and is what this builds. Measured
            on 2026-09-01: 0.057 s to take the metadata out of the 1.88 GB Server
            package, 0.123 s out of the 4.76 GB Windows 11 one.

            THE ROOT ENTRY IS DROPPED. /List-Image prints a bare '\' for the
            container root, and excluding the root excludes everything - including
            the file being kept - so the apply writes an empty folder and the
            import reports a package with no metadata. That is not hypothetical:
            it is the shape of the bug this line prevents.

            A KEPT NAME IS MATCHED ON ITS LEAF, case-insensitively, because
            /List-Image prints rooted paths ('\onepackage.AggregatedMetadata.cab')
            and a caller should not have to know that.

        .PARAMETER Entry
            The entries inside the container, as ConvertFrom-HDTUpdateFileList
            read them off /List-Image.

        .PARAMETER Keep
            The leaf names to keep. Everything else is excluded.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the whole file, ready to write.

        .EXAMPLE
            Get-HDTUpdateExclusionText -Entry $entry -Keep 'onepackage.AggregatedMetadata.cab'

            The configuration that leaves a multi-gigabyte package unpacked and
            takes its metadata out in a tenth of a second.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [string[]] $Entry,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Keep
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $line = New-Object -TypeName System.Collections.ArrayList
    [void] $line.Add('[ExclusionList]')

    foreach ($current in @($Entry)) {

        # THE ROOT EXCLUDES EVERYTHING, INCLUDING WHAT IS BEING KEPT. /List-Image
        # prints '\' for the container itself, and passing that through produces
        # a configuration that unpacks nothing at all.
        if ([string]::IsNullOrWhiteSpace($current) -or ($current.Trim() -eq '\')) {
            continue
        }

        $leaf = [System.IO.Path]::GetFileName($current.TrimEnd('\'))

        if (@($Keep) -contains $leaf) {
            continue
        }

        [void] $line.Add($current)
    }

    return (@($line) -join [System.Environment]::NewLine)
}
