function Get-HDTRefreshLaunchPlan {
    <#
        .SYNOPSIS
            Everything the full-OS launcher needs to hand a Refresh to the
            engine: which share it was started from, which leg this is, and the
            bootstrap document Start-HDTDeployment.ps1 reads.

        .DESCRIPTION
            THE DOOR INTO A REFRESH. M9 built the whole of one - the derived
            phase, the transport, the guards, refresh.yaml - and left nothing that
            could start it. The engine calls a run a REFRESH because it STARTED in
            the running full OS (DESIGN 3.2), and Start-HDTDeployment.ps1 has been
            ready to be started on that leg since M9; what did not exist was
            anything that started it there. DESIGN documented the WinPE entry
            point and only the WinPE entry point.

            MDT'S SHAPE, AND HDT TAKES IT. A Refresh in MDT is
            \\server\Share$\Scripts\LiteTouch.vbs, run by an administrator on the
            machine that is about to be replaced. That file is thin on purpose: it
            works out where it was launched FROM
            (oFSO.GetParentFolderName(WScript.ScriptFullName)), checks the machine
            can do this at all, and hands everything to LiteTouch.wsf, which is
            the heavy lifting. HDT's heavy lifting already exists, so the launcher
            has LiteTouch.vbs's job and nothing else - and every decision it would
            have made is here, where a fake can drive it.

            WHY THE SHARE IS THE LAUNCHER'S OWN LOCATION AND NOT A WRITTEN-DOWN
            PATH. The administrator reached \\server\Share\Scripts\ to run this,
            so that path demonstrably works from this machine right now. A
            deployRoot recorded in a document months ago may not: a share
            published under a second name, a DFS path, a drive mapped to it, a
            server renamed. MDT has always derived it this way and it is the one
            value that cannot be stale.

            THE PROVIDER IS Local, AND THAT IS ABOUT AUTHENTICATION RATHER THAN
            ABOUT UNC. Smb means "connect to this share with these credentials
            first" - what a machine that has just booted a WIM must do, with
            nobody logged on and no token to reuse. An administrator who opened
            the share and ran the launcher has already authenticated; their
            session holds the connection, and the content is reachable as a plain
            filesystem path. Get-HDTBootstrapConfiguration refuses an Smb document
            carrying no credential and no promptForCredential for exactly that
            situation - "a machine booting it can neither authenticate to the
            share nor ask anybody" - and this is neither of those things. Local
            with a rooted deployRoot is legal and is what a build host already
            uses; Resolve-HDTDeployRoot returns it unchanged once it finds the
            marker beside it.

            WHAT IT REFUSES, AND IN THIS ORDER:

              1. an unelevated session. FIRST, because a standard user very often
                 cannot read the share either - so a launcher that checked the
                 share first would tell them rules.yaml was missing and send them
                 looking for a file that is there. MDT checks the same thing in
                 the same place, by writing into %SystemRoot%.
              2. a run started in WinPE. startnet.cmd already runs the engine
                 there; this would mint a second run beside the one going.
              3. a launcher that is not sitting in a share. Copying a .ps1 to the
                 desktop is the obvious thing to do with one and it cannot work,
                 because the file's location IS the share.
              4. a share with no engine staged in Modules\. The machine being
                 refreshed has nothing installed on it - that is the whole
                 situation - so the engine comes off the share, which DESIGN 3's
                 layout already calls "engine payload staged to clients".

            EVERY REFUSAL NAMES THE FIX rather than the symptom, because this runs
            on somebody's production laptop with a person watching it.

        .PARAMETER ScriptRoot
            The directory the launcher is running from - $PSScriptRoot on the
            share, which is <share>\Scripts.

        .PARAMETER SystemDrive
            The system drive as the environment reports it, read through
            IEnvironmentProvider. 'C:' in the full OS, 'X:' in WinPE. It decides
            the phase, so nothing may declare it.

        .PARAMETER IsElevated
            Whether the session is running as an administrator. Read by the
            launcher from the real WindowsPrincipal and decided here, so the
            refusal is testable.

        .PARAMETER SequenceId
            The task sequence to run, when the administrator named one. Empty is
            legal and ordinary: the sequence then comes from the wizard or the
            rules.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one; a test passes
            New-HDTFakeFileSystem.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Root, ScriptRoot, Phase, DeploymentType, Provider, WorkspaceId,
              SequenceId, ModuleRoot, PayloadPath, BootstrapPath, Bootstrap,
              BootstrapText, UiRoot, UiArgument

            UiArgument is a hashtable ready to splat onto the payload: every
            window it declares on the WinPE RAM disk, answered with the copy in
            the engine staged on the share.

        .EXAMPLE
            Get-HDTRefreshLaunchPlan -ScriptRoot '\\HDT-HOST\HdtShare\Scripts' `
                -SystemDrive 'C:' -IsElevated $true

            What Start-HDTRefresh.ps1 asks for, on the machine being replaced.
            The share is the folder above the launcher, the phase is derived from
            the drive, and the run is a REFRESH because of it.

        .EXAMPLE
            $plan = Get-HDTRefreshLaunchPlan -ScriptRoot 'D:\HdtShare\Scripts' `
                -SystemDrive 'C:' -IsElevated $true -SequenceId 'REFRESH'
            Set-Content -LiteralPath $plan.BootstrapPath -Value $plan.BootstrapText -Encoding UTF8
            $ui = $plan.UiArgument
            & $plan.PayloadPath -BootstrapPath $plan.BootstrapPath -ModuleRoot $plan.ModuleRoot @ui

            The whole handover, with the sequence named so nobody is asked for
            it: write the bootstrap document the plan produced, then run the same
            entry point startnet.cmd runs in WinPE - splatting the screens, which
            default to a RAM disk this machine does not have.

        .LINK
            Get-HDTDeploymentPhase

        .LINK
            Get-HDTBootstrapConfiguration
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ScriptRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $SystemDrive,

        [Parameter(Mandatory = $true)]
        [bool] $IsElevated,

        [Parameter()]
        [AllowEmptyString()]
        [string] $SequenceId = '',

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- 1. may this session do it at all ------------------------------------
    #
    # BEFORE THE SHARE IS TOUCHED. See the refusal order in the description: a
    # standard user is very often refused by the share as well, and the first
    # sentence they read has to be the one that is actually true of them.
    if (-not $IsElevated) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ScriptRoot `
                    -Category PermissionDenied `
                    -Message ('a Refresh must be started by an administrator, and this session is not elevated. ' +
                        'It suspends BitLocker, writes a one-shot boot entry with bcdedit and empties the volume Windows is running from - ' +
                        'every one of those fails part-way through as a standard user, which leaves the machine worse off than not starting. ' +
                        'Right-click Start-HDTRefresh.cmd and choose Run as administrator.')))
    }

    # -- 2. which leg is this ------------------------------------------------
    #
    # DERIVED, NEVER DECLARED. Get-HDTDeploymentPhase carries every branch and
    # the reasoning; this asks it, and asks Get-HDTDeploymentType for the mapping
    # rather than keeping a second copy of it (that function's own note says two
    # things need the mapping and they must not disagree - a third would be a
    # third).
    $phase = Get-HDTDeploymentPhase -SystemDrive $SystemDrive

    if ($phase -eq 'WinPE') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $SystemDrive `
                    -Message (("this machine is running WinPE - its system drive is '{0}' - and the WinPE entry point has already run. " -f $SystemDrive) +
                        'startnet.cmd launches X:\HDT\Start-HDTDeployment.ps1 the moment the image finishes booting, so there is nothing for this launcher to start; ' +
                        'running it here would mint a second deployment beside the one already going. This file is for starting a Refresh from an installed Windows.')))
    }

    $deploymentType = Get-HDTDeploymentType -Phase $phase

    # -- 3. where the share is -----------------------------------------------
    #
    # [IO.Path]::GetDirectoryName, NOT Split-Path -Parent. The launcher routinely
    # sits on a UNC path or on a drive this session has not mounted, and the
    # provider-aware cmdlets resolve the drive - the DriveNotFound trap CLAUDE.md
    # rule 8 names and Get-HDTWorkspacePath already carries. Every combine below
    # is [IO.Path]::Combine for the same reason, which is what makes this
    # provable against a fake at all.
    $root = [System.IO.Path]::GetDirectoryName($ScriptRoot.TrimEnd('\', '/'))

    if ([string]::IsNullOrWhiteSpace($root)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ScriptRoot `
                    -Message (("'{0}' has no parent directory, so the deployment share this launcher belongs to cannot be worked out. " -f $ScriptRoot) +
                        'The launcher runs from <share>\Scripts\, and the share is the folder above it.')))
    }

    # THE MARKER, NOT THE FOLDER NAME. rules.yaml is what every provider in HDT
    # already uses to recognise a share (contentMarker), so a folder that merely
    # happens to be called Scripts does not pass and a share is recognised the
    # same way here as it is at boot.
    $rulePath = [System.IO.Path]::Combine($root, 'rules.yaml')

    if (-not $FileSystem.TestPath($rulePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $rulePath `
                    -Message (("'{0}' is not a deployment share: it holds no rules.yaml. " -f $root) +
                        'The launcher reads the share from its own location, so it has to run from <share>\Scripts\ - ' +
                        'a copy on the desktop or in a downloads folder has nothing to deploy. ' +
                        'Run it from the share itself, the way MDT runs Scripts\LiteTouch.vbs.')))
    }

    $workspacePath = [System.IO.Path]::Combine($root, 'workspace.yaml')

    if (-not $FileSystem.TestPath($workspacePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $workspacePath `
                    -Message (("'{0}' holds a rules.yaml but no workspace.yaml, so the share cannot say what it is called. " -f $root) +
                        'The id is carried into log and artifact names. Create the share with New-HDTWorkspace, or restore the workspace.yaml it wrote.')))
    }

    # -- 4. the engine it hands over to --------------------------------------
    #
    # OFF THE SHARE, BECAUSE THE MACHINE HAS NOTHING ON IT. A machine being
    # refreshed is somebody's working laptop; HDT is not installed on it and must
    # not have to be. DESIGN 3's layout already names Modules\ "engine payload
    # staged to clients", and this is the client.
    $moduleRoot = [System.IO.Path]::Combine($root, 'Modules')
    $payloadPath = [System.IO.Path]::Combine($moduleRoot, 'Hephaestus', 'Payload', 'Start-HDTDeployment.ps1')

    if (-not $FileSystem.TestPath($payloadPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $payloadPath `
                    -Message (("the engine is not staged on this share: '{0}' does not exist. " -f $payloadPath) +
                        'A machine being refreshed has nothing installed on it, so the engine is read from the share - ' +
                        ("copy the Hephaestus module folder to '{0}\Hephaestus' and run this again." -f $moduleRoot))))
    }

    # -- 5. what the share calls itself --------------------------------------
    #
    # READ, NOT INVENTED. The workspace id is written into log and artifact
    # names, so a launcher that made one up would produce a run nobody could find
    # beside the share's other runs.
    $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem

    # -- 6. the bootstrap document -------------------------------------------
    #
    # THE SAME FILE THE BOOT IMAGE CARRIES, WRITTEN HERE INSTEAD OF AT BUILD
    # TIME. Update-HDTBootImage bakes one into X:\HDT\bootstrap.json because a
    # booting machine has no other way to be told where it is; a Refresh knows,
    # because it is already standing in the share. Same reader, same shape, same
    # refusals - so nothing downstream has to learn that this run started
    # differently.
    #
    # NO credential BLOCK AND promptForCredential FALSE. See the description: the
    # session that launched this is already authenticated to the share, which is
    # why the provider is Local.
    $bootstrap = [System.Collections.Specialized.OrderedDictionary]::new()
    $bootstrap['schemaVersion'] = 1
    $bootstrap['workspaceId'] = [string] $workspace.Id
    $bootstrap['provider'] = 'Local'
    $bootstrap['deployRoot'] = $root
    $bootstrap['contentMarker'] = 'rules.yaml'
    $bootstrap['sequenceId'] = [string] $SequenceId
    $bootstrap['promptForCredential'] = $false
    $bootstrap['logLevel'] = 'Info'

    # WHERE IT LANDS: <SystemDrive>\HDT\, which is already this run's own
    # directory in the full OS. Get-HDTLogPath puts the logs there, refresh.yaml
    # stages the WinPE to <volume>\HDT\Boot and CleanVolume keeps the folder
    # standing for exactly that reason. A temp folder would say nothing about
    # which run wrote it, and would be gone by the time anybody looked.
    $driveRoot = $SystemDrive.Trim().TrimEnd('\', '/')
    $bootstrapPath = [System.IO.Path]::Combine($driveRoot + '\', 'HDT', 'bootstrap.json')

    # -- 7. the windows this leg draws ---------------------------------------
    #
    # OFF THE SHARE, OUT OF THE ENGINE ALREADY STAGED THERE. Start-HDTDeployment
    # takes every window it draws as a parameter defaulted to X:\HDT\UI\, which
    # is right on the leg it was written for - Update-HDTBootImage stages
    # src\Hephaestus\UI\ into the image and WinPE boots with its system drive at
    # X:. A Refresh runs that same file on a machine that never booted a WIM, so
    # X: is not a drive at all, and until this existed the wizard, the progress
    # board, the failure screen, the welcome screen and the boot status panel
    # every one of them had no file to load.
    #
    # WHY THE MODULE'S OWN UI\ AND NOT A NEW STAGING STEP. -ModuleRoot already
    # points at Modules\, the refusal above has already proved the engine is
    # there, and UI\ ships inside that module folder - so the screens travel with
    # the engine that is about to draw them and cannot be a version out of step
    # with it. Nothing is copied onto the machine, which matters: this leg runs
    # BEFORE the volume is emptied, and the legs that run after it draw their own
    # screens from C:\HDT\UI\, which Copy-HDTResumeAgent stages and CleanVolume
    # keeps.
    #
    # AND THE SET IS DISCOVERED, NOT LISTED. Get-HDTPayloadUiPath reads the param
    # block of the payload named above - the very file this plan hands over to -
    # so a seventh screen added to it is answered here on the day it is added.
    # A list written down in this function is the second source of truth
    # CLAUDE.md rule 8 refuses, and six wrong defaults is what one costs.
    $uiRoot = [System.IO.Path]::Combine($moduleRoot, 'Hephaestus', 'UI')
    $uiArgument = Get-HDTPayloadUiPath -PayloadPath $payloadPath -UiRoot $uiRoot -FileSystem $FileSystem

    return [pscustomobject] @{
        Root           = $root
        ScriptRoot     = $ScriptRoot
        Phase          = $phase
        DeploymentType = $deploymentType
        Provider       = [string] $bootstrap['provider']
        WorkspaceId    = [string] $workspace.Id
        SequenceId     = [string] $SequenceId
        ModuleRoot     = $moduleRoot
        PayloadPath    = $payloadPath
        BootstrapPath  = $bootstrapPath
        UiRoot         = $uiRoot
        UiArgument     = $uiArgument
        Bootstrap      = $bootstrap

        # SERIALISED HERE so the launcher writes bytes rather than deciding a
        # shape. ConvertTo-Json's default depth is 2 and this document is flat,
        # but the depth is stated rather than relied on.
        BootstrapText  = ($bootstrap | ConvertTo-Json -Depth 5)
    }
}
