function Invoke-HDTBootToWinPEStep {
    <#
        .SYNOPSIS
            Stages a WinPE on the local disk and arms exactly one boot into it,
            so a sysprepped machine can capture itself.

        .DESCRIPTION
            THE TRANSPORT HALF OF THE FullOS -> WinPE REBOOT.
            Get-HDTResumeCandidate already answers "is a run in progress" when a
            machine arrives in WinPE, and is deliberately transport-independent.
            This is how it gets there.

              - name: Boot into WinPE
                type: BootToWinPE
                runIn: FullOS
                action: arm          # stage | arm | remove
                bootImage: HDTPE_x64 # optional; the share's Boot\<name>.wim

            ONE FIRMWARE-ORDER SWITCH CANNOT SERVE TWO RESTARTS THAT WANT
            OPPOSITE THINGS, and that is the defect this ends. A reference build
            restarts once into WINDOWS - the only window in which applications
            install and Sysprep runs - and once into WinPE, to capture.
            ConfigureBoot's setBootOrder picks one and ruins the other. Measured
            on 2026-08-31: with it false the machine went straight back into
            WinPE at restart 1 and the run stopped at step 8 of 12.

            SO THE FIRMWARE ORDER IS LEFT ALONE AND THE WINDOWS BOOT MANAGER
            DOES THE WORK. A WinPE is staged on the local disk, a ramdisk BCD
            entry points at it, and bcdedit /bootsequence hands that entry the
            next boot and only the next boot. setBootOrder goes back to true,
            restart 1 reaches Windows, and restart 2 reaches WinPE.

            DERIVED FROM MDT: LTIApply.wsf InstallPE (:159-410) and
            ZTIBCDUtility.vbs, wired into Client.xml as two task-sequence steps
            either side of LTISysprep.wsf (:463 and :472). MIT licensed; see
            NOTICE.md. PSD has no FullOS -> WinPE mechanism at all - PSDTBA.ps1
            /capture is an explicit stub - so MDT's VBScript is the only prior
            art there is.

            THREE ACTIONS, WHICH ARE MDT'S OWN THREE HALVES:

              stage    copy Boot\<name>.wim off the share and boot.sdi out of the
                       running Windows, into <volume>\HDT\Boot.
              arm      clear any stale entry, create the ramdisk entry, and point
                       /bootsequence at it.
              remove   delete the entry and the staged files.

            NOTHING IS GENERALIZED UNTIL WE KNOW IT CAN COME BACK, and the split
            into three is what makes that enforceable. stage and arm both run
            BEFORE Sysprep and both FAIL the step rather than warning, because a
            machine sealed by sysprep that cannot reach WinPE is stranded: there
            is no leg left that could fix it, and the installation on the disk
            has already been generalized. remove is the mirror image and warns
            instead - it runs after the capture boot has happened, so a cleanup
            that fails costs nothing anybody needs, while failing there would
            cost the capture the whole build exists to produce.

            AND IT ARMS BEFORE SYSPREP, WHICH IS THE ONE PLACE THIS DIVERGES FROM
            MDT'S ORDERING - AND THE ONE PLACE THIS FILE IS REASONING RATHER THAN
            REPORTING. MDT stages before (/PE /STAGE) and arms after (/PE /BCD),
            with a comment at LTIApply.wsf:347-350 saying the BCD work is deferred
            "so that Sysprep doesn't complain". That ordering leaves the hole this
            step's fail-safe rule exists to close: if the arm fails, the machine
            has already been sealed and nothing downstream can fix it.

            ⚠ NOT OBSERVED. NOBODY HAS RUN sysprep /generalize ON A MACHINE WITH
            AN ARMED /bootsequence AND WATCHED WHAT HAPPENS. The argument for why
            MDT's problem should not apply here is that AdjustBCDDefaults also
            sets /default, repointing the DEFAULT OS entry at a WinPE ramdisk -
            exactly the sort of thing a generalize-time validation would look at -
            while this sets /bootsequence alone and leaves {default} naming
            Windows. SPIKES S23.3 proves that IS what MDT does; it proves nothing
            about what sysprep thinks of it. MDT's comment is evidence somebody
            once hit something, and what they hit is not written down.

            SO TREAT THE ORDER AS PROVISIONAL. If sysprep objects, or silently
            clears the entry, the fix is a template edit and not a rewrite: move
            the action: arm step in reference.yaml to sit after Sysprep. The
            action: stage step stays where it is, so "nothing is generalized
            until we know it can come back" holds either way - which is why this
            step has three actions rather than one. SPIKES S23.5 carries the
            probe to run when there is a machine to run it on.

            THE VOLUME COMES FROM THE PHASE, NOT FROM %HDTOSVolume%.
            In the full OS it is the running system drive, read through
            IEnvironmentProvider: HDTOSVolume carries the WinPE letter (W:)
            across the reboot in state.json, and bcdedit resolves a drive letter
            to a partition at the moment it runs, so arming with W: would write
            an entry naming a volume that is not there. In WinPE it is
            %HDTOSVolume%, because SystemDrive there is X: - the RAM disk - and
            a teardown pointed at X:\HDT\Boot would delete nothing and report
            success.

            THE STORE COMES FROM THE PHASE TOO. In the full OS the machine booted
            through the store bcdboot wrote, so bare bcdedit already targets it
            and the EFI System Partition needs no drive letter. In WinPE the
            running store is the RAM disk's and is not the one the machine boots
            from, so the teardown names %HDTSystemVolume%'s store explicitly.

            PROVEN AGAINST REAL bcdedit, NOT ONLY AGAINST A FAKE (SPIKES S23).
            The ten create commands were run against a standalone scratch store
            and all returned 0, with the entry enumerating exactly as MDT's does.
            The same probe measured the thing this step's whole shape rests on:
            after MDT's four-command AdjustBCDDefaults, {bootmgr} carries
            default, displayorder AND bootsequence pointing at the WinPE entry,
            and `timeout 0` survives even the teardown. MDT's "boot into WinPE
            once" is therefore permanent, and HDT's single /bootsequence is not.

            NOTHING HERE COPIES A BOOT LOADER. MDT's InstallPE robocopies the
            ADK's efi\ and Boot\ trees over the boot drive and renames
            bootx64.efi to BootMgFW.efi - it replaces the machine's boot manager
            with the ADK's. SPIKES S20 measured that exact file at SVN 3.0
            against an enforced Secure Boot floor of 7.0, so copying MDT more
            faithfully here would DOWNGRADE the one binary the firmware already
            refuses. The ramdisk entry is loaded BY the boot manager bcdboot
            installed from the applied image, as an OSLOADER application, so the
            Secure Boot chain gains nothing new and this path is no worse than
            booting the media.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            Image, FileSystem and Environment services.

        .OUTPUTS
            A New-HDTStepResult. Data carries action, volume, wim, entry and
            store.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Image (New-HDTImageService) -Environment (New-HDTEnvironmentProvider)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFERENCE\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'BootToWinPE' })[0]

            Invoke-HDTBootToWinPEStep -Step $step -Context $context

            One step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTBootToWinPEStep -Step $step -Context $context
            $result.Data['entry']

            The BCD identifier the teardown leg will delete. $step and $context
            are the ones built in the example above.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $component = 'BootToWinPE'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    $letterOf = {
        param([string] $Value)

        $text = ([string] $Value).Trim().TrimEnd('\', '/').TrimEnd(':')
        if ($text.Length -eq 0) { return '' }

        return $text.Substring(0, 1).ToUpperInvariant()
    }

    try {
        $action = Get-HDTStepProperty -Step $Step -Name 'action' -Default 'stage' -Context $Context -Expand -As String
        $bootImage = Get-HDTStepProperty -Step $Step -Name 'bootImage' -Default 'HDTPE_x64' -Context $Context -Expand -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    $action = ([string] $action).Trim().ToLowerInvariant()

    # THE SET COMES FROM Get-HDTStepPropertyChoice, NOT FROM A LIST HERE.
    # That is the same list the console's Action dropdown is built from, so
    # the editor cannot offer a value this step would refuse, and a fourth
    # action added later is offered and accepted by construction rather than
    # by somebody remembering both places (CLAUDE.md 8).
    $known = [string[]] @(Get-HDTStepPropertyChoice -Type 'BootToWinPE' -Key 'action')

    if ($known -notcontains $action) {
        return (& $fail ("step '{0}' asks for action '{1}', which is not one this step type knows. The actions are {2} - stage copies a WinPE onto the local disk, arm points the next boot at it, and remove takes both away again." -f
                $Step.Name, $action, ($known -join ', ')) 'HDTConfigurationError')
    }

    try {
        $imageService = $Context.Service.GetRequired('Image', $component)
        $fileSystem = $Context.Service.GetRequired('FileSystem', $component)
        $environment = $Context.Service.GetRequired('Environment', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where this machine is, and therefore what its volumes are called ----
    #
    # The phase decides, because the same machine calls the same partition two
    # different letters in the two legs. See the header: this is the difference
    # between a BCD entry that boots and one that names a volume which is not
    # there.
    $inWinPe = ([string] $Context.Phase) -eq 'WinPE'

    $volume = ''
    $systemRoot = ''
    $systemVolume = ''

    if ($inWinPe) {
        $volume = & $letterOf ([string] $Context.Variable['HDTOSVolume'])
        if ($volume.Length -eq 0) {
            return (& $fail ("step '{0}' works on the Windows volume and HDTOSVolume is not set. The partition step publishes it, and a resumed leg carries it in state.json." -f
                    $Step.Name) 'HDTConfigurationError')
        }

        $systemRoot = '{0}:\Windows' -f $volume

        # THE STORE MUST BE NAMED IN WinPE. Bare bcdedit there edits the RAM
        # disk's own store, which is not the one this machine boots from, so a
        # teardown without a store path would report success having changed
        # nothing.
        $systemVolume = & $letterOf ([string] $Context.Variable['HDTSystemVolume'])
        if ($systemVolume.Length -eq 0) {
            return (& $fail ("step '{0}' edits the boot configuration on the system partition and HDTSystemVolume is not set. WinPE cannot use the running boot store, because that is the RAM disk's." -f
                    $Step.Name) 'HDTConfigurationError')
        }
    } else {
        $volume = & $letterOf ([string] $environment.GetVariable('SystemDrive'))
        if ($volume.Length -eq 0) {
            return (& $fail ("step '{0}' works on the volume Windows is running from and SystemDrive is not set, which should not be possible on a running machine." -f
                    $Step.Name) 'HDTConfigurationError')
        }

        $systemRoot = [string] $environment.GetVariable('SystemRoot')
        if ([string]::IsNullOrWhiteSpace($systemRoot)) {
            $systemRoot = '{0}:\Windows' -f $volume
        }

        # EMPTY ON PURPOSE. The running machine booted through the store bcdedit
        # already targets, and the EFI System Partition has no drive letter here
        # to name one with.
        $systemVolume = ''
    }

    $gathered = $Context.Variable['HDTIsUEFI']
    $isUefi = $false
    if ($gathered -is [bool]) {
        $isUefi = [bool] $gathered
    } elseif ($null -ne $gathered) {
        $isUefi = ([string] $gathered).Trim() -eq 'True'
    }

    $firmware = 'BIOS'
    if ($isUefi) { $firmware = 'UEFI' }

    $plan = Get-HDTLocalWinPePlan -Volume $volume -DeployRoot ([string] $Context.WorkspaceRoot) `
        -SystemRoot $systemRoot -Firmware $firmware -SystemVolume $systemVolume -BootImageName $bootImage

    $data = [ordered] @{
        action   = $action
        volume   = $plan.RamdiskVolume
        firmware = $firmware
        wim      = $plan.WimPath
        entry    = $plan.EntryId
        store    = $plan.StorePath
    }

    # -- stage --------------------------------------------------------------

    if ($action -eq 'stage') {

        # BOTH SOURCES ARE CHECKED BEFORE EITHER IS COPIED, so a share with no
        # boot image fails without having half-written a staging directory.
        if (-not $fileSystem.TestPath($plan.SourceWimPath)) {
            return (& $fail ("step '{0}' stages a WinPE for the capture boot and there is no boot image at {1}. Build one with Update-HDTBootImage, or name a different one with the step's bootImage property. Nothing has been changed on this machine." -f
                    $Step.Name, $plan.SourceWimPath) 'HDTContentError')
        }

        if (-not $fileSystem.TestPath($plan.SourceSdiPath)) {
            return (& $fail ("step '{0}' stages a WinPE for the capture boot and this machine has no boot.sdi at {1}. Every Windows installation carries one; a machine without it cannot boot a ramdisk image at all. Nothing has been changed on this machine." -f
                    $Step.Name, $plan.SourceSdiPath) 'HDTContentError')
        }

        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ('staging {0} to {1} for the capture boot' -f $plan.SourceWimPath, $plan.WimPath) -Data $data

        try {
            $fileSystem.CreateDirectory($plan.StageDirectory)
            $fileSystem.CopyItem($plan.SourceWimPath, $plan.WimPath)
            $fileSystem.CopyItem($plan.SourceSdiPath, $plan.SdiPath)
        } catch {
            return (& $fail ("step '{0}' could not stage a WinPE to {1}: {2}. The sequence stops here rather than generalizing a machine it cannot bring back." -f
                    $Step.Name, $plan.StageDirectory, [string] $_.Exception.Message) '')
        }

        $message = 'A WinPE is staged at {0} for the capture boot.' -f $plan.WimPath
        Write-HDTLog -Context $Context.Log -Message $message -Component $component -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- arm ----------------------------------------------------------------

    if ($action -eq 'arm') {

        # ARMING A BOOT INTO A FILE THAT IS NOT THERE IS THE WORST OUTCOME OF
        # ALL. bcdedit accepts it, sysprep seals the machine, and the next boot
        # is a black screen and an 0xc000000f on a generalized installation
        # nobody can log into to find out why.
        if (-not $fileSystem.TestPath($plan.WimPath)) {
            return (& $fail ("step '{0}' arms a boot into {1} and nothing is staged there. A BootToWinPE step with action: stage has to run first, and it has to have succeeded. Nothing has been armed." -f
                    $Step.Name, $plan.WimPath) 'HDTConfigurationError')
        }

        # THE STALE ENTRY GOES FIRST, AND ITS FAILURE IS THE ORDINARY CASE.
        # The identifier is fixed, so a second reference build on the same
        # machine would meet its own previous entry and bcdedit /create would
        # refuse. A machine that has never been armed has nothing to delete and
        # bcdedit says so with a non-zero exit code, which is not a problem.
        try {
            $imageService.RemoveBootEntry($plan.StorePath, $plan.EntryId)
        } catch {
            Write-HDTLog -Context $Context.Log -Severity Debug -Component $component `
                -Message ('there was no previous boot entry {0} to clear: {1}' -f $plan.EntryId, [string] $_.Exception.Message)
        }

        Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component $component `
            -Message ('creating the {0} boot entry {1} for {2}' -f $firmware, $plan.EntryId, $plan.WimPath) -Data $data

        try {
            $imageService.AddRamdiskBootEntry($plan.StorePath, $plan.EntryId, $plan.Description,
                $plan.RamdiskVolume, $plan.WimDevicePath, $plan.SdiDevicePath, $plan.LoaderPath)
        } catch {
            return (& $fail ("step '{0}' could not create the boot entry that reaches the staged WinPE: {1}. The sequence stops here rather than generalizing a machine it cannot bring back." -f
                    $Step.Name, [string] $_.Exception.Message) '')
        }

        try {
            # /bootsequence AND NOTHING ELSE. {default} goes on naming Windows,
            # so a machine that never comes back to be torn down boots Windows
            # rather than being stranded in WinPE - which is what MDT's
            # AdjustBCDDefaults does by also setting /default.
            $imageService.SetBootSequenceOnce($plan.StorePath, $plan.EntryId)
        } catch {
            # THE STORE IS THE LIKELY CAUSE AND bcdedit WILL NOT SAY SO.
            # bootsequence is an element on {bootmgr}; a store without one fails
            # with "The system cannot find the file specified", which reads like
            # a missing boot.wim and is not (SPIKES S23.2). Naming the store is
            # what turns that into something a technician can act on.
            return (& $fail ("step '{0}' created the boot entry but could not arm the one-shot boot into it: {1}. The store it wrote to was {2}, and bcdedit reports a missing boot manager in the store the same way it reports a missing file. The sequence stops here rather than generalizing a machine it cannot bring back." -f
                    $Step.Name, [string] $_.Exception.Message,
                    $(if ([string]::IsNullOrWhiteSpace($plan.StorePath)) { 'this machine''s own system store' } else { $plan.StorePath })) '')
        }

        $message = 'The next boot will be the WinPE staged at {0}. The firmware boot order is unchanged.' -f $plan.WimPath
        Write-HDTLog -Context $Context.Log -Message $message -Component $component -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- remove -------------------------------------------------------------
    #
    # WARN AND CONTINUE THROUGHOUT, WHICH IS THE OPPOSITE OF THE TWO ABOVE AND
    # RIGHT FOR THE SAME REASON THEY ARE NOT. This runs after the capture boot
    # has already happened. A cleanup that fails leaves an entry nothing points
    # at, on a machine that is about to be captured and torn down; failing here
    # would cost the capture the whole reference build exists to produce.

    $removed = $false
    try {
        $imageService.RemoveBootEntry($plan.StorePath, $plan.EntryId)
        $removed = $true
    } catch {
        Write-HDTLog -Context $Context.Log -Severity Warning -Component $component `
            -Message ("the boot entry {0} could not be deleted from {1}: {2}. It is not in the display order and is not the default, so this machine still boots Windows; the entry is left behind in the store." -f
                $plan.EntryId, $plan.StorePath, [string] $_.Exception.Message) -Data $data
    }

    # TWO FILES BY NAME, NEVER THE DIRECTORY.
    # CLAUDE.md's delete rules are explicit: delete by -LiteralPath to a
    # specific thing this code created, and never build a delete target by
    # enumerating a parent. <volume>\HDT is the engine's own working tree - it
    # holds state.json, the resume agent and the logs - so a recursive removal
    # aimed at it, or at a directory computed one level below it, is one typo
    # away from taking the run's own state with it.
    $cleared = $false
    foreach ($stale in @($plan.WimPath, $plan.SdiPath)) {
        try {
            # NOT REQUIRED FOR A CLEAN CAPTURE, AND DONE ANYWAY.
            # Templates\Capture\wimscript.ini excludes \HDT as a tree, so the
            # staged WinPE cannot reach the image either way. This is about the
            # machine rather than the image: half a gigabyte nothing will read
            # again, on a volume the capture is about to be written from.
            if ($fileSystem.TestPath($stale)) {
                $fileSystem.RemoveItem($stale, $false)
                $cleared = $true
            }
        } catch {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component $component `
                -Message ("the staged {0} could not be removed: {1}. The capture excludes \HDT, so it will not travel inside the image." -f
                    $stale, [string] $_.Exception.Message) -Data $data
        }
    }

    $data['entryRemoved'] = $removed
    $data['filesRemoved'] = $cleared

    $message = 'The local WinPE and the boot entry that reached it have been removed.'
    Write-HDTLog -Context $Context.Log -Message $message -Component $component -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
