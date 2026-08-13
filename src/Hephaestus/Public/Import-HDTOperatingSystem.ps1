function Import-HDTOperatingSystem {
    <#
        .SYNOPSIS
            Promotes an operating system source into the workspace catalog.

        .DESCRIPTION
            DESIGN 9.3: "Import-HDTOperatingSystem promotes a capture into the OS
            catalog." DESIGN 2.1 fixes where it lands -
            OperatingSystems\<id>\os.yaml - and this is the only writer of that
            document.

            THE IMAGE LIST IS READ FROM THE IMAGE FILE, NEVER TYPED BY HAND. It
            comes through IImageService.GetImageInfo, so the catalog cannot
            disagree with the media it describes. A catalog whose indices an
            author entered is a catalog that lies the first time the media is
            rebuilt, and it lies to the step that decides what to apply.

            EVERY PATH IS BUILT WITH Get-HDTWorkspacePath. That command exists
            because a plan once did not: Start-HDTResume built its path from the
            literal 'Sequences' while the layout said 'TaskSequences', the unit
            suite was green because nothing in it resolved a real workspace path,
            and a deployment would have died at its first reboot. No literal
            'OperatingSystems' appears in this file.

            -Copy IS OPT-IN BECAUSE COPYING 4 GB IS A REAL OPERATION. Without it
            the tree is registered where it stands and sourcePath is recorded as
            given. With it, the directory holding the image is copied to
            <os folder>\sources and sourcePath becomes the relative
            sources\<file>, which is what DESIGN 2.1's layout shows.

            THE CLOCK IS MANDATORY, for the reason it is mandatory everywhere in
            this engine: the only default is a real clock reading inside engine
            code, and a timestamp nobody injected is a timestamp no test can
            assert on.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id. Becomes the folder name under OperatingSystems\, so
            it must match ^[A-Za-z0-9][A-Za-z0-9_.-]*$.

        .PARAMETER SourcePath
            The .wim or .ffu to import.

        .PARAMETER FileSystem
            An IFileSystem.

        .PARAMETER ImageService
            An IImageService. Only GetImageInfo is called.

        .PARAMETER Clock
            An IClock. Stamps importedUtc.

        .PARAMETER Name
            The display name. Defaults to the id.

        .PARAMETER Description
            A free-text note for the console.

        .PARAMETER Copy
            Copy the source tree into the workspace as well as cataloguing it.

        .PARAMETER Force
            Overwrite an existing os.yaml for this id.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the catalog it wrote,
            in the shape Get-HDTOperatingSystem returns.

        .EXAMPLE
            Import-HDTOperatingSystem -WorkspaceRoot 'X:\Deploy' -Id 'Win11-LTSC-2024' `
                -SourcePath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' `
                -FileSystem (New-HDTFileSystem) -ImageService (New-HDTImageService) -Clock (New-HDTClock)

            Registers the staged media in place - seconds, not gigabytes.

        .EXAMPLE
            Import-HDTOperatingSystem -WorkspaceRoot 'X:\Deploy' -Id 'Win11-LTSC-2024' `
                -SourcePath $wim -FileSystem $fs -ImageService $image -Clock $clock -Copy -Force

            Brings the media into the share, replacing an existing entry.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ImageService,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Description,

        [Parameter()]
        [switch] $Copy,

        [Parameter()]
        [switch] $Force
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is not a legal operating system id. It becomes a folder name under the workspace's operating system folder, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $Id)))
    }

    $osFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $Id
    $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $Id, 'os.yaml'

    if ($FileSystem.TestPath($catalogPath) -and -not $Force) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                    -Message ("an operating system with the id '{0}' is already in this workspace. Use -Force to replace it." -f $Id)))
    }

    if (-not $FileSystem.TestPath($SourcePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $SourcePath `
                    -Message 'the source image does not exist.' -Category ObjectNotFound))
    }

    $image = @($ImageService.GetImageInfo($SourcePath))

    if ($image.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $SourcePath `
                    -Message 'the source image declares no index, so there is nothing to catalogue.'))
    }

    $type = 'wim'
    if (([System.IO.Path]::GetExtension($SourcePath)).ToLowerInvariant() -eq '.ffu') { $type = 'ffu' }

    $displayName = $Id
    if (-not [string]::IsNullOrWhiteSpace($Name)) { $displayName = $Name }

    # DISM reports a NUMERIC architecture code, not a string (04-01: both staged
    # media report 9). An unrecognised code is omitted rather than guessed at.
    $architectureByCode = @{ '0' = 'x86'; '9' = 'x64'; '12' = 'arm64' }
    $architecture = ''
    $firstArchitecture = [string] $image[0].Architecture
    if ($architectureByCode.ContainsKey($firstArchitecture)) {
        $architecture = $architectureByCode[$firstArchitecture]
    }

    $recordedSourcePath = $SourcePath
    $sourceTree = [System.IO.Path]::GetDirectoryName($SourcePath)
    $sourceLeaf = [System.IO.Path]::GetFileName($SourcePath)

    if ($Copy) {
        $recordedSourcePath = [System.IO.Path]::Combine('sources', $sourceLeaf)
    }

    $document = [System.Collections.Specialized.OrderedDictionary]::new()
    $document['schemaVersion'] = 1
    $document['id'] = $Id
    $document['name'] = $displayName
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $document['description'] = $Description }
    $document['type'] = $type
    if (-not [string]::IsNullOrWhiteSpace($architecture)) { $document['architecture'] = $architecture }
    $document['sourcePath'] = $recordedSourcePath
    $document['importedUtc'] = $Clock.GetUtcNow().ToString('o')
    $document['defaultIndex'] = [int] $image[0].Index

    $imageDocument = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in $image) {
        $entry = [System.Collections.Specialized.OrderedDictionary]::new()
        $entry['index'] = [int] $current.Index
        $entry['name'] = [string] $current.Name
        if (-not [string]::IsNullOrWhiteSpace([string] $current.Description)) { $entry['description'] = [string] $current.Description }
        if (-not [string]::IsNullOrWhiteSpace([string] $current.Edition)) { $entry['edition'] = [string] $current.Edition }
        if ([long] $current.SizeBytes -gt 0) { $entry['sizeBytes'] = [long] $current.SizeBytes }
        if (-not [string]::IsNullOrWhiteSpace([string] $current.Version)) { $entry['version'] = [string] $current.Version }

        [void] $imageDocument.Add($entry)
    }
    $document['images'] = [object[]] @($imageDocument)

    # The writer is held to the validator, here, before anything is written.
    Assert-HDTOperatingSystemDocument -Document $document -Path $catalogPath

    $text = ConvertTo-HDTYaml -Document $document -Path $catalogPath

    if (-not $PSCmdlet.ShouldProcess($catalogPath, ("Import operating system '{0}'" -f $Id))) {
        return $null
    }

    $FileSystem.CreateDirectory($osFolder)

    if ($Copy) {
        Copy-HDTContentTree -Source $sourceTree -Destination ([System.IO.Path]::Combine($osFolder, 'sources')) -FileSystem $FileSystem | Out-Null
    }

    $FileSystem.WriteAllText($catalogPath, $text)

    return (ConvertTo-HDTOperatingSystemCatalog -Document $document -OsFolder $osFolder -CatalogPath $catalogPath)
}
