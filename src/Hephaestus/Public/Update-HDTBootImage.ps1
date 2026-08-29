function Update-HDTBootImage {
    <#
        .SYNOPSIS
            Builds the HDT boot image: one mount, two artifacts, and a manifest
            saying exactly what went into them.

        .DESCRIPTION
            One build produces two artifacts from the same source ... Both come
            from a single mount/inject/commit cycle. They are never built
            separately, so the ISO you debug with is byte-for-byte the WinPE you
            PXE boot - which is the entire point of having it. One command for
            the whole share is the shape MDT's Update-MDTDeploymentShare set.

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
              13  write startnet.cmd - wpeinit, the workspace's startCommand
                  list, then the entry command
             13b  copy the WinPE answer file to \Unattend.xml, if one is named
              14  copy extraContent
              15  check the share ACL and warn
              16  dismount saving, export, and COPY the exported WIM into the
                  media tree
              17  build the ISO, then write the manifest LAST

            STEP 16'S COPY IS THE WHOLE HASH-IDENTITY GUARANTEE. The ISO is built from
            the exported WIM copied into the media tree, not from a second
            export. One file, two homes, same bytes - and the manifest records
            isoBootWimSha256 so an operator can check that without this test
            suite.

            STEP 4 REFUSES A SCRATCH PATH WITH A SPACE IN IT, and that is a
            lab-proven limit rather than fussiness: <scratch>\bootbits is what step 17 hands
            New-HDTBootIso as -BootBitPath, oscdimg's -bootdata: cannot take a
            quoted path, and a space-free staging directory that is itself under
            a path with a space solves nothing. It also refuses a scratch inside
            the workspace or inside the repository: a build that writes into the
            share it is reading is how a deployment share gets a mount folder in
            it forever.

            deployRoot AND contentMarker GO INTO THE IMAGE VERBATIM, including
            the volume-relative form (\Share). That form is the whole reason a
            Local boot image works on a machine whose drive letters WinPE has not
            assigned yet - a lab test recorded WinPE giving the content disk C:
            while the RAM disk was X: - and a builder that "helpfully" expanded
            it to the letter it sees on the build host would bake in the one
            value that is certainly wrong.

            A FAILURE AFTER THE MOUNT DISCARDS IT. DismountImage(..., $false)
            runs from the catch, so a failed build leaves no half-applied image
            mounted and no artifact on the share.

            THE ACL CHECK WARNS AND NEVER REFUSES. An administrator
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

        .PARAMETER PerDriver
            Inject the boot drivers one .inf at a time, so the build reports
            each by name as it goes in. Off by default and for a measured
            reason: the lab's seventy-driver Dell WinPE pack takes 7 minutes
            this way against 56 seconds handed to DISM as one folder. Turn it on
            when a machine has booted without its network card and the question
            is which drivers actually went in.

        .PARAMETER SkipIso
            Build the WIM and skip the ISO - generating the ISO is the slow
            half, and during iteration on a WDS lab you often do not need it.
            The manifest is still written, with the ISO recorded as skipped.

        .PARAMETER PromptForCredential
            Build an image with no embedded credential. The booted
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
            It is the dependency the whole engine rests on inside
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

        .PARAMETER Progress
            Where the seventeen steps are reported, from New-HDTBuildProgress.
            Defaults to a sink that records nothing, which is what every caller
            that is not a window wants.

            EVERY STEP IS REPORTED BEFORE IT IS TAKEN, not after. A mount is
            tens of seconds and the export is longer; a watcher still showing
            the previous step's text through all of it is a watcher somebody
            decides has stuck.

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
            going offsite. The booted machine stops for a human.

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

        # SEVEN MINUTES INSTEAD OF ONE, DELIBERATELY. Measured on the lab's Dell
        # WinPE pack: seventy drivers injected one .inf at a time took 7m against
        # 56s for the same seventy handed to DISM as one folder. A build has no
        # business being seven times slower by default, so this is off - and the
        # progress bar sweeps during the silent minute instead, which is what
        # says "working" (Get-HDTConsoleBuildBusy).
        #
        # IT IS WORTH HAVING FOR THE BUILD THAT GOES WRONG. When a machine boots
        # without its network card, "which of these seventy drivers actually went
        # in" is the question, and this is the only thing that answers it.
        [Parameter()]
        [switch] $PerDriver,

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
        [object] $Clock,

        # WHERE THE SEVENTEEN STEPS ARE REPORTED. Omitted, they go to a sink
        # that records nothing - which is what every caller that is not a window
        # wants, and costs one method call per step.
        #
        # It exists because this command was SILENT for two and a half minutes
        # between its ShouldProcess and its result. A window that greys out for
        # that long reads as one that has hung, so it gets killed - and a killed
        # build strands a mounted image that needs dism /cleanup-wim before
        # anything can build again.
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
    # THE BUILD LOG, AND ONLY WHEN THIS COMMAND OWNS THE SINK. A caller that
    # passed -Progress is the console, which renders these into a window and
    # writes its own file; giving it a second writer would put two things on one
    # path. A bare command line has neither, and had nothing to read afterwards.
    #
    # THE NAME IS READ AHEAD OF STEP 1 rather than after it, because the log has
    # to exist for the failure that happens BEFORE the document is understood.
    # Get-HDTConsoleBuildLogPath falls back to bootimage.build.log for exactly
    # that case, so an unreadable workspace still leaves a log saying so.
    $buildLogName = ''
    try {
        $buildLogName = [string] (Import-HDTWorkspaceDocument -Path (
                [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml')) -FileSystem $FileSystem).BootImage.Name
    } catch {
        Write-Verbose ("the boot image name could not be read for the build log: {0}" -f $_.Exception.Message)
    }

    $buildLogPath = ''
    try {
        $buildLogPath = [string] (Get-HDTConsoleBuildLogPath -WorkspaceRoot $WorkspaceRoot -Name $buildLogName)
    } catch {
        Write-Verbose ("the build log path could not be worked out: {0}" -f $_.Exception.Message)
    }

    if ($null -eq $Progress) { $Progress = New-HDTBuildProgress -LogPath $buildLogPath -FileSystem $FileSystem }

    # ONE NUMBER, IN ONE PLACE. The step count is what a progress bar divides
    # by, and a total that disagreed with the number of reports would show a bar
    # that never reaches the end - or reaches it early and then keeps going.
    $stepTotal = 17

    $startedUtc = $Clock.GetUtcNow()

    # =====================================================================
    # 1. THE WORKSPACE DOCUMENT
    # =====================================================================

    $Progress.Report(1, $stepTotal, 'Reading the workspace document', $WorkspaceRoot)

    $workspacePath = [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml')
    $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

    $buildArchitecture = [string] $workspace.BootImage.Architecture
    if ($PSBoundParameters.ContainsKey('Architecture')) { $buildArchitecture = $Architecture }

    $buildLanguage = [string] $workspace.BootImage.Language
    if ($PSBoundParameters.ContainsKey('Language')) { $buildLanguage = $Language }

    $imageName = [string] $workspace.BootImage.Name

    # WHETHER THE ISO STOPS AT "Press any key to boot from CD or DVD", DECIDED
    # ONCE AND HERE - the manifest records it even when -SkipIso means no ISO is
    # built, so it cannot be worked out inside the block that builds one.
    #
    # THE SWITCH WINS OVER THE SHARE. workspace.yaml's promptForKey is what an
    # administrator sets in the console for every build of this image;
    # -PromptForKey is what somebody types for THIS build. A setting is a
    # default; an argument is an instruction.
    $wantPrompt = [bool] $workspace.BootImage.PromptForKey
    if ($PSBoundParameters.ContainsKey('PromptForKey')) { $wantPrompt = [bool] $PromptForKey }

    # =====================================================================
    # 2. THE ADK, RESOLVED - NEVER A LITERAL
    # =====================================================================

    $Progress.Report(2, $stepTotal, 'Resolving the Windows ADK', '')

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

    $Progress.Report(3, $stepTotal, 'Planning the optional components', '')

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

    $Progress.Report(4, $stepTotal, 'Checking the scratch path', $ScratchPath)

    $scratch = $ScratchPath.TrimEnd('\', '/')

    # SPIKES S2. <scratch>\bootbits is what step 17 hands New-HDTBootIso, and
    # oscdimg's -bootdata: cannot carry a quoted path.
    if ($scratch -match '\s') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $scratch `
                    -Message ("the scratch path '{0}' contains a space. The boot bits for the ISO are staged in <scratch>\bootbits, and oscdimg's -bootdata: argument cannot carry a quoted path - a quoted one arrives doubled and produces `"Could not open boot sector file`" / Error 123. A staging directory under a path with a space solves nothing. Choose a scratch path without one, such as C:\HDTLab\scratch\bootimage." -f $scratch)))
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

    # CAN THIS BUILD WRITE WHAT IT IS ABOUT TO BUILD? Asked HERE, before the
    # mount, for the same reason the dependency checks below are: a build that
    # finds out at the end has already spent three minutes, and it finds out by
    # failing over a half-written pair of artifacts.
    #
    # A VM HOLDING THE ISO IS THE CASE THIS CATCHES, and it is the common one in
    # a lab - the machine you are testing the image on has it in its DVD drive.
    # The probe writes and removes each staging name: same folder, same volume,
    # same permissions as the artifacts themselves.
    # PARENTHESISED, EACH ONE. @($a + '.new', $b + '.new') parses as
    # $a + @('.new', $b) + '.new' - one concatenated string, and the probe then
    # tries to write a path made of both artifacts joined by a space.
    foreach ($probePath in @(($wimPath + '.new'), ($isoPath + '.new'))) {
        try {
            $FileSystem.WriteAllText($probePath, 'hdt')
            $FileSystem.RemoveItem($probePath, $false)
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $probePath -Category WriteError `
                        -Message ("'{0}' cannot be written, so this build would mount a WIM for several minutes and then fail with nowhere to put the result: {1}. In a lab the usual cause is a virtual machine holding the ISO in its DVD drive - shut it down, or point -ScratchPath and the share elsewhere." -f
                            $probePath, $_.Exception.Message)))
        }
    }

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
                    -Message ("powershell-yaml could not be found, so this boot image would have no YAML parser. It is the dependency the whole engine rests on inside WinPE: ConvertFrom-HDTYaml goes through it, and every document HDT reads goes through that. Run Install-Module powershell-yaml -Scope AllUsers, or pass -YamlModulePath to name a staged copy. Looked at: '{0}'." -f $yamlPath)))
    }

    $deploymentPayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Start-HDTDeployment.ps1')
    $resumePayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Start-HDTResume.ps1')
    $certificatePayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Import-HDTBootCertificate.ps1')

    # THE DELETER TRAVELS WITH THE RESUME AGENT, for the same reason and by the
    # same route: it is staged from the boot image onto the target's C:\HDT, and
    # it is what removes that folder once the deployment is finished. An image
    # without it deploys machines that keep the engine and the share credential.
    $removalPayload = [System.IO.Path]::Combine($EngineModulePath, 'Payload', 'Remove-HDTAgentTree.ps1')

    foreach ($required in @($EngineModulePath, $deploymentPayload, $resumePayload, $certificatePayload, $removalPayload)) {
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
                        -Message ("workspace.yaml declares the deployment account '{0}' but no secret has been written for it, so this boot image could not authenticate to the share. Run Set-HDTShareCredential, or build with -PromptForCredential if the image is meant to stop for a human." -f $credentialUserName)))
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

        Write-Warning ("deployRoot '{0}' is a share and no credential is embedded, so this image will ASK THE TECHNICIAN for the deployment account when it boots - MDT's behaviour when Bootstrap.ini carries no UserID. To make it run unattended instead, declare the account in workspace.yaml's credential block and write its secret with Set-HDTShareCredential." -f
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

    # -- the WinPE answer file, resolved and judged before the mount ---------
    #
    # IT LANDS AT THE ROOT OF THE IMAGE, as \Unattend.xml, which is X:\ once the
    # machine has booted. wpeinit will take a path anywhere, but the root is
    # where Microsoft's own documentation puts it and where somebody debugging
    # a boot will look first.
    #
    # A MISSING FILE IS REFUSED HERE RATHER THAN AT THE COPY, because the copy
    # happens after the mount: failing then costs a mount, a discard and the
    # minutes both take, to say something that was knowable before any of it.

    $unattendSource = ''
    $unattendInImage = ''

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.Unattend)) {
        $unattendDeclared = [string] $workspace.BootImage.Unattend

        # ROOTED IS TAKEN AS WRITTEN, RELATIVE IS READ FROM THE SHARE. The
        # answer file is whatever the administrator browsed to, which is
        # frequently a folder on the build host and not share content at all.
        #
        # IsPathRooted RATHER THAN TrimStart. Trimming the leading separators
        # and combining - the idiom extraContent uses - turns
        # \\server\share\Unattend.xml into a share-relative server\share\...,
        # which is a UNC silently read from the wrong place.
        $unattendSource = $unattendDeclared

        if (-not [System.IO.Path]::IsPathRooted($unattendDeclared)) {
            $unattendSource = [System.IO.Path]::Combine($WorkspaceRoot, $unattendDeclared)
        }

        if (-not $FileSystem.TestPath($unattendSource)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $unattendSource `
                        -Message ("the WinPE answer file '{0}' is named in workspace.yaml and is not at '{1}'. An image built without it would boot with none and say nothing about why the firewall setting did not take." -f
                            $unattendDeclared, $unattendSource)))
        }

        $unattendInImage = 'X:\Unattend.xml'
    }

    # -- the certificates, resolved and judged before the mount --------------
    #
    # SAME RULES AS THE ANSWER FILE - rooted is taken as written, relative is
    # read from the share, a named file that is not there is refused before
    # anything is mounted - plus the one rule that is only about certificates:
    # A CLIENT CERTIFICATE WITH NO PASSWORD IS REFUSED HERE. A .pfx will not
    # import without one, and an image built anyway boots, fails to
    # authenticate, gets no address and looks exactly like a broken share.
    # Fifteen minutes of build to learn that is fifteen minutes too many.

    $certificateSource = New-Object -TypeName System.Collections.ArrayList

    foreach ($declared in @($workspace.BootImage.RootCertificate)) {
        $source = [string] $declared

        if (-not [System.IO.Path]::IsPathRooted($source)) {
            $source = [System.IO.Path]::Combine($WorkspaceRoot, $source)
        }

        if (-not $FileSystem.TestPath($source)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $source -Category ObjectNotFound `
                        -Message ("the certificate '{0}' is named in workspace.yaml and is not at '{1}'. An image built without it would boot trusting nothing of yours, and say nothing about why an HTTPS endpoint was unreachable." -f
                            $declared, $source)))
        }

        [void] $certificateSource.Add([pscustomobject] @{
                Source = $source
                Leaf   = [System.IO.Path]::GetFileName($source)
                Store  = 'Root'
            })
    }

    $clientCertificateSource = ''
    $clientCertificateLeaf = ''
    $certificateProtected = ''

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.ClientCertificate)) {
        $clientDeclared = [string] $workspace.BootImage.ClientCertificate
        $clientCertificateSource = $clientDeclared

        if (-not [System.IO.Path]::IsPathRooted($clientDeclared)) {
            $clientCertificateSource = [System.IO.Path]::Combine($WorkspaceRoot, $clientDeclared)
        }

        if (-not $FileSystem.TestPath($clientCertificateSource)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $clientCertificateSource -Category ObjectNotFound `
                        -Message ("the machine certificate '{0}' is named in workspace.yaml and is not at '{1}'. An image built without it cannot authenticate to a network that asks it to." -f
                            $clientDeclared, $clientCertificateSource)))
        }

        $clientCertificateLeaf = [System.IO.Path]::GetFileName($clientCertificateSource)

        $certificatePassword = Get-HDTBootImageCertificatePassword -WorkspaceRoot $WorkspaceRoot -FileSystem $FileSystem

        if ([string]::IsNullOrEmpty($certificatePassword)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $clientCertificateSource `
                        -Message ("workspace.yaml names the machine certificate '{0}' and no password has been written for it, so it could not be imported on the machine that boots this image. Run Set-HDTBootImageCertificatePassword." -f
                            $clientDeclared)))
        }

        $certificateProtected = Protect-HDTShareSecret -Secret $certificatePassword
    }

    # -- the WinPE background, resolved and judged before the mount ----------
    #
    # SAME RULES AS THE ANSWER FILE: rooted is taken as written, relative is
    # read from the share, and a named file that is not there is refused before
    # anything is mounted rather than after.

    $backgroundSource = ''

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.Background)) {
        $backgroundDeclared = [string] $workspace.BootImage.Background
        $backgroundSource = $backgroundDeclared

        if (-not [System.IO.Path]::IsPathRooted($backgroundDeclared)) {
            $backgroundSource = [System.IO.Path]::Combine($WorkspaceRoot, $backgroundDeclared)
        }

        if (-not $FileSystem.TestPath($backgroundSource)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $backgroundSource `
                        -Message ("the WinPE background '{0}' is named in workspace.yaml and is not at '{1}'." -f
                            $backgroundDeclared, $backgroundSource)))
        }
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

    $Progress.Report(5, $stepTotal, 'Copying the source WinPE image', $scratchWim)

    $FileSystem.RemoveItem($scratchWim, $false)
    $FileSystem.CopyItem($assetPath['WinPeWim'], $scratchWim)

    # =====================================================================
    # 6. THE MEDIA TREE
    # =====================================================================

    $Progress.Report(6, $stepTotal, 'Copying the ADK media tree', $mediaPath)

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
    #
    # The start commands are the OTHER half of extraContent: step 14 copies a
    # tool into the image and nothing there starts it. They go in whatever the
    # entry command is - a diagnostic image wants its background too.
    $startnetSplat = @{ StartCommand = [string[]] @($workspace.BootImage.StartCommand) }

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.EntryCommand)) {
        $startnetSplat['Command'] = [string] $workspace.BootImage.EntryCommand
    }

    # The answer file is wpeinit's argument, not a line of its own - so it goes
    # into the same call that writes the rest of startnet.cmd.
    if (-not [string]::IsNullOrWhiteSpace($unattendInImage)) {
        $startnetSplat['UnattendPath'] = $unattendInImage
    }

    # THE ONE LINE THAT GOES BEFORE wpeinit, and only when there is something
    # for it to import. See Get-HDTStartnetScript: a machine certificate that
    # arrives after the network came up has missed what it was carried for.
    if (@($certificateSource).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($clientCertificateSource)) {
        $startnetSplat['CertificateScript'] = 'X:\HDT\Import-HDTBootCertificate.ps1'
    }

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.TimeZone)) {
        $startnetSplat['TimeZone'] = [string] $workspace.BootImage.TimeZone
    }

    $startnet = Get-HDTStartnetScript @startnetSplat

    try {
        # -- 7. mount -------------------------------------------------------
        #
        # REPORTED BEFORE IT HAPPENS, like every other step: a mount is tens of
        # seconds, and a window still showing the PREVIOUS step's text for all
        # of it is a window somebody decides has stuck.

        # THE DETAIL SAYS WHAT IS BEING MOUNTED AND THAT IT IS SLOW. DISM gives
        # this adapter no sub-progress to pass on - it is one call that returns
        # when it is done - so the honest thing is to name the file, name the
        # mount, and say roughly how long it takes. A watcher that also shows
        # how long the current step has been running turns the rest of the
        # reassurance into something that visibly moves.
        $Progress.Report(7, $stepTotal, 'Mounting the image',
            ('{0} into {1} - a minute or so' -f (Split-Path -Leaf $scratchWim), $mountPath))

        $BootImageService.MountImage($scratchWim, 1, $mountPath)
        $mounted = $true

        # -- 8. the components, each followed by its language pack -----------

        $Progress.Report(8, $stepTotal, 'Applying the optional components',
            ('{0} component(s)' -f @($component).Count))
        #
        # DESIGN 5.1: "Each component's matching en-us pack is applied
        # immediately after it, where one exists." The empty LanguageCabPath is
        # Get-HDTBootImageComponent's answer for the twelve components in this
        # ADK that ship none.

        # REPORTED PER CAB, NOT ONCE FOR THE LOOP. This step is most of a minute
        # on a nine-component image, and a watcher told only "applying the
        # optional components" sits on one unchanging line for all of it -
        # which is indistinguishable from a build that has stopped. Naming each
        # cab as it goes in is the difference between "working" and "stuck", and
        # it also says WHICH one was being applied if the build dies here.
        $componentAt = 0

        foreach ($row in $component) {
            $componentAt++

            $Progress.Report(8, $stepTotal, 'Applying the optional components',
                ('{0} of {1} - {2}' -f $componentAt, @($component).Count, [string] $row.Name))

            $BootImageService.AddPackage($mountPath, [string] $row.CabPath)

            if (-not [string]::IsNullOrWhiteSpace([string] $row.LanguageCabPath)) {
                $Progress.Report(8, $stepTotal, 'Applying the optional components',
                    ('{0} of {1} - {2} language pack' -f $componentAt, @($component).Count, [string] $row.Name))

                $BootImageService.AddPackage($mountPath, [string] $row.LanguageCabPath)
            }
        }

        # -- 9. scratch space ------------------------------------------------

        $Progress.Report(9, $stepTotal, 'Setting the scratch space',
            ('{0} MB' -f [int] $workspace.BootImage.ScratchSpaceMB))

        $BootImageService.SetScratchSpace($mountPath, [int] $workspace.BootImage.ScratchSpaceMB)

        # -- 10. the boot driver group ---------------------------------------

        $Progress.Report(10, $stepTotal, 'Injecting the boot drivers', [string] $workspace.BootImage.Drivers)
        #
        # Boot images get network and storage drivers only, never the whole
        # driver store. A group that is not there WARNS AND CONTINUES: M5 owns
        # the driver store, and a boot image build must not be blocked by a
        # folder nobody has imported into yet.
        #
        # THE KEY NAMES A SELECTION PROFILE NOW, WHICH CAN BE SEVERAL FOLDERS.
        # That is what lets one boot image carry a Dell WinPE pack and an HP
        # WinPE pack - the thing a single folder name could never say. A share
        # written before profiles existed still names a folder, and
        # Resolve-HDTBootImageDriverPath still answers with it.

        $driverGroup = [string] $workspace.BootImage.Drivers

        $resolved = Resolve-HDTBootImageDriverPath -WorkspaceRoot $WorkspaceRoot `
            -Name $driverGroup -FileSystem $FileSystem

        if (-not [string]::IsNullOrEmpty([string] $resolved.Warning)) {
            Write-Warning ([string] $resolved.Warning)
        }

        # EACH FOLDER IS ITS OWN CALL, in the profile's declared order. DISM
        # takes one -Driver path at a time, and the order is the author's: a
        # profile listing a storage pack before a network pack meant that.
        #
        # A FOLDER HOLDING A DISABLED DRIVER GOES IN ONE .inf AT A TIME.
        # Add-WindowsDriver with -Recurse takes everything under a folder and
        # there is no "except that one", so a tick box that did not change this
        # would be decoration. Every other folder still goes in whole - see
        # Get-HDTBootImageDriverInjection for why that is decided per folder.
        $catalog = @()

        try {
            $catalog = @(Get-HDTDriver -Root $WorkspaceRoot -FileSystem $FileSystem)
        } catch {
            # A store this cannot read is a store with nothing disabled as far as
            # the build is concerned: the folders still go in whole, which is
            # what happened before any of this existed.
            Write-Warning ("the driver catalog could not be read, so every driver in the profile will be injected: {0}" -f
                [string] $_.Exception.Message)
        }

        # ONE CALL PER DRIVER ONLY IF SOMEBODY ASKED FOR IT.
        # Add-WindowsDriver with -Recurse is a single call DISM works through
        # for about a minute with no callback, so this step cannot be counted -
        # and splitting it costs seven minutes against fifty-six seconds, which
        # is not a price to charge every build for a moving number. The bar
        # sweeps during the silence instead. -PerDriver is for the build where
        # a machine came up without its network card.
        $injection = @(Get-HDTBootImageDriverInjection -Folder ([string[]] @($resolved.Path)) `
                -Driver ([object[]] $catalog) -Root $WorkspaceRoot -PerDriver:$PerDriver)

        $injectionCount = @($injection).Count
        $injectionAt = 0

        foreach ($current in @($injection)) {
            $injectionAt++

            # ONLY WHEN THERE IS SOMETHING NEW TO SAY.
            #
            # The step has already announced itself above, naming the profile.
            # Reporting again for a FOLDER call repeated that line word for word
            # - two identical rows in the log a second apart, and then a silent
            # minute and a half - which reads as the build having stalled twice
            # rather than once. A folder call has no name to add, so it adds
            # nothing; a per-driver call has, and says it.
            if (-not [string]::IsNullOrEmpty([string] $current.Name)) {
                $Progress.Report(10, $stepTotal, 'Injecting the boot drivers',
                    ('{0} of {1} - {2}' -f $injectionAt, $injectionCount, [string] $current.Name))
            }

            $driver += @($BootImageService.AddDriver($mountPath, [string] $current.Path, [bool] $current.Recurse))
        }

        # -- 11. the engine ---------------------------------------------------

        # The detail is the mount, not $hdtRoot: that one is worked out a few
        # lines below, and a report reaching for it is a report that reads a
        # variable which does not exist yet.
        $Progress.Report(11, $stepTotal, 'Staging the engine and the payload', $mountPath)
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

        # ONE FILE INSTEAD OF SEVERAL HUNDRED.
        #
        # The module is authored one function per file - 391 of them - and the
        # loader dot-sources every one. The bundle is that same code
        # concatenated, and Hephaestus.psm1 prefers it whenever it is not stale.
        # Staging the sources meant reading, copying and parsing 391 files to
        # build an image, and then Copy-HDTResumeAgent copying all 391 again onto
        # the disk of every machine deployed from it.
        #
        # IT IS REGENERATED, NOT TRUSTED. A bundle left over from before an edit
        # would put an engine older than its own sources inside a boot image -
        # the one outcome worse than a slow build, and impossible to spot from
        # the image. Writing it here means the bundle in the image is by
        # construction the module being staged.
        #
        # A MODULE ROOT THAT CANNOT BE BUNDLED IS NOT FATAL. Write-HDTModuleBundle
        # refuses a folder with no Private or Public in it, which is what a
        # module that ALREADY ships as a bundle looks like - so the sources are
        # staged the old way and the bundle, if there is one, travels with them.
        # THE REGENERATION IS BEST EFFORT; THE DECISION IS NOT. Write-HDTModuleBundle
        # works on the real module folder, so it is attempted and its failure is
        # not fatal - a source tree that cannot be written (read-only, or a module
        # that already ships bundled) still has whatever bundle it has, and that
        # is the same file the build host's own loader would import. What decides
        # the staging is the injected file system, which is what a test can see.
        try {
            [void] (Write-HDTModuleBundle -ModuleRoot $EngineModulePath -ErrorAction Stop)
        } catch {
            $Progress.Report(11, $stepTotal, 'The module bundle could not be regenerated; staging what is there', $EngineModulePath)
        }

        $bundled = $FileSystem.TestPath([System.IO.Path]::Combine($EngineModulePath, 'Hephaestus.bundle.ps1'))

        $engineFileCount = 0
        foreach ($child in @($FileSystem.GetChildItem($EngineModulePath))) {
            $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            # Payload\ AND UI\ ARE BOTH EXCLUDED FROM THE MODULE TREE and
            # staged to X:\HDT\ instead. A second copy under
            # Modules\Hephaestus\ would be a second answer to "where is the
            # wizard", and the one startnet.cmd does not use.
            if (@('Payload', 'UI') -contains $leaf) { continue }

            # AND SO ARE THE SOURCES THE BUNDLE REPLACES. Shipping both would
            # ship the same code twice and leave the loader deciding between them
            # on a timestamp comparison inside WinPE.
            if ($bundled -and @('Private', 'Public') -contains $leaf) { continue }

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

        # AND THE DELETER BESIDE IT, staged FROM the boot image TO the target
        # exactly as the resume agent is. It is the script that removes C:\HDT
        # once the deployment has finished, and it has to live inside the folder
        # it deletes so Copy-HDTResumeAgent can carry it across - it is copied
        # out to %TEMP% at the moment it is needed.
        $FileSystem.CopyItem($removalPayload, [System.IO.Path]::Combine($hdtRoot, 'Remove-HDTAgentTree.ps1'))
        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Remove-HDTAgentTree.ps1'
                Source      = $removalPayload
                FileCount   = 1
                SizeBytes   = [long] 0
            })

        # STAGED WHETHER OR NOT THIS IMAGE CARRIES CERTIFICATES, exactly as
        # Start-HDTResume.ps1 is staged into an image that may never resume. It
        # is a few kilobytes, startnet.cmd names it only when there is something
        # to import, and an image whose script is missing the day somebody adds
        # a certificate would fail in the one place there is no operator.
        $FileSystem.CopyItem($certificatePayload, [System.IO.Path]::Combine($hdtRoot, 'Import-HDTBootCertificate.ps1'))
        [void] $payloadRow.Add([pscustomobject] @{
                Destination = '\HDT\Import-HDTBootCertificate.ps1'
                Source      = $certificatePayload
                FileCount   = 1
                SizeBytes   = [long] 0
            })

        # -- 11b. the certificates themselves ---------------------------------
        #
        # INTO \HDT\Certs\, BESIDE THE SCRIPT THAT READS THEM. The share may not
        # be reachable when they are imported - that is the whole reason the
        # import runs before wpeinit - so the files have to be in the image.
        #
        # THE LEAF NAME IS KEPT. bootstrap.json names each one as
        # X:\HDT\Certs\<leaf>, so two certificates with the same file name in
        # different folders would land on each other; the document forbids the
        # same path twice and this is the remaining case, which is rare enough
        # to be worth a plain overwrite rather than a naming scheme nobody can
        # read in a log.

        $certificateInImage = New-Object -TypeName System.Collections.ArrayList

        if (@($certificateSource).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($clientCertificateSource)) {
            $certificateRoot = [System.IO.Path]::Combine($hdtRoot, 'Certs')
            $FileSystem.CreateDirectory($certificateRoot)

            foreach ($current in @($certificateSource)) {
                $FileSystem.CopyItem([string] $current.Source,
                    [System.IO.Path]::Combine($certificateRoot, [string] $current.Leaf))

                [void] $certificateInImage.Add('X:\HDT\Certs\{0}' -f [string] $current.Leaf)

                [void] $payloadRow.Add([pscustomobject] @{
                        Destination = '\HDT\Certs\{0}' -f [string] $current.Leaf
                        Source      = [string] $current.Source
                        FileCount   = 1
                        SizeBytes   = [long] 0
                    })
            }

            if (-not [string]::IsNullOrWhiteSpace($clientCertificateSource)) {
                $FileSystem.CopyItem($clientCertificateSource,
                    [System.IO.Path]::Combine($certificateRoot, $clientCertificateLeaf))

                [void] $payloadRow.Add([pscustomobject] @{
                        Destination = '\HDT\Certs\{0}' -f $clientCertificateLeaf
                        Source      = $clientCertificateSource
                        FileCount   = 1
                        SizeBytes   = [long] 0
                    })
            }
        }

        # -- 12. bootstrap.json ----------------------------------------------

        $Progress.Report(12, $stepTotal, 'Writing bootstrap.json', '')
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

        # NAMED IN THE IMAGE'S OWN LETTERS, not the share's. By the time this
        # block is read the files are on X: and the share may not be reachable.
        if (@($certificateInImage).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($clientCertificateLeaf)) {
            $certificateBlock = [ordered] @{}

            if (@($certificateInImage).Count -gt 0) {
                $certificateBlock['root'] = [string[]] @($certificateInImage)
            }

            if (-not [string]::IsNullOrWhiteSpace($clientCertificateLeaf)) {
                $certificateBlock['client'] = 'X:\HDT\Certs\{0}' -f $clientCertificateLeaf
                $certificateBlock['protected'] = $certificateProtected
            }

            $bootstrap['certificate'] = $certificateBlock
        }

        # CARRIED SO THE DEPLOYED MACHINE GETS THE SAME ANSWER. startnet.cmd
        # already moves WinPE's clock with it; this is how HDTTimeZone reaches
        # the unattend's specialize pass without the administrator choosing
        # twice and getting two different answers.
        if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.TimeZone)) {
            $bootstrap['timeZone'] = [string] $workspace.BootImage.TimeZone
        }

        $FileSystem.WriteAllText([System.IO.Path]::Combine($hdtRoot, 'bootstrap.json'),
            (ConvertTo-Json -InputObject $bootstrap -Depth 4))

        # -- 12b. bootstrap-rules.yaml, when the share authors one ------------
        #
        # ONE BOOT IMAGE, MANY SHARES - MDT's Bootstrap.ini. bootstrap.json
        # carries ONE deployRoot; this file lets the machine choose from its own
        # facts, which is what MDT's Priority=DefaultGateway, MACAddress does.
        #
        # VALIDATED HERE, NOT IN WinPE. A document the engine would refuse at
        # three in the morning on a machine nobody is watching is refused now,
        # in front of whoever is building the image - and this is the last
        # moment anybody is looking at it.
        #
        # ABSENT IS THE NORMAL CASE. A share with one deployRoot writes no such
        # file, and an image built without one behaves exactly as it did before
        # this existed.
        $bootstrapRuleSource = Join-Path -Path $WorkspaceRoot -ChildPath 'bootstrap-rules.yaml'

        if ($FileSystem.TestPath($bootstrapRuleSource)) {
            $bootstrapDocument = Import-HDTBootstrapRuleDocument -Path $bootstrapRuleSource -FileSystem $FileSystem

            # A RULE HERE OVERRIDES deployRoot, AND NOTHING USED TO SAY SO.
            #
            # This file is read in WinPE before the share is reachable, so a rule
            # matching on gateway or MAC decides which server a machine actually
            # goes to - and workspace.yaml's deployRoot is only the fallback.
            # When the lab's DHCP lease moved, deployRoot was corrected, the
            # image rebuilt, and every machine still went to the old address
            # because both rules still named it. No screen, no step and no test
            # mentioned the disagreement; the Welcome screen even showed the
            # CORRECTED address, because that box is filled from the workspace.
            #
            # IT WARNS AND BUILDS. Pointing some machines at another server is
            # what these rules are for.
            foreach ($sentence in @(Get-HDTBootstrapDeployRootWarning `
                        -DeployRoot ([string] $workspace.DeployRoot) `
                        -Rule ([object[]] @($bootstrapDocument.Rule)))) {

                Write-Warning ([string] $sentence)
            }

            $FileSystem.WriteAllText([System.IO.Path]::Combine($hdtRoot, 'bootstrap-rules.yaml'),
                [string] $FileSystem.ReadAllText($bootstrapRuleSource))

            Write-Information ("boot image: bootstrap-rules.yaml injected from '{0}'" -f $bootstrapRuleSource)
        }


        # -- 13. startnet.cmd -------------------------------------------------

        # EVERY LINE OF IT, BECAUSE THIS FILE IS THE WHOLE BOOT.
        #
        # startnet.cmd is what WinPE runs and nothing else: wpeinit, whatever the
        # share added, and the line that launches the deployment. It reported as
        # one bare row with no detail at all, so the file that decides whether a
        # machine deploys or sits at a prompt was the least visible thing in the
        # build - and reading it afterwards means mounting the image.
        #
        # A BLANK OR A COMMENT IS NOT A COMMAND and is not worth a row; what is
        # left is exactly what will run, in order.
        $startnetLine = @([string[]] @($startnet -split "`r?`n") |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($_).TrimStart() -notlike '@rem*' -and ($_).TrimStart() -notlike 'rem *' })

        $startnetCount = @($startnetLine).Count
        $startnetAt = 0

        $Progress.Report(13, $stepTotal, 'Writing startnet.cmd', ('{0} line(s)' -f $startnetCount))

        foreach ($one in @($startnetLine)) {
            $startnetAt++

            $Progress.Report(13, $stepTotal, 'Writing startnet.cmd',
                ('{0} of {1} - {2}' -f $startnetAt, $startnetCount, ([string] $one).Trim()))
        }

        $FileSystem.WriteAllText(
            [System.IO.Path]::Combine($mountPath, 'Windows', 'System32', 'startnet.cmd'), $startnet)

        # -- 13b. the WinPE answer file ---------------------------------------
        #
        # AFTER startnet.cmd, because the line that reads it has just been
        # written and the two are one decision. Named Unattend.xml at the image
        # root whatever it is called on the share: startnet.cmd points at
        # X:\Unattend.xml, and a name that varied would mean the two files had
        # to agree twice.

        if (-not [string]::IsNullOrWhiteSpace($unattendSource)) {
            $FileSystem.CopyItem($unattendSource, [System.IO.Path]::Combine($mountPath, 'Unattend.xml'))
        }

        # -- 13c. the WinPE background ----------------------------------------
        #
        # OVER \Windows\System32\winpe.jpg, WHICH IS THE ONLY FILE WinPE READS
        # for this. The name in the image is fixed; what the administrator
        # called it on their own disk is their business.
        #
        # THAT FILE ALREADY EXISTS IN THE MOUNT AND IS OWNED BY TrustedInstaller
        # - Microsoft's own instructions for replacing it say to take ownership
        # and grant Administrators full control first. So the copy is attempted
        # and a refusal is REPORTED IN THOSE TERMS rather than as a bare access
        # denied, which is a message nobody can act on.

        if (-not [string]::IsNullOrWhiteSpace($backgroundSource)) {
            $Progress.Report(13, $stepTotal, 'Copying the WinPE background', $backgroundSource)

            $backgroundTarget = [System.IO.Path]::Combine($mountPath, 'Windows', 'System32', 'winpe.jpg')

            try {
                # OWNERSHIP FIRST, AND ONLY THEN THE COPY. A real build failed
                # here with "Access to the path is denied" before this line
                # existed: the file is owned by TrustedInstaller, and taking
                # ownership plus granting Administrators full control is
                # Microsoft's own documented procedure for replacing it.
                #
                # ONLY IF IT IS THERE. Ownership is a thing one takes FROM
                # somebody; a WinPE that shipped without a winpe.jpg has nobody
                # to take it from, and the copy below simply creates the file.
                if ($FileSystem.TestPath($backgroundTarget)) {
                    $FileSystem.TakeOwnership($backgroundTarget)
                }
                $FileSystem.CopyItem($backgroundSource, $backgroundTarget)
            } catch {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $backgroundTarget `
                            -Message ("the WinPE background could not be written over '{0}': {1}. That file is owned by TrustedInstaller inside the image, and replacing it needs ownership and full control for Administrators - or an elevated build." -f
                                $backgroundTarget, $_.Exception.Message)))
            }
        }

        # -- 14. extraContent --------------------------------------------------

        # THE COUNT ANNOUNCES THE STEP; EACH ENTRY NAMES ITSELF.
        #
        # "2 entry(s)" says how many and not which, which is a line that sends
        # somebody to workspace.yaml to find out what went into their own boot
        # image - and these are the folders the startCommand lines then run out
        # of, so which they are is the whole point. The optional components have
        # named themselves one at a time since they were written; this is that,
        # for the step that carries a site's own tools.
        $extraContentCount = @($extraContentPlan).Count
        $extraContentAt = 0

        $Progress.Report(14, $stepTotal, 'Copying the extra content', ('{0} entry(s)' -f $extraContentCount))

        foreach ($entry in $extraContentPlan) {
            $extraContentAt++

            # THE DECLARED DESTINATION, not the scratch path it is being written
            # into: '\Tools\BGInfo' is where it lands in WinPE, which is what the
            # startCommand names and what somebody reading this recognises. The
            # mount folder underneath is this build's own business.
            $Progress.Report(14, $stepTotal, 'Copying the extra content',
                ('{0} of {1} - {2}' -f $extraContentAt, $extraContentCount, [string] $entry.Declared))

            $count = Copy-HDTContentTree -Source $entry.Source -Destination $entry.Destination -FileSystem $FileSystem

            [void] $extraRow.Add([pscustomobject] @{
                    Source      = [string] $entry.Source
                    Destination = [string] $entry.Declared
                    FileCount   = [int] $count
                })
        }

        # -- 15. the share ACL - warn, never refuse (DESIGN 6.3) --------------

        $Progress.Report(15, $stepTotal, 'Checking the share permissions', $WorkspaceRoot)

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

        # THE OTHER LONG ONE, and for the same reason: a commit writes every
        # change into the WIM and the export rebuilds it. Two DISM calls, no
        # sub-progress, a minute and a half between them.
        $Progress.Report(16, $stepTotal, 'Committing and exporting the image',
            'writing every change back into the .wim - the longest step')

        $BootImageService.DismountImage($mountPath, $true)
        $mounted = $false
    } catch {
        # A FAILURE AFTER THE MOUNT DISCARDS IT. Without this the machine is left
        # with a mounted image and the next build cannot mount over it.
        if ($mounted) {
            $BootImageService.DismountImage($mountPath, $false)
            $mounted = $false
        }

        # THE FAILURE TRAVELS ON THE SAME STREAM AS THE STEPS. A watcher that
        # simply stopped receiving would have to guess between finished, slow
        # and dead - and the one it guesses wrong is the one where somebody
        # waits ten minutes for a build that died in the first thirty seconds.
        $Progress.Complete($false, [string] $_.Exception.Message)

        throw
    }

    # ONE BUILD, TWO ARTIFACTS, AND THEY MUST AGREE (DESIGN 6.1.1). Both are
    # written beside their final names and moved into place only once BOTH exist.
    # Same directory means same volume, so those moves are renames rather than
    # half a gigabyte of copying - and a build that dies between them leaves the
    # PREVIOUS pair, intact and consistent, instead of a new .wim beside a stale
    # .iso under matching names with nothing saying so.
    #
    # That is not hypothetical: a VM holding the ISO open made oscdimg fail after
    # the WIM had been written, and the share was left with artifacts three hours
    # apart.
    $wimStagePath = $wimPath + '.new'
    $isoStagePath = $isoPath + '.new'

    $FileSystem.CreateDirectory($bootFolder)
    $FileSystem.RemoveItem($wimStagePath, $false)
    $BootImageService.ExportImage($scratchWim, 1, $wimStagePath)

    # ONE FILE, TWO HOMES, SAME BYTES. The ISO is built from the exported WIM,
    # not from a second export - DESIGN 6.1.1's mechanism, and the reason the
    # manifest can record isoBootWimSha256 as a fact rather than a hope.
    $mediaBootWim = [System.IO.Path]::Combine($mediaSources, 'boot.wim')
    $FileSystem.CopyItem($wimStagePath, $mediaBootWim)

    $wimSha256 = [string] $FileSystem.GetHash($wimStagePath)
    $wimSize = [long] $FileSystem.GetLength($wimStagePath)

    # =====================================================================
    # 17. THE ISO, THEN THE MANIFEST - LAST
    # =====================================================================

    # WHICH KIND OF ISO THIS IS, SAID WHILE IT IS BEING MADE.
    #
    # The two are indistinguishable afterwards - same name, same size to the
    # megabyte - and the difference decides whether a machine boots on its own
    # or waits at "Press any key" for somebody who is not standing there. That
    # is the whole zero-keystroke story (DESIGN 5.2), and the build said nothing
    # about it: the only way to find out was to boot a VM and watch.
    #
    # -SkipIso SAYS SO TOO rather than reporting a keypress setting for a file
    # that is not being written.
    $isoDetail = 'no keypress needed - efisys_noprompt.bin'
    if ($wantPrompt) { $isoDetail = 'press a key to boot - efisys.bin' }
    if ($SkipIso) { $isoDetail = 'no ISO - the manifest records it as skipped' }

    $Progress.Report(17, $stepTotal, 'Building the ISO and writing the manifest', $isoDetail)

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
            Path             = $isoStagePath
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
        #
        if (-not $wantPrompt) { $isoSplat['NoPromptForKey'] = $true }

        $iso = New-HDTBootIso @isoSplat

        # THE FINAL PATH, NOT THE STAGING ONE. Everything downstream - the
        # manifest, the returned object, the log a technician reads - names the
        # file that will exist when this returns.
        $isoResultPath = [string] $isoPath
        $isoSha256 = [string] $iso.Sha256
        $isoSize = [long] $iso.SizeBytes
        $isoBootWimSha256 = [string] $FileSystem.GetHash($mediaBootWim)
    }

    # =====================================================================
    # 17a. PUBLISH - BOTH, OR NEITHER
    # =====================================================================
    #
    # Nothing above this line has touched the artifacts a technician boots. The
    # renames are what replace them, and they happen only now that both exist.
    # THE MANIFEST IS WRITTEN AFTER BOTH, which is what makes its recorded hashes
    # a promise rather than a hope: a manifest on disk means the two files beside
    # it came from the build that wrote it.
    # THE ISO GOES FIRST, because it is the one something else holds open - a
    # VM's DVD drive - so if a publish is going to fail, it fails before the WIM
    # has been replaced and both artifacts are still the previous build's.
    #
    # TWO RENAMES ARE NOT ONE TRANSACTION, and no filesystem offers one across two
    # files. The probe before the mount is what makes this window small rather
    # than what makes it disappear.
    if (-not $SkipIso) { $FileSystem.MoveItem($isoStagePath, $isoPath) }

    $FileSystem.MoveItem($wimStagePath, $wimPath)

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
        NoPromptForKey = (-not $wantPrompt)
        Skipped        = [bool] $SkipIso
    } `
        -IsoBootWimSha256 $isoBootWimSha256

    # LAST, so a manifest that exists describes a build that finished.
    $FileSystem.WriteAllText($manifestPath, $manifestText)

    # AFTER THE MANIFEST, for the same reason the manifest is last: the build is
    # finished when the file that describes it exists, and a watcher told
    # otherwise would close over a build still writing.
    $Progress.Complete($true, $wimPath)

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
