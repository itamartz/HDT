function Update-HDTMediaContent {
    <#
        .SYNOPSIS
            Builds the disc: projects a share through a media definition's
            selection profile, swaps the provider, assembles the WinPE media tree
            and burns one bootable ISO.

        .DESCRIPTION
            DESIGN 6.2's command. New-HDTMedia records the definition; this
            builds it - MDT's own split between a media object and
            "Update Media Content", and the same split Update-HDTBootImage and
            Set-HDTBootImageDriver already use here.

            MEDIA GENERATION IS A CONTENT PROJECTION PLUS A PROVIDER SWAP, and
            neither half is written here. Get-HDTMediaProjection says what
            travels and what is refused - purely, in milliseconds, against a fake
            - and Set-HDTMediaWorkspaceLine does the swap with two splices. This
            command is assembly.

            TWELVE STEPS, AND THEY ARE THE COMMENTED BLOCKS BELOW IN ORDER, so
            this file reads like the journal tests/unit/Update-HDTMediaContent.Tests.ps1
            asserts:

               1  read the media definition, and refuse a disabled one by name
               2  read workspace.yaml, and refuse a share with no rules.yaml
               3  project - and LOG EVERY ROW, warning each folder that is not
                  there
               4  the application dependency pass, which warns and does not fix
               5  ShouldProcess on the output ISO
               6  create the staging tree, in a try/finally that removes only
                  what this run created
               7  copy the ADK WinPE Media tree and create sources\
               8  project the rows onto <scratch>\media\Share
               9  write the rewritten workspace.yaml
              10  build the boot image AGAINST THE PROJECTED SHARE with -SkipIso,
                  move its wim to sources\boot.wim, and remove the projected
                  share's Boot folder
              11  burn one ISO with -NoPromptForKey
              12  publish the ISO, then write media.manifest.json LAST

            STEP 10 IS THE DECISION WORTH BEING EXPLICIT ABOUT, because the
            alternative looks cheaper and is wrong. Copying the share's existing
            Boot\HDTPE_x64.wim onto the disc would put an Smb image on it
            whenever the share's deployRoot is a UNC path - which is every real
            share. The image DERIVES its provider from the workspace.yaml it was
            built against:

                $provider = 'Local'
                if (([string] $workspace.DeployRoot).StartsWith('\\')) { $provider = 'Smb' }

            so the only honest way to get a Local image is to build against the
            projected one. -SkipIso because Update-HDTBootImage would otherwise
            burn a debugging ISO nobody asked for, in the middle of building the
            one that was.

            EVERY INJECTED SERVICE IS PASSED ON TO EVERY COMMAND THAT TAKES ONE.
            None of these parameters is mandatory anywhere in the chain and they
            all default to the real adapter, so dropping one is not a bind error
            and not a red test - it is a build that quietly reaches this machine's
            registry, disk and ADK. The unit suite's whole "no ADK, no DISM, no
            oscdimg" claim rests on it.

            THE FOUR REFUSALS EACH COST A REBUILD ON 2026-09-03 and each has its
            reason written on Get-HDTMediaProjection, where the next person to
            simplify one will read it.

            IT WARNS AND BUILDS. A folder the profile names that the share has
            not got, and an application whose dependency is not on the disc, are
            both sentences rather than refusals: the profile is the
            administrator's statement of intent, and MDT would have let the
            machine find out on the bench.

        .PARAMETER WorkspaceRoot
            The deployment share to build from.

        .PARAMETER Id
            The media definition - a folder under Media\ holding a media.yaml.

        .PARAMETER ScratchPath
            Where the staging tree goes. Defaults to
            %ProgramData%\Hephaestus\media, which has no space on any default
            install and is machine-scoped like the elevated build that writes to
            it. NOT one lab's path.

        .PARAMETER AdkRoot
            An explicit ADK root, which wins over the registry.

        .PARAMETER Architecture
            amd64 (default) or arm64.

        .PARAMETER Firmware
            UEFI (default), BIOS or Both.

        .PARAMETER EngineModulePath
            The Hephaestus module to stage into the boot image. Defaults to this
            module's own location, exactly as Update-HDTBootImage's does.

        .PARAMETER YamlModulePath
            powershell-yaml, for the same.

        .PARAMETER BootImageService
            An IBootImageService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Registry
            An IRegistryService, for resolving the ADK. Defaults to the real
            adapter.

        .PARAMETER Clock
            An IClock. Defaults to the real adapter.

        .PARAMETER Progress
            Where the steps are reported. Omitted, they go to a sink that records
            nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, IsoPath,
            IsoSizeBytes, IsoSha256, BootWimSha256, SelectionProfile, Projected,
            Excluded, Warning and ManifestPath.

        .EXAMPLE
            Update-HDTMediaContent -WorkspaceRoot 'C:\HDTLab\Share' -Id 'LAB-DISC'

            One bootable ISO carrying what the definition's selection profile
            names, with a Local boot image on it.

        .EXAMPLE
            Update-HDTMediaContent -WorkspaceRoot 'C:\HDTLab\Share' -Id 'LAB-DISC' -WhatIf

            THE PASS WORTH RUNNING FIRST, and the reason it is worth running is
            that it is where the warnings are. It projects the share, checks the
            application dependencies and prints both - the folder the profile
            names that is not there, and the application on the disc whose
            dependency is not - and then writes nothing. That is the same
            finding a real build gives, minus the ten minutes and the
            multi-gigabyte staging tree.

        .LINK
            New-HDTMedia

        .LINK
            Update-HDTBootImage
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScratchPath = [System.IO.Path]::Combine($env:ProgramData, 'Hephaestus', 'media'),

        [Parameter()]
        [AllowEmptyString()]
        [string] $AdkRoot = '',

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [ValidateSet('UEFI', 'BIOS', 'Both')]
        [string] $Firmware = 'UEFI',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $EngineModulePath = $script:HDTModuleRoot,

        [Parameter()]
        [AllowEmptyString()]
        [string] $YamlModulePath = '',

        [Parameter()]
        [AllowNull()]
        [object] $BootImageService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Registry,

        [Parameter()]
        [AllowNull()]
        [object] $Clock,

        [Parameter()]
        [AllowNull()]
        [object] $Progress
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Registry) { $Registry = New-HDTRegistryService }
    if ($null -eq $BootImageService) { $BootImageService = New-HDTBootImageService }
    if ($null -eq $Clock) { $Clock = New-HDTClock }
    if ($null -eq $Progress) { $Progress = New-HDTBuildProgress }

    $startedUtc = $Clock.GetUtcNow()
    $stepTotal = 12

    # =====================================================================
    # 1. THE MEDIA DEFINITION
    # =====================================================================

    $Progress.Report(1, $stepTotal, 'Reading the media definition', $Id)

    $media = Get-HDTMedia -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem

    Write-Information ("media: building '{0}' ({1}) from selection profile '{2}'" -f
        [string] $media.Id, [string] $media.Name, [string] $media.SelectionProfile)
    Write-Information ("media: the ISO goes to '{0}'" -f [string] $media.OutputPath)

    # ENABLED IS A REFUSAL, NOT A FILTER (DESIGN 6.2). A build that did nothing
    # reads as a broken build, so this says which item and what to type.
    if (-not [bool] $media.Enabled) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path ([string] $media.DocumentPath) `
                    -Message ("the media definition '{0}' is disabled, so nothing was built. Run Set-HDTMedia -WorkspaceRoot '{1}' -Id '{0}' -Enabled `$true to turn it back on." -f
                        $Id, $WorkspaceRoot)))
    }

    # =====================================================================
    # 2. THE WORKSPACE, AND THE MARKER WITHOUT WHICH A DISC IS INVISIBLE
    # =====================================================================

    $Progress.Report(2, $stepTotal, 'Reading the workspace document', $WorkspaceRoot)

    $workspacePath = [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml')
    $workspaceText = [string] $FileSystem.ReadAllText($workspacePath)
    $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

    $markerPath = [System.IO.Path]::Combine($WorkspaceRoot, 'rules.yaml')

    if (-not $FileSystem.TestPath($markerPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $markerPath -Category ObjectNotFound `
                    -Message 'this share has no rules.yaml, and rules.yaml is the content marker Resolve-HDTDeployRoot hunts every ready volume for. A disc built without it could not be found by the machine booting from it.'))
    }

    Write-Information ("media: the share's deployRoot is '{0}', and the disc's will be '\Share'" -f
        [string] $workspace.DeployRoot)

    # =====================================================================
    # 3. THE PROJECTION - LOGGED IN FULL, because this is the answer to
    #    "why is that not on the disc" a week later on a machine nobody can
    #    touch.
    # =====================================================================

    $Progress.Report(3, $stepTotal, 'Projecting the share', [string] $media.SelectionProfile)

    $row = @(Get-HDTMediaProjection -WorkspaceRoot $WorkspaceRoot `
            -SelectionProfile ([string] $media.SelectionProfile) -FileSystem $FileSystem)

    $projected = @($row | Where-Object { $_.Kind -ne 'Excluded' })
    $excluded = @($row | Where-Object { $_.Kind -eq 'Excluded' })

    $sentence = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $projected) {
        Write-Information ("media: [{0}] '{1}' -> '{2}' - {3}" -f
            [string] $current.Kind, [string] $current.Source, [string] $current.Destination, [string] $current.Reason)

        if ([bool] $current.Present) { continue }

        # A MISSING FOLDER IS NAMED, NOT DROPPED. Dropping it silently is how a
        # disc ships without one vendor's drivers and nobody finds out until a
        # laptop cannot see its disk on a bench.
        $missing = ("the selection profile '{0}' names '{1}' and this share has not got it, so nothing from it is on the disc." -f
            [string] $media.SelectionProfile, [string] $current.Source)

        [void] $sentence.Add($missing)
        Write-Warning $missing
    }

    foreach ($current in $excluded) {
        Write-Information ("media: REFUSED '{0}' - {1}" -f [string] $current.Source, [string] $current.Reason)
    }

    # =====================================================================
    # 4. THE DEPENDENCY PASS - it warns, and it does not fix
    # =====================================================================

    $Progress.Report(4, $stepTotal, 'Checking application dependencies', '')

    $catalog = @(Get-HDTApplication -WorkspaceRoot $WorkspaceRoot -FileSystem $FileSystem)
    $carried = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $projected) {
        if ([string] $current.Kind -ne 'Content') { continue }
        if (-not [bool] $current.Present) { continue }

        # [char[]] EXPLICITLY: Split('\', '/') binds to Split(char, int) and
        # tries to read '/' as a count.
        $segment = ([string] $current.Source).TrimStart('\', '/').Split([char[]] @('\', '/'))
        if ($segment[0] -ne 'Applications') { continue }

        # THE WHOLE FOLDER MEANS EVERY APPLICATION IN IT; a named one means that
        # one. Both are legal includes and the difference decides which
        # dependencies are missing.
        if (@($segment).Count -eq 1) {
            foreach ($entry in @($catalog)) { [void] $carried.Add([string] $entry.Id) }
            continue
        }

        [void] $carried.Add([string] $segment[1])
    }

    $carriedId = [string[]] @(@($carried) | Sort-Object -Unique)

    Write-Information ("media: the disc carries {0} application(s): {1}" -f
        @($carriedId).Count, ((@($carriedId) -join ', ')))

    foreach ($warning in @(Get-HDTMediaDependencyWarning -Application ([object[]] @($catalog)) -CarriedId $carriedId)) {
        [void] $sentence.Add([string] $warning)
        Write-Warning ([string] $warning)
    }

    # =====================================================================
    # 5. ShouldProcess - IT OVERWRITES A FILE SOMEBODY MAY BE BOOTING FROM
    # =====================================================================

    $isoPath = [string] $media.OutputPath
    $manifestPath = [System.IO.Path]::Combine([string] $media.Folder, 'media.manifest.json')

    $description = 'Build standalone media {0} from selection profile {1}' -f $Id, [string] $media.SelectionProfile

    if (-not $PSCmdlet.ShouldProcess($isoPath, $description)) {
        return [pscustomobject] @{
            Id               = $Id
            IsoPath          = $isoPath
            IsoSizeBytes     = [long] 0
            IsoSha256        = ''
            BootWimSha256    = ''
            SelectionProfile = [string] $media.SelectionProfile
            Projected        = [pscustomobject[]] @($projected)
            Excluded         = [pscustomobject[]] @($excluded)
            Warning          = [string[]] @($sentence)
            ManifestPath     = $manifestPath
        }
    }

    # =====================================================================
    # 6-11. THE STAGING TREE. Everything from here is inside a try that
    #       removes it, by explicit -LiteralPath, whatever happens.
    # =====================================================================

    $scratch = $ScratchPath.TrimEnd('\', '/')
    $mediaPath = [System.IO.Path]::Combine($scratch, 'media')
    $projectedShare = [System.IO.Path]::Combine($mediaPath, 'Share')
    $mediaSources = [System.IO.Path]::Combine($mediaPath, 'sources')
    $bootScratch = [System.IO.Path]::Combine($scratch, 'bootimage')
    $bitPath = [System.IO.Path]::Combine($scratch, 'bootbits')
    $stagedIso = [System.IO.Path]::Combine($scratch, [System.IO.Path]::GetFileName($isoPath))

    $isoSize = [long] 0
    $isoSha256 = ''
    $bootWimSha256 = ''

    try {
        $Progress.Report(6, $stepTotal, 'Preparing the staging tree', $mediaPath)

        # ONLY WHAT THIS RUN IS ABOUT TO CREATE, by explicit path. Nothing here
        # enumerates a parent directory to find something to delete.
        $FileSystem.RemoveItem($mediaPath, $true)
        $FileSystem.CreateDirectory($mediaPath)
        $FileSystem.CreateDirectory($projectedShare)

        # -- 7. the ADK media tree ----------------------------------------

        $adkSplat = @{
            Architecture = $Architecture
            Registry     = $Registry
            FileSystem   = $FileSystem
        }
        if (-not [string]::IsNullOrWhiteSpace($AdkRoot)) { $adkSplat['Root'] = $AdkRoot }

        # RESOLVED, NEVER WRITTEN DOWN - PROJECT.md: "the layout has moved
        # between ADK releases." It reads BOTH injected services: the registry to
        # find the install, the filesystem to check the asset is there.
        $winPeMedia = Get-HDTAdkPath -Asset WinPeMedia @adkSplat

        $Progress.Report(7, $stepTotal, 'Copying the ADK media tree', $mediaPath)

        [void] (Copy-HDTContentTree -Source $winPeMedia -Destination $mediaPath -FileSystem $FileSystem)

        # The WinPE Media template has no sources\ folder; step 10 puts the
        # exported WIM there as boot.wim.
        $FileSystem.CreateDirectory($mediaSources)

        # -- 8. the projection, onto the disc -----------------------------

        $Progress.Report(8, $stepTotal, 'Copying the projected content', ('{0} row(s)' -f @($projected).Count))

        $at = 0

        foreach ($current in $projected) {
            $at++

            # workspace.yaml is REWRITTEN rather than copied - step 9 writes it -
            # and a folder the share has not got has nothing to copy.
            if ([bool] $current.Rewritten) { continue }
            if (-not [bool] $current.Present) { continue }

            $source = [string] $current.FullPath
            $destination = [System.IO.Path]::Combine($mediaPath,
                ([string] $current.Destination).TrimStart('\', '/'))

            $Progress.Report(8, $stepTotal, 'Copying the projected content',
                ('{0} of {1} - {2}' -f $at, @($projected).Count, [string] $current.Source))

            if ([string] $current.Kind -eq 'Control') {
                # CONTROL TRAVELS MINUS ONE FILE, and the credential is skipped
                # rather than copied and deleted: a copy that happened and was
                # undone is a copy that existed.
                $FileSystem.CreateDirectory($destination)

                foreach ($child in @($FileSystem.GetChildItem($source))) {
                    $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))

                    if ($leaf -eq 'share-credential.json') {
                        Write-Information "media: Control\share-credential.json was skipped, not copied and removed."
                        continue
                    }

                    $childTarget = [System.IO.Path]::Combine($destination, $leaf)

                    if (Test-HDTFileSystemFile -Path ([string] $child) -FileSystem $FileSystem) {
                        $FileSystem.CopyItem([string] $child, $childTarget)
                        continue
                    }

                    [void] (Copy-HDTContentTree -Source ([string] $child) -Destination $childTarget -FileSystem $FileSystem)
                }

                continue
            }

            if (Test-HDTFileSystemFile -Path $source -FileSystem $FileSystem) {
                $FileSystem.CopyItem($source, $destination)
                continue
            }

            # THE RECURSION THE PROFILE DELIBERATELY DOES NOT DO.
            # Expand-HDTSelectionProfile answers with folder names; the consumer
            # walks them, and for media the consumer is this line.
            [void] (Copy-HDTContentTree -Source $source -Destination $destination -FileSystem $FileSystem)
        }

        # -- 9. the provider swap -----------------------------------------

        $Progress.Report(9, $stepTotal, 'Rewriting workspace.yaml for the disc', '\Share')

        $projectedLine = [string[]] @(Set-HDTMediaWorkspaceLine -Line ([string[]] @($workspaceText -split "`r?`n")))

        $FileSystem.WriteAllText([System.IO.Path]::Combine($projectedShare, 'workspace.yaml'),
            ($projectedLine -join [System.Environment]::NewLine))

        Write-Information "media: the projected workspace.yaml carries deployRoot '\Share' and no credential block, so the boot image derives the Local provider from it."

        # -- 10. the boot image, BUILT AGAINST THE PROJECTED SHARE --------

        $Progress.Report(10, $stepTotal, 'Building the boot image for the disc', $projectedShare)

        $bootSplat = @{
            WorkspaceRoot    = $projectedShare
            ScratchPath      = $bootScratch
            SkipIso          = $true
            Architecture     = $Architecture
            AdkRoot          = $AdkRoot
            EngineModulePath = $EngineModulePath
            YamlModulePath   = $YamlModulePath
            BootImageService = $BootImageService
            FileSystem       = $FileSystem
            Registry         = $Registry
            Clock            = $Clock
            Progress         = $Progress
            Confirm          = $false
        }

        $bootImage = Update-HDTBootImage @bootSplat

        $bootWimSha256 = [string] $bootImage.WimSha256

        Write-Information ("media: the boot image is Local, built against '{0}', SHA256 {1}" -f
            $projectedShare, $bootWimSha256)

        $bootWimTarget = [System.IO.Path]::Combine($mediaSources, 'boot.wim')

        $FileSystem.MoveItem([string] $bootImage.WimPath, $bootWimTarget)

        # THE FOURTH REFUSAL, AND IT IS A DIRECTORY THIS PROCESS CREATED IN THIS
        # RUN. Boot\ inside \Share puts half a gigabyte on the ISO twice.
        $FileSystem.RemoveItem([System.IO.Path]::Combine($projectedShare, 'Boot'), $true)

        Write-Information ("media: the boot image is at '\sources\boot.wim' and the projected share's Boot folder was removed, so the wim is on the disc once.")

        # -- 11. the burn --------------------------------------------------

        $Progress.Report(11, $stepTotal, 'Burning the ISO', $stagedIso)

        $iso = New-HDTBootIso -MediaRoot $mediaPath -Path $stagedIso -NoPromptForKey `
            -BootBitPath $bitPath -Firmware $Firmware -Architecture $Architecture -AdkRoot $AdkRoot `
            -Label ('HDT_{0}' -f $Id) `
            -BootImageService $BootImageService -FileSystem $FileSystem -Registry $Registry -Confirm:$false

        $isoSize = [long] $iso.SizeBytes
        $isoSha256 = [string] $iso.Sha256

        # -- 12. publish ---------------------------------------------------

        $Progress.Report(12, $stepTotal, 'Publishing the ISO', $isoPath)

        $FileSystem.CreateDirectory([string] $media.Folder)
        $FileSystem.RemoveItem($isoPath, $false)
        $FileSystem.MoveItem($stagedIso, $isoPath)

        Write-Information ("media: the ISO is at '{0}', {1} byte(s), SHA256 {2}" -f $isoPath, $isoSize, $isoSha256)
    } finally {
        # WHAT THIS RUN CREATED, BY EXPLICIT PATH, and nothing else. A build that
        # left a multi-gigabyte tree behind on every failure fills the disk the
        # next attempt needs.
        try {
            $FileSystem.RemoveItem($scratch, $true)
        } catch {
            Write-Warning ("the staging tree '{0}' could not be removed: {1}" -f $scratch, [string] $_.Exception.Message)
        }
    }

    # =====================================================================
    # THE MANIFEST, LAST, so a manifest on disk means the ISO beside it came
    # from the build that wrote it.
    # =====================================================================

    $builtUtc = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

    $manifestText = New-HDTMediaManifest -MediaId $Id -Name ([string] $media.Name) `
        -BuildId ([guid]::NewGuid().ToString()) -BuiltUtc $builtUtc -BuiltOn $env:COMPUTERNAME `
        -EngineVersion (Get-HDTModuleVersion) -WorkspaceId ([string] $workspace.Id) `
        -WorkspaceRoot $WorkspaceRoot -SelectionProfile ([string] $media.SelectionProfile) `
        -DeployRoot '\Share' -Architecture $Architecture -Firmware $Firmware `
        -Projected ([object[]] @($projected)) -Excluded ([object[]] @($excluded)) `
        -Warning ([string[]] @($sentence)) `
        -Iso @{ Path = $isoPath; Sha256 = $isoSha256; SizeBytes = $isoSize } `
        -BootWimSha256 $bootWimSha256

    $FileSystem.WriteAllText($manifestPath, $manifestText)

    $Progress.Complete($true, $isoPath)

    return [pscustomobject] @{
        Id               = $Id
        IsoPath          = $isoPath
        IsoSizeBytes     = $isoSize
        IsoSha256        = $isoSha256
        BootWimSha256    = $bootWimSha256
        SelectionProfile = [string] $media.SelectionProfile
        Projected        = [pscustomobject[]] @($projected)
        Excluded         = [pscustomobject[]] @($excluded)
        Warning          = [string[]] @($sentence)
        ManifestPath     = $manifestPath
    }
}
