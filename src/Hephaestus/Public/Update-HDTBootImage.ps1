function Update-HDTBootImage {
    <#
        .SYNOPSIS
            Builds the HDT boot image: one mount, two artifacts, and a manifest
            saying exactly what went into them.

        .DESCRIPTION
            DESIGN 5: "Like MDT's Update-MDTDeploymentShare, one build produces
            two artifacts from the same source ... Both come from a single
            mount/inject/commit cycle. They are never built separately, so the
            ISO you debug with is byte-for-byte the WinPE you PXE boot - which is
            the entire point of having it."

            SEVENTEEN STEPS, AND THEY ARE WRITTEN BELOW AS SEVENTEEN COMMENTED
            BLOCKS IN ORDER, so this file reads like the journal
            tests/unit/Update-HDTBootImage.Tests.ps1 asserts:

               1  read workspace.yaml
               2  resolve the ADK, and refuse in one sentence if it is incomplete
               3  plan the components
               4  prepare the scratch directories - and refuse a scratch path
                  that has a space in it, or that is inside the workspace or the
                  repository
               5  copy winpe.wim into the scratch
               6  copy the ADK Media tree into the scratch, and create sources\
               7  mount
               8  apply each component, each followed immediately by its language
                  pack
               9  set the scratch space
              10  inject the boot driver group, if there is one
              11  stage the engine, powershell-yaml and both payload scripts
              12  write bootstrap.json
              13  write startnet.cmd
              14  copy extraContent
              15  check the share ACL and warn
              16  dismount saving, export, and COPY the exported WIM into the
                  media tree
              17  build the ISO, then write the manifest LAST

            STEP 16's COPY IS THE WHOLE OF DESIGN 6.1.1. The ISO is built from
            the exported WIM copied into the media tree, not from a second
            export. One file, two homes, same bytes - and the manifest records
            isoBootWimSha256 so an operator can check that without this test
            suite.

            STEP 4 REFUSES A SCRATCH PATH WITH A SPACE IN IT, and that is SPIKES
            S2 rather than fussiness: <scratch>\bootbits is what step 17 hands
            New-HDTBootIso as -BootBitPath, oscdimg's -bootdata: cannot take a
            quoted path, and a space-free staging directory that is itself under
            a path with a space solves nothing. It also refuses a scratch inside
            the workspace or inside the repository: a build that writes into the
            share it is reading is how a deployment share gets a mount folder in
            it forever.

            deployRoot AND contentMarker GO INTO THE IMAGE VERBATIM, including
            the volume-relative form (\Share). That form is the whole reason a
            Local boot image works on a machine whose drive letters WinPE has not
            assigned yet - SPIKES S9.1 recorded WinPE giving the content disk C:
            while the RAM disk was X: - and a builder that "helpfully" expanded
            it to the letter it sees on the build host would bake in the one
            value that is certainly wrong.

            A FAILURE AFTER THE MOUNT DISCARDS IT. DismountImage(..., $false)
            runs from the catch, so a failed build leaves no half-applied image
            mounted and no artifact on the share.

            THE ACL CHECK WARNS AND NEVER REFUSES (DESIGN 6.3). An administrator
            whose boot image build died because of an ACL check is an
            administrator who turns the check off, and then nobody is told about
            the domain admin credential either.

        .PARAMETER WorkspaceRoot
            The deployment share. workspace.yaml is read from its root and the
            artifacts are written to its Boot\ folder.

        .PARAMETER OptionalComponent
            Overrides workspace.yaml's optionalComponents for this invocation.
            An explicit empty array means the required six and nothing else.

        .PARAMETER Architecture
            Overrides workspace.yaml. amd64 or arm64.

        .PARAMETER Language
            Overrides workspace.yaml. The language pack folder, en-us by default.

        .PARAMETER SkipIso
            Build the WIM and skip the ISO. DESIGN 5.1: matching MDT's
            per-platform ISO checkbox - generating the ISO is the slow half, and
            during iteration on a WDS lab you often do not need it. The manifest
            is still written, with the ISO recorded as skipped.

        .PARAMETER PromptForCredential
            Build an image with no embedded credential (DESIGN 6.3). The booted
            machine stops for a human. Available, not the default.

        .PARAMETER PromptForKey
            Leave the "Press any key to boot from CD or DVD..." prompt in place.
            Without it the ISO is built with efisys_noprompt.bin.

        .PARAMETER Firmware
            The ISO's firmware target: UEFI (default), BIOS or Both.

        .PARAMETER ScratchPath
            Where to mount and stage. Must contain no space, and must not be
            inside the workspace or the repository. Defaults to
            C:\HDTLab\scratch\bootimage.

        .PARAMETER EngineModulePath
            The engine to stage into the image. Defaults to the RUNNING module's
            own root, so what ships is what is loaded; name another to build an
            image carrying a specific engine version.

        .PARAMETER YamlModulePath
            The powershell-yaml to stage. Resolved with Get-Module -ListAvailable
            when omitted, and REFUSED WITH A NAMED ERROR when it cannot be found:
            SPIKES S9.1 makes it the dependency the whole engine rests on inside
            WinPE.

        .PARAMETER AccessRule
            The ACL rows to judge, keyed by workspace-relative folder. Read from
            the share with Get-HDTShareAccessRule when omitted.

        .PARAMETER AdkRoot
            An explicit ADK root, which wins over the registry.

        .PARAMETER BootImageService
            An IBootImageService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Registry
            An IRegistryService, for resolving the ADK. Defaults to the real
            adapter.

        .PARAMETER Clock
            An IClock, for the build timestamp and duration. Defaults to the real
            adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with WimPath, WimSha256,
            WimSizeBytes, IsoPath, IsoSha256, IsoSizeBytes, ManifestPath,
            ComponentCount, DriverCount, DurationSecond and Skipped.

        .EXAMPLE
            Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share'

            The default build: nine optional components, the engine, the
            credential from Set-HDTShareCredential, Boot\HDTPE_x64.wim and a
            no-keypress Boot\HDTPE_x64.iso.

        .EXAMPLE
            Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share' -SkipIso

            The WIM only, for a WDS lab. About half the time.

        .EXAMPLE
            Update-HDTBootImage -WorkspaceRoot '\\HDT-HOST\HdtShare' -PromptForCredential

            An image carrying no share password - for a shared lab or media
            going offsite. The booted machine stops for a human (DESIGN 6.3).

        .EXAMPLE
            Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share' -OptionalComponent 'WinPE-FMAPI'

            The required six plus one, overriding workspace.yaml for this build.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $OptionalComponent,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Language,

        [Parameter()]
        [switch] $SkipIso,

        [Parameter()]
        [switch] $PromptForCredential,

        [Parameter()]
        [switch] $PromptForKey,

        [Parameter()]
        [ValidateSet('UEFI', 'BIOS', 'Both')]
        [string] $Firmware = 'UEFI',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScratchPath = 'C:\HDTLab\scratch\bootimage',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $EngineModulePath = $script:HDTModuleRoot,

        [Parameter()]
        [AllowEmptyString()]
        [string] $YamlModulePath = '',

        [Parameter()]
        [AllowNull()]
        [hashtable] $AccessRule,

        [Parameter()]
        [AllowEmptyString()]
        [string] $AdkRoot = '',

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
        [object] $Clock
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Registry) { $Registry = New-HDTRegistryService }
    if ($null -eq $BootImageService) { $BootImageService = New-HDTBootImageService }
    if ($null -eq $Clock) { $Clock = New-HDTClock }

    $startedUtc = $Clock.GetUtcNow()

    # =====================================================================
    # 1. THE WORKSPACE DOCUMENT
    # =====================================================================

    $workspacePath = [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml')
    $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

    $buildArchitecture = [string] $workspace.BootImage.Architecture
    if ($PSBoundParameters.ContainsKey('Architecture')) { $buildArchitecture = $Architecture }

    $buildLanguage = [string] $workspace.BootImage.Language
    if ($PSBoundParameters.ContainsKey('Language')) { $buildLanguage = $Language }

    $imageName = [string] $workspace.BootImage.Name

    # =====================================================================
    # 2. THE ADK, RESOLVED - NEVER A LITERAL
    # =====================================================================

    $adkSplat = @{
        Architecture = $buildArchitecture
        Language     = $buildLanguage
        Registry     = $Registry
        FileSystem   = $FileSystem
    }
    if (-not [string]::IsNullOrWhiteSpace($AdkRoot)) { $adkSplat['Root'] = $AdkRoot }

    $adkAsset = @(Get-HDTAdkPath -All @adkSplat)

    # What THIS build needs. Oscdimg is needed only when an ISO is being built,
    # and saying so lets a -SkipIso build run on a machine with the WinPE add-on
    # and no Deployment Tools.
    $requiredAsset = @('WinPeWim', 'WinPeMedia', 'WinPeOptionalComponent')
    if (-not $SkipIso) { $requiredAsset += 'Oscdimg' }

    $missing = @($adkAsset | Where-Object { $requiredAsset -contains $_.Name -and -not $_.Exists })

    if ($missing.Count -gt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category NotInstalled `
                    -TargetObject $missing[0].Path `
                    -Message ("the Windows ADK on this machine cannot build a boot image: {0} is missing. Install the Windows ADK Deployment Tools and the Windows PE add-on - they are separate downloads - and run Get-HDTAdkPath -All to see every asset and whether it is present." -f
                        (@($missing | ForEach-Object { "'{0}' ({1})" -f $_.Name, $_.Path }) -join ', '))))
    }

    $assetPath = @{}
    foreach ($row in $adkAsset) { $assetPath[[string] $row.Name] = [string] $row.Path }

    # =====================================================================
    # 3. THE COMPONENT PLAN
    # =====================================================================

    $componentSplat = @{
        ComponentRoot = $assetPath['WinPeOptionalComponent']
        Language      = $buildLanguage
        FileSystem    = $FileSystem
    }

    # Unset and set-to-nothing are different instructions, all the way down.
    if ($PSBoundParameters.ContainsKey('OptionalComponent')) {
        $componentSplat['OptionalComponent'] = $OptionalComponent
    } else {
        $componentSplat['OptionalComponent'] = [string[]] @($workspace.BootImage.OptionalComponent)
    }

    $component = @(Get-HDTBootImageComponent @componentSplat)

    # =====================================================================
    # 4a. THE SCRATCH PATH, JUDGED BEFORE ANYTHING IS TOUCHED
    # =====================================================================

    $scratch = $ScratchPath.TrimEnd('\', '/')

    # SPIKES S2. <scratch>\bootbits is what step 17 hands New-HDTBootIso, and
    # oscdimg's -bootdata: cannot carry a quoted path.
    if ($scratch -match '\s') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $scratch `
                    -Message ("the scratch path '{0}' contains a space. The boot bits for the ISO are staged in <scratch>\bootbits, and oscdimg's -bootdata: argument cannot carry a quoted path - SPIKES S2 verified that a quoted one arrives doubled and produces `"Could not open boot sector file`" / Error 123. A staging directory under a path with a space solves nothing. Choose a scratch path without one, such as C:\HDTLab\scratch\bootimage." -f $scratch)))
    }

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $scratchFull = [System.IO.Path]::GetFullPath($scratch).TrimEnd('\', '/')
    $separator = [System.IO.Path]::DirectorySeparatorChar

    if ($scratchFull -eq $workspaceFull -or
        $scratchFull.StartsWith(($workspaceFull + $separator), [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $scratch `
                    -Message ("the scratch path '{0}' is inside the workspace '{1}'. A build that writes into the share it is reading is how a deployment share ends up with a mount folder in it forever, and step 4 empties the scratch directories. Choose a scratch path outside the workspace." -f $scratch, $WorkspaceRoot)))
    }

    # The repository, recognised by its .git folder rather than by a literal
    # path: the module knows where it is, and a checkout is the one place a
    # developer will reflexively point a scratch directory.
    #
    # Derived from the RUNNING module's own root, not from -EngineModulePath: the
    # repository this build must not write into is the one this code is running
    # from, and a build host staging some other copy of the engine has not
    # thereby declared that copy's parent off limits.
    $repositoryRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($script:HDTModuleRoot, '..', '..')).TrimEnd('\', '/')

    if ($FileSystem.TestPath([System.IO.Path]::Combine($repositoryRoot, '.git'))) {
        if ($scratchFull -eq $repositoryRoot -or
            $scratchFull.StartsWith(($repositoryRoot + $separator), [System.StringComparison]::OrdinalIgnoreCase)) {

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $scratch `
                        -Message ("the scratch path '{0}' is inside the repository '{1}'. A boot image build mounts a WIM there and empties the directory first; neither belongs in a working tree. Choose a scratch path outside it, such as C:\HDTLab\scratch\bootimage." -f $scratch, $repositoryRoot)))
        }
    }

    $mountPath = [System.IO.Path]::Combine($scratch, 'mount')
    $mediaPath = [System.IO.Path]::Combine($scratch, 'media')
    $bitPath = [System.IO.Path]::Combine($scratch, 'bootbits')
    $scratchWim = [System.IO.Path]::Combine($scratch, ('{0}.wim' -f $imageName))

    $bootFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot
    $wimPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot -ChildPath ('{0}.wim' -f $imageName)
    $isoPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot -ChildPath ('{0}.iso' -f $imageName)
    $manifestPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot -ChildPath ('{0}.manifest.json' -f $imageName)

    # The engine and the parser, resolved and existence-checked BEFORE the mount,
    # because a build that discovers a missing dependency with a WIM mounted has
    # wasted fifteen minutes to say something it could have said immediately.
    $yamlPath = $YamlModulePath
    if ([string]::IsNullOrWhiteSpace($yamlPath)) {
        $available = @(Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue |
                Sort-Object -Property Version -Descending)

        if ($available.Count -gt 0) { $yamlPath = [string] $available[0].ModuleBase }
    }

    if ([string]::IsNullOrWhiteSpace($yamlPath) -or -not $FileSystem.TestPath($yamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category NotInstalled `
                    -TargetObject $yamlPath `
                    -Message ("powershell-yaml could not be found, so this boot image would have no YAML parser. SPIKES S9.1 proved it is the dependency the whole engine rests on inside WinPE: ConvertFrom-HDTYaml goes through it, and every document HDT reads goes through that. Run Install-Module powershell-yaml -Scope AllUsers, or pass -YamlModulePath to name a staged copy. Looked at: '{0}'." -f $yamlPath)))
    }

    $deploymentPayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Start-HDTDeployment.ps1')
    $resumePayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Start-HDTResume.ps1')

    foreach ($required in @($EngineModulePath, $deploymentPayload, $resumePayload)) {
        if (-not $FileSystem.TestPath($required)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category ObjectNotFound `
                        -TargetObject $required `
                        -Message ("the engine payload '{0}' is not there, so the boot image would have nothing to launch. The module staged into the image is the one this command is running from; if that copy is incomplete, reinstall it or pass -EngineModulePath." -f $required)))
        }
    }

    # The credential, decided before the mount for the same reason.
    $credentialUserName = ''
    $credentialProtected = ''
    $embedCredential = $false

    if (-not $PromptForCredential -and $null -ne $workspace.Credential) {
        $credentialUserName = [string] $workspace.Credential.Username

        $secretPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Control -ChildPath 'share-credential.json'

        if (-not $FileSystem.TestPath($secretPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $secretPath -Category ObjectNotFound `
                        -Message ("workspace.yaml declares the deployment account '{0}' but no secret has been written for it, so this boot image could not authenticate to the share. Run Set-HDTShareCredential, or build with -PromptForCredential if the image is meant to stop for a human (DESIGN 6.3)." -f $credentialUserName)))
        }

        $secret = Get-HDTShareCredential -WorkspaceRoot $WorkspaceRoot -FileSystem $FileSystem
        $credentialUserName = [string] $secret.UserName
        $credentialProtected = Protect-HDTShareSecret -Secret ([string] $secret.Password)
        $embedCredential = $true
    }

    # -- a share image with no embedded credential ASKS THE TECHNICIAN -------
    #
    # MDT'S LOGIC, KEPT. A Bootstrap.ini that names a DeployRoot but no UserID
    # does not fail the build - LiteTouch prompts for the credentials at the
    # start of the deployment. HDT does the same: a UNC deployRoot with no
    # embedded credential turns promptForCredential on, and the payload asks.
    #
    # An earlier version of this REFUSED the build instead. That was a rule MDT
    # does not have, and it would have made the ordinary "build the image now,
    # let the technician sign in at the machine" workflow impossible.
    #
    # It is a warning rather than silence because the two builds behave very
    # differently in front of a technician - one runs unattended, one stops -
    # and the admin should know which one they just made.

    $promptForCredentialEffective = [bool] $PromptForCredential

    if (-not $embedCredential -and -not $promptForCredentialEffective -and
        ([string] $workspace.DeployRoot).StartsWith('\\')) {

        $promptForCredentialEffective = $true

        Write-Warning ("deployRoot '{0}' is a share and no credential is embedded, so this image will ASK THE TECHNICIAN for the deployment account when it boots - MDT's behaviour when Bootstrap.ini carries no UserID. To make it run unattended instead, declare the account in workspace.yaml's credential block and write its secret with Set-HDTShareCredential (DESIGN 6.3)." -f
            [string] $workspace.DeployRoot)
    }

    # -- extraContent, resolved and judged before the mount ------------------

    $extraContentPlan = New-Object -TypeName System.Collections.ArrayList
    $mountFull = [System.IO.Path]::GetFullPath($mountPath).TrimEnd('\', '/')

    foreach ($entry in @($workspace.BootImage.ExtraContent)) {
        $source = [System.IO.Path]::Combine($WorkspaceRoot, ([string] $entry.Source).TrimStart('\', '/'))
        $destination = [System.IO.Path]::Combine($mountPath, ([string] $entry.Destination).TrimStart('\', '/'))
        $destinationFull = [System.IO.Path]::GetFullPath($destination).TrimEnd('\', '/')

        if ($destinationFull -ne $mountFull -and
            -not $destinationFull.StartsWith(($mountFull + $separator), [System.StringComparison]::OrdinalIgnoreCase)) {

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $entry.Destination `
                        -Message ("the extraContent destination '{0}' would escape the boot image and write to '{1}' on the build host. A destination inside the image is a path under its root; '..' does not belong in one." -f $entry.Destination, $destinationFull)))
        }

        [void] $extraContentPlan.Add([pscustomobject] @{
                Source      = $source
                Destination = $destination
                Declared    = [string] $entry.Destination
            })
    }

    # =====================================================================
    # 4b. THE SCRATCH DIRECTORIES - the first thing that writes
    # =====================================================================

    $description = 'Build boot image {0} ({1} component(s))' -f $imageName, $component.Count

    if (-not $PSCmdlet.ShouldProcess($wimPath, $description)) {
        return [pscustomobject] @{
            WimPath        = $wimPath
            WimSha256      = ''
            WimSizeBytes   = [long] 0
            IsoPath        = ''
            IsoSha256      = ''
            IsoSizeBytes   = [long] 0
            ManifestPath   = $manifestPath
            ComponentCount = $component.Count
            DriverCount    = 0
            DurationSecond = [double] 0
            Skipped        = [string[]] @()
        }
    }

    foreach ($folder in @($mountPath, $mediaPath, $bitPath)) {
        $FileSystem.RemoveItem($folder, $true)
        $FileSystem.CreateDirectory($folder)
    }

    # =====================================================================
    # 5. THE SOURCE WIM
    # =====================================================================

    $FileSystem.RemoveItem($scratchWim, $false)
    $FileSystem.CopyItem($assetPath['WinPeWim'], $scratchWim)

    # =====================================================================
    # 6. THE MEDIA TREE
    # =====================================================================

    [void] (Copy-HDTContentTree -Source $assetPath['WinPeMedia'] -Destination $mediaPath -FileSystem $FileSystem)

    # The WinPE Media template has no sources\ folder; the build creates it and
    # step 16 puts the exported WIM there as boot.wim.
    $mediaSources = [System.IO.Path]::Combine($mediaPath, 'sources')
    $FileSystem.CreateDirectory($mediaSources)

    # =====================================================================
    # 7-15. THE MOUNT. Everything from here is inside a try that discards it.
    # =====================================================================

    $mounted = $false
    $driver = @()
    $payloadRow = New-Object -TypeName System.Collections.ArrayList
    $extraRow = New-Object -TypeName System.Collections.ArrayList
    # An empty EntryCommand means the workspace did not say, so the default in
    # Get-HDTStartnetScript's parameter decides. Passing the empty string through
    # would trip its ValidateNotNullOrEmpty and turn "did not say" into an error.
    $startnet = if ([string]::IsNullOrWhiteSpace([string] $workspace.BootImage.EntryCommand)) {
        Get-HDTStartnetScript
    } else {
        Get-HDTStartnetScript -Command ([string] $workspace.BootImage.EntryCommand)
    }

    try {
        # -- 7. mount -------------------------------------------------------

        $BootImageService.MountImage($scratchWim, 1, $mountPath)
        $mounted = $true

        # -- 8. the components, each followed by its language pack -----------
        #
        # DESIGN 5.1: "Each component's matching en-us pack is applied
        # immediately after it, where one exists." The empty LanguageCabPath is
        # Get-HDTBootImageComponent's answer for the twelve components in this
        # ADK that ship none.

        foreach ($row in $component) {
            $BootImageService.AddPackage($mountPath, [string] $row.CabPath)

            if (-not [string]::IsNullOrWhiteSpace([string] $row.LanguageCabPath)) {
                $BootImageService.AddPackage($mountPath, [string] $row.LanguageCabPath)
            }
        }

        # -- 9. scratch space ------------------------------------------------

        $BootImageService.SetScratchSpace($mountPath, [int] $workspace.BootImage.ScratchSpaceMB)

        # -- 10. the boot driver group ---------------------------------------
        #
        # Boot images get network and storage drivers only, never the whole
        # driver store. A group that is not there WARNS AND CONTINUES: M5 owns
        # the driver store, and a boot image build must not be blocked by a
        # folder nobody has imported into yet.

        $driverGroup = [string] $workspace.BootImage.Drivers

        if (-not [string]::IsNullOrWhiteSpace($driverGroup)) {
            $driverPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Drivers -ChildPath $driverGroup

            if ($FileSystem.TestPath($driverPath)) {
                $driver = @($BootImageService.AddDriver($mountPath, $driverPath, $true))
            } else {
                Write-Warning ("The boot driver group '{0}' is declared in workspace.yaml but there is nothing at '{1}', so no drivers were injected. Import drivers into that folder, or remove the drivers: key." -f $driverGroup, $driverPath)
            }
        }

        # -- 11. the engine ---------------------------------------------------
        #
        # Payload\ IS EXCLUDED FROM THE MODULE TREE and staged to X:\HDT\
        # instead. startnet.cmd launches X:\HDT\Start-HDTDeployment.ps1; a second
        # copy under Modules\Hephaestus\Payload\ would be a second answer to
        # "which one is running".

        $hdtRoot = [System.IO.Path]::Combine($mountPath, 'HDT')
        $moduleRoot = [System.IO.Path]::Combine($hdtRoot, 'Modules')
        $engineDestination = [System.IO.Path]::Combine($moduleRoot, 'Hephaestus')
        $yamlDestination = [System.IO.Path]::Combine($moduleRoot, 'powershell-yaml')

        $FileSystem.CreateDirectory($engineDestination)

        $engineFileCount = 0
        foreach ($child in @($FileSystem.GetChildItem($EngineModulePath))) {
            $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            # Payload\ AND UI\ ARE BOTH EXCLUDED FROM THE MODULE TREE and
            # staged to X:\HDT\ instead. A second copy under
            # Modules\Hephaestus\ would be a second answer to "where is the
            # wizard", and the one startnet.cmd does not use.
            if (@('Payload', 'UI') -contains $leaf) { continue }

            $target = [System.IO.Path]::Combine($engineDestination, $leaf)

            $isFile = $true
            try { [void] $FileSystem.GetLength($child) } catch { $isFile = $false }

            if ($isFile) {
                $FileSystem.CopyItem($child, $target)
                $engineFileCount++
                continue
            }

            $engineFileCount += Copy-HDTContentTree -Source $child -Destination $target -FileSystem $FileSystem
        }

        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Modules\Hephaestus'
                Source      = $EngineModulePath
                FileCount   = $engineFileCount
                SizeBytes   = [long] 0
            })

        $yamlFileCount = Copy-HDTContentTree -Source $yamlPath -Destination $yamlDestination -FileSystem $FileSystem

        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Modules\powershell-yaml'
                Source      = $yamlPath
                FileCount   = $yamlFileCount
                SizeBytes   = [long] 0
            })

        # -- the wizard UI ---------------------------------------------------
        #
        # W1 of the WPF-first direction. The window lives at X:\HDT\UI\ because
        # X: is the RAM disk and its letter is fixed - the same reason the
        # payloads are there. An image with no UI\ folder on the build host is
        # not an error: the engine deploys perfectly well without a technician
        # window, and DESIGN's unattended path must not start requiring one.

        $uiSource = [System.IO.Path]::Combine($EngineModulePath, 'UI')

        if ($FileSystem.TestPath($uiSource)) {
            $uiDestination = [System.IO.Path]::Combine($hdtRoot, 'UI')
            $uiFileCount = Copy-HDTContentTree -Source $uiSource -Destination $uiDestination -FileSystem $FileSystem

            [void] $payloadRow.Add([pscustomobject] @{
                    Destination = '\HDT\UI'
                    Source      = $uiSource
                    FileCount   = $uiFileCount
                    SizeBytes   = [long] 0
                })
        }

        $FileSystem.CopyItem($deploymentPayload, [System.IO.Path]::Combine($hdtRoot, 'Start-HDTDeployment.ps1'))
        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Start-HDTDeployment.ps1'
                Source      = $deploymentPayload
                FileCount   = 1
                SizeBytes   = [long] 0
            })

        # The full-OS leg is staged FROM the boot image TO the target, so it has
        # to be in the boot image even though nothing in WinPE runs it.
        $FileSystem.CopyItem($resumePayload, [System.IO.Path]::Combine($hdtRoot, 'Start-HDTResume.ps1'))
        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Start-HDTResume.ps1'
                Source      = $resumePayload
                FileCount   = 1
                SizeBytes   = [long] 0
            })

        # -- 12. bootstrap.json ----------------------------------------------
        #
        # deployRoot GOES IN VERBATIM. See the header: a builder that expanded
        # \Share to the letter it sees here would bake in the one value that is
        # certainly wrong.

        $buildId = [guid]::NewGuid().ToString()
        $builtUtc = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

        $provider = 'Local'
        if (([string] $workspace.DeployRoot).StartsWith('\\')) { $provider = 'Smb' }

        # AN UNSTATED SHARE IS OMITTED, NOT WRITTEN EMPTY - the same rule the
        # skip block below follows. A deployRoot of "" in the file reads as a
        # share somebody meant to set and got wrong; the key's absence reads as
        # an image that means to ask, which is what the Welcome screen's hint
        # then does.
        $bootstrap = [ordered] @{
            schemaVersion       = 1
            workspaceId         = [string] $workspace.Id
            provider            = $provider
            contentMarker       = 'rules.yaml'
            sequenceId          = ''
            promptForCredential = [bool] $promptForCredentialEffective
            logLevel            = [string] $workspace.LogLevel
            buildId             = $buildId
            builtUtc            = $builtUtc
        }

        if (-not [string]::IsNullOrWhiteSpace([string] $workspace.DeployRoot)) {
            $bootstrap['deployRoot'] = [string] $workspace.DeployRoot
        }

        # THE SKIP BLOCK, WRITTEN ONLY FOR RULES THE WORKSPACE ACTUALLY STATED.
        #
        # MDT's Bootstrap.ini carries SkipBDDWelcome for a structural reason:
        # the Welcome screen runs BEFORE the share is reachable, so a rule about
        # it cannot live on the share (.planning/WPF-FIRST.md, W2). This is the
        # in-image half of that split.
        #
        # AN UNSTATED RULE IS OMITTED, NOT WRITTEN AS false. Get-HDTWizardSkip's
        # defaults are what turn "the image said nothing" into the unattended
        # path, and writing false here would silently move that decision to
        # build time - where the machine's promptForCredential is not yet known
        # to whoever is reading the file.
        $skipStated = [ordered] @{}

        foreach ($pair in @(
                @{ Key = 'welcome'; Property = 'SkipWelcome' },
                @{ Key = 'staticIp'; Property = 'SkipStaticIp' },
                @{ Key = 'deployRoot'; Property = 'SkipDeployRoot' },
                @{ Key = 'credential'; Property = 'SkipCredential' })) {

            $property = [string] $pair.Property
            if ($null -eq $workspace.BootImage.PSObject.Properties[$property]) { continue }
            if ($null -eq $workspace.BootImage.$property) { continue }

            $skipStated[[string] $pair.Key] = [bool] $workspace.BootImage.$property
        }

        if ($skipStated.Count -ge 1) { $bootstrap['skip'] = $skipStated }

        if ($embedCredential) {
            $bootstrap['credential'] = [ordered] @{
                username  = $credentialUserName
                protected = $credentialProtected
            }
        }

        $FileSystem.WriteAllText([System.IO.Path]::Combine($hdtRoot, 'bootstrap.json'),
            (ConvertTo-Json -InputObject $bootstrap -Depth 4))

        # -- 13. startnet.cmd -------------------------------------------------

        $FileSystem.WriteAllText(
            [System.IO.Path]::Combine($mountPath, 'Windows', 'System32', 'startnet.cmd'), $startnet)

        # -- 14. extraContent --------------------------------------------------

        foreach ($entry in $extraContentPlan) {
            $count = Copy-HDTContentTree -Source $entry.Source -Destination $entry.Destination -FileSystem $FileSystem

            [void] $extraRow.Add([pscustomobject] @{
                    Source      = [string] $entry.Source
                    Destination = [string] $entry.Declared
                    FileCount   = [int] $count
                })
        }

        # -- 15. the share ACL - warn, never refuse (DESIGN 6.3) --------------

        if (-not [string]::IsNullOrWhiteSpace($credentialUserName)) {
            $rule = $AccessRule

            if ($null -eq $rule) {
                $rule = @{}
                $rule['.'] = Get-HDTShareAccessRule -Path $WorkspaceRoot

                foreach ($kind in @('Logs', 'Captures', 'Boot', 'Control', 'Drivers',
                        'OperatingSystems', 'Applications', 'TaskSequences', 'Scripts', 'Modules')) {
                    $rule[$kind] = Get-HDTShareAccessRule -Path (Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind $kind)
                }
            }

            $judgement = Test-HDTShareAcl -WorkspaceRoot $WorkspaceRoot -Identity $credentialUserName -AccessRule $rule

            foreach ($finding in @($judgement.Finding)) {
                if ([string] $finding.Severity -eq 'Information') { continue }

                Write-Warning ("Share ACL ({0}): {1}" -f $finding.Severity, $finding.Message)
            }
        }

        # -- 16. commit, export, and the copy that IS DESIGN 6.1.1 ------------

        $BootImageService.DismountImage($mountPath, $true)
        $mounted = $false
    } catch {
        # A FAILURE AFTER THE MOUNT DISCARDS IT. Without this the machine is left
        # with a mounted image and the next build cannot mount over it.
        if ($mounted) {
            $BootImageService.DismountImage($mountPath, $false)
            $mounted = $false
        }

        throw
    }

    $FileSystem.CreateDirectory($bootFolder)
    $FileSystem.RemoveItem($wimPath, $false)
    $BootImageService.ExportImage($scratchWim, 1, $wimPath)

    # ONE FILE, TWO HOMES, SAME BYTES. The ISO is built from the exported WIM,
    # not from a second export - DESIGN 6.1.1's mechanism, and the reason the
    # manifest can record isoBootWimSha256 as a fact rather than a hope.
    $mediaBootWim = [System.IO.Path]::Combine($mediaSources, 'boot.wim')
    $FileSystem.CopyItem($wimPath, $mediaBootWim)

    $wimSha256 = [string] $FileSystem.GetHash($wimPath)
    $wimSize = [long] $FileSystem.GetLength($wimPath)

    # =====================================================================
    # 17. THE ISO, THEN THE MANIFEST - LAST
    # =====================================================================

    $skipped = New-Object -TypeName System.Collections.ArrayList

    $isoResultPath = ''
    $isoSha256 = ''
    $isoSize = [long] 0
    $isoBootWimSha256 = ''

    if ($SkipIso) {
        [void] $skipped.Add('Iso')
    } else {
        $isoSplat = @{
            MediaRoot        = $mediaPath
            Path             = $isoPath
            BootBitPath      = $bitPath
            Firmware         = $Firmware
            Architecture     = $buildArchitecture
            BootImageService = $BootImageService
            FileSystem       = $FileSystem
            Registry         = $Registry
            Confirm          = $false
        }
        if (-not [string]::IsNullOrWhiteSpace($AdkRoot)) { $isoSplat['AdkRoot'] = $AdkRoot }

        # DESIGN 5.2: -NoPromptForKey is ON when Update-HDTBootImage invokes
        # New-HDTBootIso, because a boot image you mount to test something should
        # just boot.
        if (-not $PromptForKey) { $isoSplat['NoPromptForKey'] = $true }

        $iso = New-HDTBootIso @isoSplat

        $isoResultPath = [string] $iso.Path
        $isoSha256 = [string] $iso.Sha256
        $isoSize = [long] $iso.SizeBytes
        $isoBootWimSha256 = [string] $FileSystem.GetHash($mediaBootWim)
    }

    $finishedUtc = $Clock.GetUtcNow()

    $manifestText = New-HDTBootImageManifest -BuildId $buildId -BuiltUtc $builtUtc -BuiltOn $env:COMPUTERNAME `
        -EngineVersion (Get-HDTModuleVersion) -WorkspaceId ([string] $workspace.Id) `
        -Architecture $buildArchitecture -Language $buildLanguage `
        -Adk @{
        Root     = $assetPath['Root']
        Oscdimg  = $assetPath['Oscdimg']
        WinPeWim = $assetPath['WinPeWim']
    } `
        -Component ([object[]] @($component)) -Driver ([object[]] @($driver)) `
        -Payload ([object[]] @($payloadRow)) -ExtraContent ([object[]] @($extraRow)) `
        -Startnet $startnet `
        -CredentialRecord @{
        Username            = $credentialUserName
        Embedded            = $embedCredential
        PromptForCredential = [bool] $PromptForCredential
    } `
        -Wim @{ Path = $wimPath; Sha256 = $wimSha256; SizeBytes = $wimSize } `
        -Iso @{
        Path           = $isoResultPath
        Sha256         = $isoSha256
        SizeBytes      = $isoSize
        Firmware       = $Firmware
        NoPromptForKey = (-not $PromptForKey)
        Skipped        = [bool] $SkipIso
    } `
        -IsoBootWimSha256 $isoBootWimSha256

    # LAST, so a manifest that exists describes a build that finished.
    $FileSystem.WriteAllText($manifestPath, $manifestText)

    return [pscustomobject] @{
        WimPath        = $wimPath
        WimSha256      = $wimSha256
        WimSizeBytes   = $wimSize
        IsoPath        = $isoResultPath
        IsoSha256      = $isoSha256
        IsoSizeBytes   = $isoSize
        ManifestPath   = $manifestPath
        ComponentCount = $component.Count
        DriverCount    = @($driver).Count
        DurationSecond = [double] ($finishedUtc - $startedUtc).TotalSeconds
        Skipped        = [string[]] @($skipped)
    }
}
