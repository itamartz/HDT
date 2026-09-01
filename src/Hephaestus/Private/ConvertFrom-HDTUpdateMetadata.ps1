function ConvertFrom-HDTUpdateMetadata {
    <#
        .SYNOPSIS
            Reads what a Windows update package says about itself, out of the
            CompDB documents it carries.

        .DESCRIPTION
            THE FILE NAME IS NOT EVIDENCE. The 2026-06 cumulative update for
            Windows 11 24H2 and the 2026-06 cumulative update for Windows Server
            2025 are both delivered as windows11.0-kb50941xx-x64_<sha>.msu. A
            catalog that read the name would file one of them under the wrong
            release and nothing downstream would ever notice, because everything
            downstream would be reading the same name back.

            SO THE PACKAGE IS ASKED INSTEAD. A modern .msu is a WIM (the first
            four bytes are MSWIM, not MSCF - Microsoft changed the container, and
            expand.exe cannot open one at all, which is what makes MDT's
            ZTIPatches mechanism dead here rather than merely unfashionable).
            Inside it is onepackage.AggregatedMetadata.cab, and inside that is
            one CompDB XML per package the .msu carries: the cumulative update,
            and the servicing stack update bundled with it.

            This command takes those XML documents as text and returns one row.
            Extracting them is Get-HDTUpdateMetadataCommand's and the process
            adapter's job; deciding what they mean is a decision, and decisions
            are unit tested.

            WHAT IS AUTHORITATIVE HERE, verified on 2026-09-01 against both real
            packages:

              Kb                Feature/@FeatureID, e.g. CumulativeUpdate_KB5094126
              Kind              Feature/@Type - CumulativeUpdate or
                                ServicingStackUpdate. THIS IS WHAT MAKES SSU
                                DETECTION EXACT rather than a guess at a file name.
              Architecture      @BuildArch, translated amd64 -> x64
              BaselineVersion   @OSVersion - the build the update expects to find
              TargetVersion     @TargetOSVersion - the build it produces
              PackageId         the Package/@ID it installs
              SourceBranch      the branch token out of @TargetBuildInfo
              CreatedUtc        @CreatedDate

            AND WHAT IS NOT, WHICH MATTERS MORE. There is no product family in
            this file and no edition. @Product says "Desktop" for the Windows
            SERVER package exactly as it does for the client one - both were read
            on 2026-09-01 and both say Desktop - so exposing it as a product
            family would be inventing a fact. Nothing here can tell Windows 11
            24H2 from Windows Server 2025: they share build 26100, they share the
            baseline 10.0.26100.1742, and they share the architecture. The
            administrator's label at import is the only source of that, and
            Import-HDTWindowsUpdate says so rather than pretending otherwise.

            SourceBranch IS RECORDED AND NEVER MATCHED ON. ge_release_svc_prod1
            for the client package against lt_release_svc_prod1 for the server
            one is the only field that differs between the two, and it is an
            undocumented Microsoft build-branch string seen in three samples. It
            is worth showing an administrator and worth a warning when it
            disagrees with the release they chose; it is not worth refusing an
            import over, and it separates a SERVICING BRANCH rather than a
            product - Windows 11 LTSC would read lt_release too.

        .PARAMETER Document
            The CompDB XML documents, as text. A .msu normally yields two - the
            cumulative update and its bundled servicing stack update - and a
            Windows 11 package adds a model CompDB, which is ignored: its @Type
            is Build rather than BuildUpdate, so it describes the operating
            system and not the update.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Kb, Kind,
            Architecture, BaselineVersion, TargetVersion, Build, Revision,
            PackageId, SourceBranch, CreatedUtc, BundledSsuKb and
            BundledSsuVersion.

        .EXAMPLE
            $xml = [System.IO.File]::ReadAllText('C:\meta\LCUCompDB_KB5094126.xml')
            ConvertFrom-HDTUpdateMetadata -Document @($xml)

            The Windows 11 24H2 cumulative update, as the package describes
            itself.

        .EXAMPLE
            (ConvertFrom-HDTUpdateMetadata -Document $xml).Kind -eq 'ServicingStackUpdate'

            Whether this package is a servicing stack update, which is what
            decides the order the ApplyUpdates step applies it in.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [string[]] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $compDb = New-Object -TypeName System.Collections.ArrayList

    foreach ($text in @($Document)) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        # A DOCUMENT THAT IS NOT XML IS SKIPPED, NOT FATAL, AND A REAL PACKAGE
        # FORCED THIS. The Windows 11 cumulative update's aggregated metadata cab
        # carries a JSON manifest of MSIX workload entities alongside the CompDB
        # cabs; the Server package carries none. Throwing on it made every client
        # package import with no metadata at all while the server package read
        # perfectly - found by running both, not by a test.
        #
        # A SET WITH NO CompDB IN IT IS STILL REFUSED, below, so this skips noise
        # without hiding a package that said nothing.
        $xml = $null
        try {
            $xml = [xml] $text
        } catch {
            continue
        }

        # The document element, whatever namespace prefix it was written with.
        if ($xml.DocumentElement.LocalName -ne 'CompDB') {
            continue
        }

        # @Type Build is a MODEL CompDB - it describes the operating system the
        # update targets, not the update - and a Windows 11 .msu ships one
        # alongside the two that matter. Reading it as the package reports the
        # wrong KB, so it is skipped by the only thing that distinguishes it.
        if ([string] $xml.DocumentElement.GetAttribute('Type') -ne 'BuildUpdate') {
            continue
        }

        [void] $compDb.Add($xml.DocumentElement)
    }

    if ($compDb.Count -eq 0) {
        throw 'a Windows update package must carry at least one CompDB describing an update; no CompDB was found in the metadata read from it.'
    }

    # THE FEATURE IS WHERE THE KIND AND THE KB LIVE. One Feature per CompDB in
    # every package read so far, and its @Type is the exact answer to "is this a
    # servicing stack update" that a file name can only guess at.
    $row = foreach ($element in @($compDb)) {
        $feature = @($element.GetElementsByTagName('Feature') | Where-Object { $_.LocalName -eq 'Feature' })

        $kind = ''
        $featureId = ''
        if ($feature.Count -gt 0) {
            $kind = [string] $feature[0].GetAttribute('Type')
            $featureId = [string] $feature[0].GetAttribute('FeatureID')
        }

        $package = @($element.GetElementsByTagName('Package') | Where-Object { $_.LocalName -eq 'Package' })
        $packageId = ''
        if ($package.Count -gt 0) {
            $packageId = [string] $package[0].GetAttribute('ID')
        }

        [pscustomobject] @{
            Kind            = $kind
            # CumulativeUpdate_KB5094126 -> KB5094126. The KB is the tail after
            # the underscore, which is the shape both packages and the standalone
            # servicing stack updates inside them use.
            Kb              = [string] ([regex]::Match($featureId, 'KB\d+').Value)
            Architecture    = [string] $element.GetAttribute('BuildArch')
            BaselineVersion = [string] $element.GetAttribute('OSVersion')
            TargetVersion   = [string] $element.GetAttribute('TargetOSVersion')
            PackageId       = $packageId
            BuildInfo       = [string] $element.GetAttribute('TargetBuildInfo')
            CreatedUtc      = [string] $element.GetAttribute('CreatedDate')
        }
    }

    $all = @($row)

    # THE PRIMARY IS THE ONE THAT IS NOT THE BUNDLED SERVICING STACK. A .msu
    # holding a cumulative update and its SSU has two; a standalone SSU has one,
    # and then the servicing stack update IS the package.
    $primary = @($all | Where-Object { $_.Kind -ne 'ServicingStackUpdate' })
    $ssu = @($all | Where-Object { $_.Kind -eq 'ServicingStackUpdate' })

    $bundledKb = ''
    $bundledVersion = ''

    if ($primary.Count -eq 0) {
        $primary = $ssu
        $ssu = @()
    }

    if ($ssu.Count -gt 0) {
        $bundledKb = [string] $ssu[0].Kb
        $bundledVersion = [string] $ssu[0].TargetVersion
    }

    $chosen = $primary[0]

    # amd64 IS DISM'S WORD AND x64 IS EVERY HDT DOCUMENT'S. os.yaml, the release
    # list and the console all say x64; a catalog that stored both spellings
    # would never match itself. -replace, not a branch: an architecture this does
    # not know is passed through as the package spelled it rather than guessed at.
    $architecture = [string] $chosen.Architecture -replace '^amd64$', 'x64'

    # 10.0.26100.8655 -> build 26100, revision 8655. The build is what a release
    # is matched on; the revision is what tells two releases sharing a build
    # apart in a report, and nothing matches on it.
    $build = 0
    $revision = 0
    $version = [regex]::Match([string] $chosen.TargetVersion, '^\d+\.\d+\.(?<build>\d+)\.(?<revision>\d+)$')
    if ($version.Success) {
        $build = [int] $version.Groups['build'].Value
        $revision = [int] $version.Groups['revision'].Value
    }

    # ge_release_svc_prod1.26100.8655.260605-1839 -> ge_release_svc_prod1. The
    # branch is everything before the first dot; the rest is the build stamp,
    # which TargetVersion already carries in a form worth comparing.
    $branch = [string] ([regex]::Match([string] $chosen.BuildInfo, '^[^.]+').Value)

    return [pscustomobject] @{
        Kb                = [string] $chosen.Kb
        Kind              = [string] $chosen.Kind
        Architecture      = $architecture
        BaselineVersion   = [string] $chosen.BaselineVersion
        TargetVersion     = [string] $chosen.TargetVersion
        Build             = $build
        Revision          = $revision
        PackageId         = [string] $chosen.PackageId
        SourceBranch      = $branch
        CreatedUtc        = [string] $chosen.CreatedUtc
        BundledSsuKb      = $bundledKb
        BundledSsuVersion = $bundledVersion
    }
}
