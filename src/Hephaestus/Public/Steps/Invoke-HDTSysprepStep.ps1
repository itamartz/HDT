function Invoke-HDTSysprepStep {
    <#
        .SYNOPSIS
            Generalizes the reference machine, and proves it was generalized.

        .DESCRIPTION
            The first half of DESIGN 9.3's reference-image loop:

              - name: Sysprep
                type: Sysprep
                runIn: FullOS
                unattend: sysprep-unattend.xml    # optional
                timeoutMinutes: 60

            It runs

              %SystemRoot%\system32\sysprep\sysprep.exe /quiet /generalize /oobe /quit

            appending /unattend:<path> when one is configured - MDT's line
            exactly (LTISysprep.wsf:257).

            /quit AND NEVER /shutdown, AND THAT IS NOT A STYLE CHOICE.
            /shutdown cuts the power inside the call: the step never returns,
            never reports success, and can check nothing about what sysprep
            actually did. A step whose only outcome is "the power went out"
            reports the same thing whether it worked or not - and it bypasses
            the checkpoint the WinPE leg resumes from. The reboot is a separate
            Restart step (DESIGN 9.3 notes 1 and 3).

            AN EXIT CODE OF ZERO IS NOT EVIDENCE, so afterwards this reads

              HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State
                  ImageState

            and fails unless it is IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE.
            sysprep can return 0 having declined to generalize, and the reason is
            never on the console - it is in
            %SystemRoot%\system32\sysprep\panther\setupact.log, which is what the
            failure message names. This repository has met the same shape once
            already: reagentc /setreimage exits 0, prints "Operation Successful"
            and registers nothing (DESIGN 9.2 note 5). Where an external tool
            leaves a readable trace of its own result, the step reads the trace.

            TWO PRECONDITIONS, BOTH BEFORE ANYTHING RUNS.

              A DOMAIN MEMBER IS REFUSED. sysprep will not generalize one, and
              Win32_ComputerSystem.DomainRole says so without asking sysprep:
              1, 3, 4 and 5 are the joined roles. Finding this out from sysprep
              means finding it out at the end of a reference build.

              A PENDING FILE RENAME FORCES THE RESTART FIRST. Windows queues
              replacements at
              HKLM\System\CurrentControlSet\Control\Session Manager
              PendingFileRenameOperations, and sysprep refuses while any are
              outstanding. The step returns RebootRequested and lets the existing
              restart machinery clear the queue.

              ONCE, AND ONLY ONCE. HDTSysprepRestarted is the sentinel MDT's own
              guard is built around: a machine whose queue never empties would
              otherwise reboot on every pass for ever, and every one of those
              passes looks like progress in the log. The second time round it is
              a failure naming the queue, not another restart.

            AND IT PROVES Captures\ CAN BE WRITTEN BEFORE IT SEALS ANYTHING.
            That looks like somebody else's business until the cost is written
            down: this step is the point of no return of a reference build, and
            a share the deployment account cannot write turns hours of work into
            a generalized machine that can neither be captured nor resumed.
            DESIGN 9.3 note 5 and ROADMAP M7 both put the check here for that
            reason, and Test-HDTCaptureTarget is the same function the capture
            step calls so the two answers cannot drift.

            IT STRIPS HDT'S OWN RESUME HOOK BEFORE IT GENERALIZES. MDT removes
            LiteTouch.lnk and RunOnce\LiteTouch here; HDT's equivalents are the
            Winlogon autologon values, RunOnce\HDTResume, the LSA secret Winlogon
            reads and the staged answer files - the exact set Clear-HDTAutoLogon
            already removes, which is why this calls it rather than writing the
            registry itself. An image that carried them would log itself in and
            re-enter a finished deployment on the first boot of every machine
            ever built from it.

            THE STAGED AGENT TREE IS NOT DELETED HERE, AND THAT IS DELIBERATE.
            <osvolume>\HDT is excluded from the capture by the shipped
            Templates\Capture\wimscript.ini, which is the reason DESIGN 9.3
            note 7 puts \HDT on that list at all - so it never reaches the image.
            Removing it would destroy the tree this engine is running from with
            the Restart step still to come, which is a deployment that ends
            mid-sequence to tidy up something the exclusion list already handles.

            THE ANSWER FILE IS STAGED AND THEN REMOVED. sysprep reads it from
            %SystemRoot%\system32\sysprep, so a file kept anywhere else is copied
            there and deleted after the call - MDT does the same, and for the
            same reason: an answer file left behind travels inside the captured
            image and answers Setup on every machine built from it.

            IT REPORTS WHILE IT WAITS, BECAUSE IT HAS TO. sysprep prints no meter
            and no percentage; on a real machine it is silent for minutes.
            New-HDTStepHeartbeat turns the process service's poll into a record
            every fifteen seconds saying the machine is alive and how long it has
            been going, which is the only honest thing there is to say.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Its TimeoutMinutes
            becomes the process timeout.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            Cim, Registry, Process and FileSystem services, and an Lsa service
            for the autologon teardown.

        .OUTPUTS
            A New-HDTStepResult. Data carries the command, the exit code, the
            duration and the ImageState that was read back.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Registry (New-HDTRegistryService) -Process (New-HDTProcessService) `
                -Cim (New-HDTCimProvider) -Lsa (New-HDTLsaService) `
                -Environment (New-HDTEnvironmentProvider)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REF-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Sysprep' })[0]

            Invoke-HDTSysprepStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what
            the engine does before the first step; a step cannot be run without
            one.

        .EXAMPLE
            $result = Invoke-HDTSysprepStep -Step $step -Context $context
            $result.Data.imageState

            What the machine says about itself after the call, which is the fact
            this step exists to check. Anything but
            IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE is a Failed result.
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

    $component = 'Sysprep'

    $fail = {
        param([string] $Message, [object] $Data, [int] $ExitCode)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $payload

        return (New-HDTStepResult -Status Failed -ExitCode $ExitCode -Message $Message -Data $payload)
    }

    # -- the services -----------------------------------------------------

    try {
        $cim = $Context.Service.GetRequired('Cim', $component)
        $registry = $Context.Service.GetRequired('Registry', $component)
        $process = $Context.Service.GetRequired('Process', $component)
        $fileSystem = $Context.Service.GetRequired('FileSystem', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null 0)
    }

    # -- precondition: not a domain member --------------------------------
    #
    # THE ROLES ARE MDT'S. 1 Member Workstation, 3 Member Server, 4 Backup
    # Domain Controller, 5 Primary Domain Controller. 0 and 2 are the standalone
    # pair, which is what a reference build is.
    $joinedRole = @(1, 3, 4, 5)

    try {
        $computerSystem = @($cim.GetInstance('Win32_ComputerSystem'))
    } catch {
        return (& $fail ("step '{0}' could not read Win32_ComputerSystem, so it cannot tell whether this machine is a domain member: {1}" -f
                $Step.Name, [string] $_.Exception.Message) $null 0)
    }

    if (@($computerSystem).Count -eq 0) {
        return (& $fail ("step '{0}': Win32_ComputerSystem returned no instance, so it cannot tell whether this machine is a domain member." -f
                $Step.Name) $null 0)
    }

    $domainRole = [int] $computerSystem[0].DomainRole

    if ($joinedRole -contains $domainRole) {
        return (& $fail ("this machine is joined to a domain (Win32_ComputerSystem.DomainRole {0}), and sysprep will not generalize a domain member. A reference build runs in a workgroup; remove the machine from the domain before this step." -f
                $domainRole) ([ordered] @{ domainRole = $domainRole }) 0)
    }

    # -- precondition: nothing queued for the next boot --------------------

    $sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

    $pending = @()
    try {
        $raw = $registry.GetValue($sessionManagerPath, 'PendingFileRenameOperations')
        if ($null -ne $raw) {
            $pending = @(@($raw) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        }
    } catch {
        # ABSENCE IS THE NORMAL CASE and a read that failed is not evidence of a
        # queue. Kept where a debugger can reach it rather than thrown away.
        $pending = @()
        Write-HDTLog -Context $Context.Log -Severity Debug -Component $component `
            -Message ('PendingFileRenameOperations could not be read: {0}' -f [string] $_.Exception.Message)
    }

    if (@($pending).Count -gt 0) {
        $alreadyRestarted = [string] $Context.Variable['HDTSysprepRestarted']

        if ($alreadyRestarted -eq 'true') {
            # THE SENTINEL EARNING ITS PLACE. One restart is a queue being
            # cleared; two is a machine that will do this for ever, and every
            # pass of it looks like progress.
            return (& $fail ("{0} file rename(s) are still pending after a restart, and sysprep will not generalize while any are outstanding. Something on this machine is re-queueing them; clear it before the reference build reaches this step." -f
                    @($pending).Count) ([ordered] @{ pendingCount = @($pending).Count }) 0)
        }

        $Context.Variable['HDTSysprepRestarted'] = 'true'

        $message = '{0} file rename(s) are pending, and sysprep will not generalize until they are applied. Restarting first.' -f @($pending).Count

        Write-HDTLog -Context $Context.Log -Message $message -Component $component `
            -Data ([ordered] @{ pendingCount = @($pending).Count })

        return (New-HDTStepResult -Status RebootRequested -Message $message `
                -Data ([ordered] @{ pendingCount = @($pending).Count }))
    }

    # -- can this build be captured at all, while the answer is still cheap --
    #
    # THE LAST MOMENT IT COSTS NOTHING. DESIGN 9.3 note 5 puts this check BEFORE
    # the Sysprep step rather than at the moment of writing, and ROADMAP M7's
    # capture exit says it in its own words: "the Captures\ write was proven
    # before sysprep ran, not after the build". A reference build is hours of
    # installing and customizing; finding out at the end of it that the account
    # cannot write Captures\ costs the whole run - and costs it after the
    # machine has been generalized and can no longer be picked up where it left
    # off. This probe is milliseconds against an ordinary running Windows.
    #
    # SYSPREP EXISTS HERE FOR THE CAPTURE, WHICH IS WHY THIS BELONGS TO IT.
    # DESIGN 9.3 is the only place this step type appears at all: it generalizes
    # a machine so that the WinPE leg can read it into a WIM. A Sysprep step that
    # sealed a machine no capture could ever be written from has done nothing
    # anybody wanted, and would have destroyed the run to find out.
    #
    # Test-HDTCaptureTarget IS THE SAME FUNCTION Invoke-HDTCaptureImageStep
    # CALLS, so the early answer and the late one cannot disagree.
    $target = Test-HDTCaptureTarget -Context $Context -FileSystem $fileSystem

    if (-not $target.Ok) {
        return (& $fail ([string] $target.Message) ([ordered] @{ errorId = [string] $target.ErrorId }) 0)
    }

    # -- where Windows is --------------------------------------------------
    #
    # FROM THE INJECTED ENVIRONMENT, NEVER FROM $env:. A step may not read the
    # process environment directly (PROJECT constraint 4), and a machine whose
    # Windows is not on C: is exactly the machine an assumption breaks on.
    $systemRoot = 'C:\Windows'
    if ($null -ne $Context.Service.Environment) {
        $fromEnvironment = [string] $Context.Service.Environment.GetVariable('SystemRoot')
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
            $systemRoot = $fromEnvironment.TrimEnd('\')
        }
    }

    $sysprepDirectory = [System.IO.Path]::Combine($systemRoot, 'system32\sysprep')
    $sysprepExe = [System.IO.Path]::Combine($sysprepDirectory, 'sysprep.exe')
    $setupActLog = [System.IO.Path]::Combine($sysprepDirectory, 'panther\setupact.log')

    # -- the answer file ---------------------------------------------------

    try {
        $unattendProperty = Get-HDTStepProperty -Step $Step -Name 'unattend' -Default '' -Context $Context -Expand -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null 0)
    }

    $stagedUnattend = ''

    if (-not [string]::IsNullOrWhiteSpace($unattendProperty)) {
        $source = $unattendProperty

        # RELATIVE TO THE SEQUENCE FOLDER, WHICH IS ApplyUnattend'S RULE AND FOR
        # ApplyUnattend'S REASON: that is where New-HDTTaskSequence puts the
        # answer files a sequence names, so an author writes the file name and
        # nothing else. No literal 'TaskSequences' here - the workspace layout
        # has one owner and it is Get-HDTWorkspacePath.
        if (-not [System.IO.Path]::IsPathRooted($source)) {
            $sequenceId = ''
            if ($null -ne $Context.State -and $null -ne $Context.State.PSObject.Properties['sequenceId']) {
                $sequenceId = [string] $Context.State.sequenceId
            }

            if ([string]::IsNullOrWhiteSpace($sequenceId)) {
                $sequenceId = [string] $Context.Variable['HDTTaskSequenceID']
            }

            if ([string]::IsNullOrWhiteSpace($sequenceId)) {
                return (& $fail ("step '{0}' names a sysprep answer file relative to the sequence folder, and this run does not know which sequence it is running. Set HDTTaskSequenceID, or give the file a rooted path." -f
                        $Step.Name) $null 0)
            }

            $source = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind TaskSequences `
                -ChildPath $sequenceId, $source
        }

        if (-not $fileSystem.TestPath($source)) {
            return (& $fail ("step '{0}' names the sysprep answer file '{1}', and it is not there. This is the generalize-pass document, not the deployment's own unattend.xml." -f
                    $Step.Name, $source) ([ordered] @{ unattend = $source }) 0)
        }

        $stagedUnattend = [System.IO.Path]::Combine($sysprepDirectory, 'unattend.xml')
    }

    # -- HDT's own resume hook, before anything is generalized -------------
    #
    # THE ORDER IS LOAD-BEARING TWICE OVER. The registry has to be clean at the
    # instant the machine is sealed, because that registry is what the capture
    # reads - and Clear-HDTAutoLogon's own list of staged answer files includes
    # %SystemRoot%\System32\Sysprep\unattend.xml, so it must run BEFORE this
    # step stages one there rather than after.
    try {
        $lsa = $Context.Service.GetRequired('Lsa', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null 0)
    }

    try {
        $cleared = Clear-HDTAutoLogon -Registry $registry -Lsa $lsa -FileSystem $fileSystem -Confirm:$false

        Write-HDTLog -Context $Context.Log -Component $component `
            -Message ("cleared {0} resume artefact(s) before generalizing; an image that kept them would re-enter this deployment on every machine built from it." -f
                @($cleared.Cleared).Count) `
            -Data ([ordered] @{ cleared = [string[]] @($cleared.Cleared) })
    } catch {
        return (& $fail ("the deployment's own resume hook could not be removed, and generalizing with it in place would put it inside the captured image: {0}" -f
                [string] $_.Exception.Message) $null 0)
    }

    # -- stage the answer file ---------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($stagedUnattend)) {
        try {
            $fileSystem.CopyItem($source, $stagedUnattend)
        } catch {
            return (& $fail ("the sysprep answer file '{0}' could not be staged at '{1}': {2}" -f
                    $source, $stagedUnattend, [string] $_.Exception.Message) $null 0)
        }
    }

    # -- the call ----------------------------------------------------------

    $argument = '/quiet /generalize /oobe /quit'
    if (-not [string]::IsNullOrWhiteSpace($stagedUnattend)) {
        $argument = '{0} /unattend:{1}' -f $argument, $stagedUnattend
    }

    $timeoutMillisecond = 0
    if ([int] $Step.TimeoutMinutes -gt 0) {
        $timeoutMillisecond = [int] $Step.TimeoutMinutes * 60000
    }

    $commandLine = '{0} {1}' -f $sysprepExe, $argument

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component $component `
        -Message ('generalizing this machine: {0}' -f $commandLine) `
        -Data ([ordered] @{ file = $sysprepExe; timeoutMs = $timeoutMillisecond })

    # THE FIRST FRAME, WRITTEN BEFORE THE WAIT RATHER THAN AFTER IT. sysprep
    # prints nothing at all - no banner, no meter, no line - so without this the
    # progress card's last word before a silence of minutes would be the step's
    # own name, which says nothing about what the machine is doing.
    #
    # THROUGH THE LOG, NEVER THROUGH A CHANNEL OF ITS OWN (DESIGN 11.1): the
    # record goes to the JSONL and the display is asked to re-read it, so the
    # screen and the log cannot disagree.
    # heartbeat, NOT A PERCENT, AND THE MARK IS WHAT MAKES THAT READABLE. sysprep
    # reports nothing at all, so this record and the ones New-HDTStepHeartbeat
    # writes after it are the same kind of thing: a sign of life. A reader cannot
    # test for the ABSENCE of a percent, so without the mark the opener sat in
    # the measurement stream looking like a measurement.
    Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component $component `
        -Message 'generalizing this machine; sysprep reports nothing until it is finished' `
        -Data ([ordered] @{ activity = 'sysprep /generalize'; file = $sysprepExe; heartbeat = $true })

    Update-HDTProgressDisplay -Context $Context

    # AND THE MINUTES AFTER IT. sysprep is silent for the whole of them, so the
    # process service polls and this turns each poll into a record every fifteen
    # seconds - the machine is alive, and this is how long it has been going.
    # New-HDTStepHeartbeat owns the shape, the interval and the rationing.
    $heartbeat = New-HDTStepHeartbeat -Context $Context -Component $component `
        -Activity 'generalizing this machine with sysprep'

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    try {
        $result = $process.Start($sysprepExe, $argument, $sysprepDirectory, $timeoutMillisecond, $heartbeat)
    } catch {
        return (& $fail ("sysprep could not be run: {0}" -f [string] $_.Exception.Message) $null 0)
    } finally {
        # THE ANSWER FILE DOES NOT TRAVEL INSIDE THE IMAGE. In a finally, so a
        # sysprep that threw does not leave one site's document in the folder
        # Setup reads on every machine ever built from this volume.
        if (-not [string]::IsNullOrWhiteSpace($stagedUnattend)) {
            try {
                if ($fileSystem.TestPath($stagedUnattend)) { $fileSystem.RemoveItem($stagedUnattend, $false) }
            } catch {
                Write-HDTLog -Context $Context.Log -Severity Warning -Component $component `
                    -Message ("the staged sysprep answer file '{0}' could not be removed; it will be captured with the image unless it is deleted by hand." -f $stagedUnattend)
            }
        }
    }

    $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds

    # SYSPREP'S OWN OUTPUT, INTO THE LOG (DESIGN 12.2.3). It prints little, and
    # what it prints on a failure is the only sentence worth having.
    foreach ($stream in @($result.StandardOutput, $result.StandardError)) {
        foreach ($line in @([string] $stream -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            Write-HDTLog -Context $Context.Log -Message $line -Component $component -Source $sysprepExe
        }
    }

    $exitCode = [int] $result.ExitCode

    $data = [ordered] @{
        file       = $sysprepExe
        exitCode   = $exitCode
        durationMs = $durationMillisecond
    }

    if ([bool] $result.TimedOut) {
        return (& $fail ("sysprep timed out after {0} minute(s) and was stopped. A generalize that runs this long is normally waiting on a provisioned appx package; the detail is in {1}." -f
                $Step.TimeoutMinutes, $setupActLog) $data $exitCode)
    }

    if ($exitCode -ne 0) {
        return (& $fail ("sysprep returned {0}. The reason is in {1}." -f $exitCode, $setupActLog) $data $exitCode)
    }

    # -- what it actually did ----------------------------------------------
    #
    # NOT WHAT IT RETURNED. sysprep can exit 0 having declined to generalize,
    # and nothing about the run looks wrong afterwards - which on a reference
    # build means a WIM that is a copy of one machine, deployed to a fleet.
    $sealed = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
    $statePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'

    $imageState = ''
    try {
        $imageState = [string] $registry.GetValue($statePath, 'ImageState')
    } catch {
        $imageState = ''
    }

    $data['imageState'] = $imageState

    if ($imageState -ne $sealed) {
        $said = "'(not set)'"
        if (-not [string]::IsNullOrWhiteSpace($imageState)) { $said = "'{0}'" -f $imageState }

        return (& $fail ("sysprep returned 0 but this machine reports ImageState {0}, not {1}, so it was not generalized. An image captured now would be a copy of this one machine. The reason is in {2}." -f
                $said, $sealed, $setupActLog) $data $exitCode)
    }

    $message = 'sysprep generalized this machine in {0} ms; ImageState is {1}.' -f $durationMillisecond, $sealed

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component $component -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -ExitCode $exitCode -Message $message -Data $data)
}
