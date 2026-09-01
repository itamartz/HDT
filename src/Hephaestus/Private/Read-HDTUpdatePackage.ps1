function Read-HDTUpdatePackage {
    <#
        .SYNOPSIS
            Asks a .msu what it is, by extracting the metadata it carries.

        .DESCRIPTION
            THE THREE STAGES, RUN. Get-HDTUpdateMetadataCommand decides what to
            run and ConvertFrom-HDTUpdateMetadata decides what the answer means;
            this is the part in between that drives them, and it exists so
            Import-HDTWindowsUpdate reads as a list of decisions rather than as a
            transcript of DISM invocations.

              1  dism /List-Image names every entry in the container.
              2  dism /Apply-Image, with an exclusion list naming every entry
                 EXCEPT onepackage.AggregatedMetadata.cab, extracts that one file.
              3  expand.exe opens it, and opens each CompDB cab inside it, and the
                 XML that falls out is the package describing itself.

            IT NEVER THROWS FOR A PACKAGE IT COULD NOT READ. An empty row comes
            back instead, and Import-HDTWindowsUpdate falls back to the file name
            with a note saying it did. The metadata cab is a Microsoft convention
            rather than a guarantee - the container layout has already changed
            once, from cabinet to WIM, which is what killed MDT's mechanism - and
            an importer that refused every package it did not recognise would be
            brittle in the one direction that costs an administrator their
            afternoon.

            THE SCRATCH DIRECTORY IS THIS PROCESS'S OWN AND IS REMOVED BY THE
            CODE THAT MADE IT, which is the only shape of deletion CLAUDE.md
            permits. It is created under the caller's temp path with a name
            carrying a fresh GUID, so two imports running at once cannot collide.

        .PARAMETER Path
            The .msu to read.

        .PARAMETER FileSystem
            An IFileSystem, for the scratch directory and for reading what fell
            out of the cabinets.

        .PARAMETER Process
            An IProcessService, to run dism and expand.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, as
            ConvertFrom-HDTUpdateMetadata returns one. Every field is empty or
            zero when the package carried nothing readable.

        .EXAMPLE
            Read-HDTUpdatePackage -Path 'D:\updates\kb5094126.msu' -FileSystem $fs -Process $p

            KB5094126, its architecture, the build it produces and the servicing
            stack update bundled with it - in about a tenth of a second, without
            unpacking the four point seven gigabytes beside them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Process
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE EMPTY ANSWER, DEFINED ONCE. Every failure path below returns this
    # rather than throwing, and the caller reads it as "the package said
    # nothing".
    $empty = [pscustomobject] @{
        Kb                = ''
        Kind              = ''
        Architecture      = ''
        BaselineVersion   = ''
        TargetVersion     = ''
        Build             = 0
        Revision          = 0
        PackageId         = ''
        SourceBranch      = ''
        CreatedUtc        = ''
        BundledSsuKb      = ''
        BundledSsuVersion = ''
    }

    $scratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
        ('HDT-update-{0}' -f [guid]::NewGuid().ToString('N')))

    try {
        $FileSystem.CreateDirectory($scratch)

        # -- 1. what is in the container --------------------------------------

        $list = Get-HDTUpdateMetadataCommand -Stage List -PackagePath $Path

        $listRun = $Process.Start([string] $list.FilePath,
            ((@($list.Argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ })) -join ' '),
            $scratch, 300000)

        if ([int] $listRun.ExitCode -ne 0) { return $empty }

        $entry = @(ConvertFrom-HDTUpdateFileList -Output ([string[]] (([string] $listRun.StandardOutput) -split "`r?`n")))

        if ($entry.Count -eq 0) { return $empty }

        # -- 2. that one file, and none of the rest ---------------------------

        $metadataCab = 'onepackage.AggregatedMetadata.cab'

        $configPath = [System.IO.Path]::Combine($scratch, 'exclude.ini')
        $FileSystem.WriteAllText($configPath,
            (Get-HDTUpdateExclusionText -Entry $entry -Keep $metadataCab))

        $extractRoot = [System.IO.Path]::Combine($scratch, 'meta')
        $FileSystem.CreateDirectory($extractRoot)

        $extract = Get-HDTUpdateMetadataCommand -Stage Extract -PackagePath $Path `
            -Destination $extractRoot -ConfigPath $configPath

        $extractRun = $Process.Start([string] $extract.FilePath,
            ((@($extract.Argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ })) -join ' '),
            $scratch, 600000)

        if ([int] $extractRun.ExitCode -ne 0) { return $empty }

        $cabPath = [System.IO.Path]::Combine($extractRoot, $metadataCab)

        if (-not $FileSystem.TestPath($cabPath)) { return $empty }

        # -- 3. the cabinets, twice ------------------------------------------

        # THE AGGREGATED CAB HOLDS MORE CABS, not the XML. One expand yields
        # LCUCompDB_KB<n>.xml.cab and SSUCompDB_KB<n>.xml.cab; a second expand of
        # each of those yields the XML.
        $expandRoot = [System.IO.Path]::Combine($scratch, 'expanded')
        $FileSystem.CreateDirectory($expandRoot)

        $expand = Get-HDTUpdateMetadataCommand -Stage Expand -CabPath $cabPath -Destination $expandRoot

        $null = $Process.Start([string] $expand.FilePath,
            ((@($expand.Argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ })) -join ' '),
            $scratch, 300000)

        $xmlRoot = [System.IO.Path]::Combine($scratch, 'xml')
        $FileSystem.CreateDirectory($xmlRoot)

        foreach ($child in @($FileSystem.GetChildItem($expandRoot))) {
            $inner = Get-HDTUpdateMetadataCommand -Stage Expand -CabPath ([string] $child) -Destination $xmlRoot

            $null = $Process.Start([string] $inner.FilePath,
                ((@($inner.Argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ })) -join ' '),
                $scratch, 300000)
        }

        $document = foreach ($child in @($FileSystem.GetChildItem($xmlRoot))) {
            $FileSystem.ReadAllText([string] $child)
        }

        $text = [string[]] @($document)

        if ($text.Count -eq 0) { return $empty }

        return (ConvertFrom-HDTUpdateMetadata -Document $text)

    } catch {
        # A PACKAGE THAT COULD NOT BE READ IS NOT A FAILED IMPORT. The caller
        # falls back to the file name and records that it had to.
        Write-Verbose ("Read-HDTUpdatePackage: '{0}' carried no readable metadata: {1}" -f $Path, $_.Exception.Message)
        return $empty
    } finally {
        # REMOVED BY THE CODE THAT CREATED IT, IN THE SAME RUN, BY LITERAL PATH -
        # which is the only deletion shape CLAUDE.md permits.
        if ($FileSystem.TestPath($scratch)) {
            $FileSystem.RemoveItem($scratch, $true)
        }
    }
}
