function Get-HDTUpdateMetadataCommand {
    <#
        .SYNOPSIS
            The program and arguments that read a .msu package's own metadata.

        .DESCRIPTION
            WHAT TO RUN, DECIDED WHERE PESTER CAN SEE IT. Running it is the
            process adapter's job and is branch-free because it is not unit
            tested; choosing the switches is a decision, and getting one wrong
            means an import that reads nothing and files an update under whatever
            the administrator happened to pick.

            THE MECHANISM, AND WHY IT IS NOT MDT'S. MDT's ZTIPatches.wsf reads a
            package by running `expand <file>.cab -F:update.mum` and parsing the
            assemblyIdentity out of update.mum. That cannot work here, because a
            modern package is not a cabinet at all. Both packages built against
            begin with the bytes 4D 53 57 49 4D - MSWIM - and expand.exe reports
            "Can't open input file" on them. DISM's own /Get-PackageInfo is no
            help either: on these packages it answers
            "Package Identity : OnePackage~~~~0.0.0.0" with every other field
            blank.

            SO THE CONTAINER IS READ AS WHAT IT IS. The .msu is a WIM holding
            onepackage.AggregatedMetadata.cab, which holds one CompDB XML per
            package inside. Three stages:

              List     dism /List-Image names every entry in the container.
              Extract  dism /Apply-Image with a ConfigFile EXCLUSION LIST that
                       names every entry EXCEPT the metadata cab.
              Expand   expand.exe -F:* pulls the CompDB cabs out of it, and
                       again to pull the XML out of each of those.

            THE EXCLUSION LIST IS WHAT MAKES THIS CHEAP, and the number is the
            reason the design does not extract packages at import. DISM has no
            single-file extract, so a naive read would unpack the whole container
            - 4.76 GB for the Windows 11 cumulative update. Excluding everything
            but the 22 KB metadata cab was measured on 2026-09-01 at 0.057 s for
            the 1.88 GB Server package and 0.123 s for the 4.76 GB Windows 11
            one. An import pays a tenth of a second, not five gigabytes.

            /English IS NOT DECORATION. Nothing downstream parses DISM's prose -
            the outcome of an apply is decided by re-reading the image's package
            list, not by matching a sentence - but the FILE LIST from /List-Image
            is parsed, and a localised DISM would return its header rows in
            another language while the paths stayed the same. Pinning the
            language keeps the rows this reads stable on any machine.

            NOTHING IS QUOTED HERE. Quoting belongs to whoever builds the command
            line, and doubling it produces arguments with literal quotes in them.

        .PARAMETER Stage
            Which command to build.

        .PARAMETER PackagePath
            The .msu, for List and Extract.

        .PARAMETER Destination
            Where Extract writes, and where Expand expands into.

        .PARAMETER ConfigPath
            The exclusion list Extract passes as /ConfigFile.

        .PARAMETER CabPath
            The cabinet Expand opens.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with FilePath and
            Argument.

        .EXAMPLE
            Get-HDTUpdateMetadataCommand -Stage List -PackagePath 'D:\updates\kb5094126.msu'

            The command that names every entry inside the package.

        .EXAMPLE
            Get-HDTUpdateMetadataCommand -Stage Extract -PackagePath 'D:\u.msu' -Destination 'C:\t' -ConfigPath 'C:\t\exclude.ini'

            The command that pulls out the metadata cab and nothing else.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('List', 'Extract', 'Expand')]
        [string] $Stage,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $PackagePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ConfigPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $CabPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A HASHTABLE LOOKUP, NOT A SWITCH, so the three stages are one table a
    # reader can see at once rather than three arms to hold in their head.
    $dism = "$env:SystemRoot\System32\dism.exe"

    $plan = @{
        List    = [pscustomobject] @{
            FilePath = $dism
            Argument = @('/English', '/List-Image', ('/ImageFile:{0}' -f $PackagePath), '/Index:1')
        }
        Extract = [pscustomobject] @{
            FilePath = $dism
            Argument = @('/English', '/Apply-Image', ('/ImageFile:{0}' -f $PackagePath), '/Index:1',
                ('/ApplyDir:{0}' -f $Destination), ('/ConfigFile:{0}' -f $ConfigPath))
        }
        # -F:* IS THE PART PEOPLE MISS, and Get-HDTDriverExpandCommand says the
        # same thing about the same tool: without it expand copies the cabinet's
        # first file and stops, which here would take one CompDB and leave the
        # other - so a package's bundled servicing stack update would vanish.
        Expand  = [pscustomobject] @{
            FilePath = "$env:SystemRoot\System32\expand.exe"
            Argument = @($CabPath, '-F:*', $Destination)
        }
    }

    return $plan[$Stage]
}
