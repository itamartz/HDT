function Invoke-HDTTaskSequence {
    <#
        .SYNOPSIS
            Runs a flattened task sequence: ordering, conditions, retry,
            reboot-and-resume, and the finally teardown that makes autologon
            safe.

        .DESCRIPTION
            The execution loop. It takes an imported sequence and an
            execution context and returns:

              Status      Succeeded | Failed | RebootPending
              State       the state document as it stands
              Result      one row per step the loop reached, in order
              FailedStep  the flattened step that ended the run, or $null

            THE BRANCH ORDER PER STEP IS THE DESIGN, and each branch is a test:

              1. already Completed or Skipped on a previous leg  -> step.skip
              2. left Running by an interrupted leg              -> resumable:
                 true re-runs it, anything else FAILS THE RUN
              2a. the administrator disabled the step             -> step.skip
              3. runIn does not match this leg's phase           -> step.skip
              4. a group condition is false, outermost first     -> step.skip,
                 naming THE GROUP
              5. the step's own condition is false               -> step.skip
              6. the step type says it does not apply            -> step.skip
              7. run it

            Case 2 is the one worth spelling out. A step recorded Running was
            started and never finished - the machine rebooted, or the power went.
            Re-running it silently would repeat half-applied work; skipping it
            silently would build on work that never happened. So HDT refuses,
            names the step, and says what `resumable: true` would have done.

            CHECKPOINTS BRACKET EVERY STEP. The state is saved when a step is
            marked Running and again when its outcome is known, which is what
            makes case 2 detectable at all. The live variable dictionary is
            copied into the state on every save, so a variable a step set in
            WinPE is there for a condition in the full OS.

            THE REBOOT CEREMONY IS ORDERED, and the order is an argument rather
            than a preference:

              1. mark the step Completed, advancing stepIndex past it - or
                 Pending, leaving it, when the step asked to be re-entered
              2. SAVE
              3. take (or generate) the deployment password
              4. Set-HDTAutoLogon for 1 + the Restart steps still ahead
              5. SAVE again, so autoLogon.armed is durable
              6. status heartbeat
              7. IPowerService.Restart

            STEP 1'S SECOND HALF IS 07-02's. A step that owns a LIST - the
            InstallApplications step, which gets a 3010 halfway through and needs
            the reboot to come back to it - returns
            New-HDTStepResult -Reenter. Recording it Completed would advance
            stepIndex past it and silently skip every application after the one
            that asked for the restart, so the run would report success having
            installed half the software. Pending leaves stepIndex where it is:
            the next leg runs the step again, and the step picks up from the
            progress it checkpointed into a variable. Everything else about the
            ceremony is identical, which is why Reenter changes one assignment
            rather than adding a branch to the ceremony.

            If arming succeeded and the save then failed, the machine would
            reboot, autologon, and resume at the OLD index - re-running the
            Restart step, which reboots again: an infinite loop that needs a
            technician and a boot menu. If the save succeeds and arming then
            fails, the machine reboots and stops at the logon screen: stuck, but
            safe and diagnosable. Between a loop and a stop, choose the stop.

            REMAININGLEG IS A BOUND, NOT A PREDICTION. It is one for this reboot
            plus one for every Restart step still ahead, but a CommandLine step
            returning 3010 can add a leg nobody counted. Every arm re-sets the
            count, so the bound is refreshed on each reboot and Windows'
            AutoLogonCount backstop stays the third line of defence rather than
            the first.

            TEARDOWN RUNS FROM finally, NOT FROM A STEP. A cleanup that is
            itself a step is one any earlier failure skips, leaving autologon
            armed. Here every terminal outcome - success, failure, a
            thrown exception, even a failed checkpoint - runs the autologon
            checklist. The one outcome that does NOT tear down is RebootPending:
            the machine has to stay armed to come back.

            The finally runs: clear the step, stamp the run status, checkpoint,
            TEAR DOWN, log run.end, write the heartbeat, copy the logs back. The
            teardown comes before run.end so the copied-back log carries its
            record, and so run.end is genuinely the last line of the run.

            PAUSEONERROR DOES NOT PROMPT. The LTISuspend equivalent is
            read from the state document; when it is set and a step fails
            terminally, the loop logs at Error that the run is paused, writes the
            heartbeat and RETURNS with the state loaded. Dropping to a live
            prompt belongs to the caller (Start-HDTDeployment, phase 05): an
            engine that blocked on input could not be unit tested and would hang
            CI.

            TIMEOUTS ARE NOT PRE-EMPTIVE. `timeoutMinutes` is passed to the step
            - only CommandLine can enforce it, through IProcessService - and
            measured by the loop afterwards. HDT does not preempt a synchronous
            step: one that hangs in-process hangs the sequence. Running steps in
            a child runspace is a post-v1 idea, and ForEach-Object -Parallel is
            not available to an engine that must run under Windows PowerShell
            5.1.

        .PARAMETER Sequence
            An Import-HDTSequenceDocument result. Its Step list is already
            flattened into execution order.

        .PARAMETER Context
            A New-HDTExecutionContext context. Everything the loop touches -
            filesystem, clock, registry, LSA, power - comes from its service
            catalog, so the whole engine runs under Pester against fakes.

        .PARAMETER State
            An existing run state, which is what a resume is. Without one a fresh
            document is built from the sequence.

        .PARAMETER StatePath
            Where to checkpoint. Defaults to state.json in the log directory,
            which is where the log directory listing puts it. A caller
            that follows the X:\HDT\state.json convention - Start-HDTResume.ps1
            does - passes it explicitly.

        .PARAMETER MirrorStatePath
            A second location for the same document, conventionally the target
            volume once one is formatted. The mirror is what makes the WinPE to
            full-OS transition survivable.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. Without one the loop discovers
            once per run and hands the same registry to every dispatch.

        .PARAMETER StatusPath
            Where to write the status.json heartbeat. Defaults to
            status.json in the log directory.

        .PARAMETER LogDestination
            The share's log root. When given, the log directory is copied back at
            the end of the run - on failure too, because a deployment that dies
            is exactly when the logs matter.

        .PARAMETER AutoLogonUserName
            The account the reboot ceremony arms autologon for. Defaults to
            Administrator, MDT's model.

        .PARAMETER AutoLogonDomainName
            That account's domain. Empty for a workgroup machine, which is what a
            machine mid-deployment normally is.

        .PARAMETER ResumeCommand
            What RunOnce launches at logon. Passed through to Set-HDTAutoLogon,
            which defaults it to Start-HDTResume.ps1.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Status, State,
            Result and FailedStep.

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE ``
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) ``
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $state = New-HDTRunState -SequenceId 'DEMO-05' -RunId 'run-0001' -Phase WinPE ``
                -Clock $clock -Variable ([ordered] @{}) -Step @($sequence.Step)
            $run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context `
                -StatePath 'X:\HDT\state.json' -MirrorStatePath 'W:\HDT\state.json'

            if ($run.Status -eq 'RebootPending') { return }

        .EXAMPLE
            Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state

            The second leg, resumed from the state the first one checkpointed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Sequence,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $StatePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $MirrorStatePath,

        # THIS LEG IS CONTINUING A RUN, NOT STARTING ONE.
        #
        # Set by Start-HDTDeployment.ps1 when Get-HDTResumeCandidate has found a
        # task sequence already in progress on this machine's disk. It turns on
        # the guard at the top of the loop, which refuses the step types that
        # would destroy the installation the run exists to finish.
        #
        # NOT INFERRED FROM state.leg, DELIBERATELY. A leg number greater than
        # one says the run has rebooted, which is true of the ordinary full-OS
        # leg as well - and that leg legitimately runs steps this refuses on a
        # WinPE one. The caller knows which discovery got it here; the loop
        # should not have to guess.
        [Parameter()]
        [switch] $Resumed,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $StatusPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $LogDestination,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AutoLogonUserName = 'Administrator',

        [Parameter()]
        [AllowEmptyString()]
        [string] $AutoLogonDomainName = '',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ResumeCommand
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $log = $Context.Log
    $fileSystem = $Context.Service.FileSystem
    $clock = $Context.Service.Clock

    $logRoot = ([string] $log.LogPath).TrimEnd('\', '/')

    $statePathValue = '{0}\state.json' -f $logRoot
    if ($PSBoundParameters.ContainsKey('StatePath')) {
        $statePathValue = $StatePath
    }

    $statusPathValue = '{0}\status.json' -f $logRoot

    # WHERE A CONSOLE WATCHING THIS SHARE LOOKS. <share>\Logs\_active\<RunId>.json
    # is what Get-HDTConsoleMonitor tails, and -LogDestination is already the
    # share's Logs folder - the same one the copy-back ships to at the end. This
    # is MDT's SLShareDynamicLogging: the END of a run has always been reported;
    # this is the part that says a machine is still working.
    #
    # NO DESTINATION, NO MIRROR. A full-OS leg that could not reach the share
    # still deploys, and Write-HDTStatus writes locally either way.
    $activeStatusPath = ''
    if ($PSBoundParameters.ContainsKey('LogDestination') -and
        -not [string]::IsNullOrWhiteSpace($LogDestination)) {

        $activeStatusPath = '{0}\_active\{1}.json' -f
            $LogDestination.TrimEnd('\', '/'), $Context.RunId
    }
    if ($PSBoundParameters.ContainsKey('StatusPath')) {
        $statusPathValue = $StatusPath
    }

    $stepList = [object[]] @($Sequence.Step)

    if (-not $PSCmdlet.ShouldProcess([string] $Sequence.Id, ('Run {0} task sequence step(s)' -f $stepList.Count))) {
        return
    }

    # -- what the engine is running, said out loud ---------------------------
    #
    # MDT's TaskSequenceID, TaskSequenceName and TaskSequenceVersion, and they
    # are published HERE rather than by whichever payload chose the sequence
    # because this is the only place that is holding the document. Both payloads
    # come through it, and so does every leg after a reboot - which is what
    # makes them true of the leg rather than only of the first boot.
    #
    # THE ID WAS AN INPUT AND NEVER AN OUTPUT, and the gap had a misleading
    # error on the end of it. A sequence is chosen three ways - -SequenceId,
    # bootstrap.json's sequenceId, or the HDTTaskSequenceID variable - and only
    # the third left the variable set. A PXE deployment driven by bootstrap.json
    # therefore reached ApplyUnattend, which resolves a relative template
    # against the sequence folder, and was refused with "this run does not know
    # which sequence it is running. Set HDTTaskSequenceID" - naming a variable
    # the administrator had deliberately not used, about a fact the engine was
    # holding in its hand.
    #
    # IT OVERWRITES. A rule can resolve HDTTaskSequenceID to one id while the
    # command line chose another; the sequence being executed is the truth, and
    # a variable that says otherwise sends a technician to read the wrong
    # sequence's steps. MDT overwrites it for the same reason.
    $Context.Variable['HDTTaskSequenceID'] = [string] $Sequence.Id
    $Context.Variable['HDTTaskSequenceName'] = [string] $Sequence.Name

    # Sequence documents written before 'version' existed have no such property
    # at all, and under Set-StrictMode -Version Latest reading one is a
    # terminating error - so this asks before it reads, and publishes an empty
    # string either way.
    $sequenceVersion = ''
    if ($null -ne $Sequence.PSObject.Properties['Version']) {
        $sequenceVersion = [string] $Sequence.Version
    }
    $Context.Variable['HDTTaskSequenceVersion'] = $sequenceVersion

    $state = $State
    if ($null -eq $state) {
        $state = New-HDTRunState -SequenceId ([string] $Sequence.Id) -RunId ([string] $Context.RunId) `
            -Phase ([string] $Context.Phase) -Clock $clock -Variable $Context.Variable -Step $stepList `
            -LogLevel ([string] $log.Level)
    }

    $Context.State = $state

    $saveArgument = @{ Path = $statePathValue; FileSystem = $fileSystem; Clock = $clock }
    if ($PSBoundParameters.ContainsKey('MirrorStatePath')) {
        $saveArgument['MirrorPath'] = $MirrorStatePath
    }

    $outcome = New-Object -TypeName System.Collections.ArrayList
    $failedStep = $null
    $runStatus = 'Succeeded'

    # The live dictionary is the truth while the run is executing and the state
    # document is the truth across a reboot, so every checkpoint copies one into
    # the other. Without this a variable set in WinPE is gone by the full OS.
    #
    # The log's seq goes with them, because DESIGN 4.4.2 requires the monotonic
    # counter to survive a reboot: the next leg seeds its log context from this
    # number, and a leg that restarted at 1 would make the ordering of a
    # multi-leg deployment exactly as ambiguous as the counter exists to prevent.
    $saveState = {
        foreach ($name in @($Context.Variable.Keys)) {
            $state.variable[[string] $name] = $Context.Variable[$name]
        }

        $state.seq = [long] $log.Seq

        # AND THE LEVEL GOES WITH IT, for the reason the line above exists: the
        # next leg builds its log context from this document, before the share
        # is reachable and before anything could re-read workspace.yaml. A leg
        # that could not find the level defaulted to Info, so a run started at
        # Debug went silent at the reboot - and the full-OS leg is where the
        # applications install.
        #
        # THE STATE PASSED IN IS COVERED TOO, WHICH IS WHY IT IS HERE RATHER
        # THAN ONLY AT New-HDTRunState ABOVE: Start-HDTDeployment.ps1 builds the
        # document itself and hands it over, so a level set only at construction
        # would be right in a test and wrong on every real deployment. Older
        # documents grow the property rather than throwing on the assignment -
        # a PSCustomObject does not add one when assigned to.
        if (@($state.PSObject.Properties | ForEach-Object { $_.Name }) -notcontains 'logLevel') {
            $state | Add-Member -MemberType NoteProperty -Name 'logLevel' -Value ([string] $log.Level)
        } else {
            $state.logLevel = [string] $log.Level
        }

        Save-HDTRunState -State $state @saveArgument
    }

    # Captured, because $PSBoundParameters is scoped to the function's own param
    # block and is EMPTY inside a scriptblock invoked with &. The relocation
    # below reads these from the loop body, where that trap does not apply - but
    # a later refactor that moves the block into a scriptblock would silently
    # start overruling a caller who named a path, so they are read once here.
    $mirrorStateWasGiven = $PSBoundParameters.ContainsKey('MirrorStatePath')
    $statusPathWasGiven = $PSBoundParameters.ContainsKey('StatusPath')

    $reportUnresolved = {
        param([object] $Unresolved, [string] $Where)

        if (@($Unresolved).Count -eq 0) {
            return
        }

        Write-HDTLog -Context $log -Severity Warning `
            -Message ("{0} names {1} variable token(s) nothing has supplied: {2}. The token is left literal and the comparison is false." -f
                $Where, @($Unresolved).Count, (@($Unresolved) -join ', ')) `
            -Data ([ordered] @{ unresolved = [string[]] @($Unresolved) })
    }

    $skipStep = {
        param([int] $Index, [object] $Step, [string] $Reason)

        Update-HDTRunStateStep -State $state -Index $Index -Status Skipped -Message $Reason -Leg ([int] $state.leg) | Out-Null
        & $saveState

        Write-HDTLog -Context $log -Event 'step.skip' -Message $Reason `
            -Data ([ordered] @{ index = $Index; name = [string] $Step.Name; type = [string] $Step.Type; reason = $Reason })

        [void] $outcome.Add([pscustomobject] ([ordered] @{
                    Index        = $Index
                    Name         = [string] $Step.Name
                    Type         = [string] $Step.Type
                    Status       = 'Skipped'
                    ExitCode     = 0
                    Message      = $Reason
                    Attempt      = 0
                    DurationMs   = [long] 0
                    TimedOut     = $false
                    FailureClass = $null
                    Reason       = $Reason
                }))
    }

    Write-HDTLog -Context $log -Event 'run.start' `
        -Message ("Run {0} starting at step {1} of {2} in the {3} phase (leg {4})" -f
            $Context.RunId, $state.stepIndex, $stepList.Count, $Context.Phase, $state.leg) `
        -Data ([ordered] @{
            sequenceId = [string] $Sequence.Id
            stepIndex  = [int] $state.stepIndex
            stepCount  = $stepList.Count
            leg        = [int] $state.leg
        })

    # DID THIS MACHINE BOOT INTO THE ENVIRONMENT ITS NEXT STEP NEEDS?
    #
    # THE SILENT FAILURE, AND THE WORST SHAPE OF THE THREE THIS FILE GUARDS.
    #
    # Resuming AT step N means step N is the next thing to do. If it cannot be
    # done in this phase, the machine has booted into the wrong environment -
    # and that is a fact about the machine, not a step to skip past.
    #
    # WHAT IT CATCHES, MEASURED ON REAL HARDWARE ON 2026-08-31. A reference
    # build restarts into Windows after ConfigureBoot, and with
    # setBootOrder: false it does not get there: the media is still first in the
    # firmware order and the machine comes straight back into WinPE. Before the
    # WinPE-side resume existed that was a VISIBLE stall - a new run, the Welcome
    # wizard, a deployment stopped at step 8 of 12.
    #
    # WITH RESUME AND WITHOUT THIS IT BECOMES SILENT AND WRONG, which is worse.
    # The boot finds the state document and resumes at the first full-OS step;
    # that step and the three after it - Customize, Sysprep, the second Restart -
    # are all FullOS, so the PHASE FILTER SKIPS EVERY ONE. Then it reaches
    # CaptureImage, which is WinPE, and captures a machine that was never
    # customized and never generalized. The run reports success and the WIM
    # looks like a WIM.
    #
    # NARROW ON PURPOSE: THE RESUME POINT ONLY. A phase skip in the MIDDLE of a
    # sequence is legitimate and is tested - a full-OS leg passing over a
    # WinPE-only step is how valid-reboot-legs.yaml ends. What cannot be right is
    # the very step the run stopped at being undoable here.
    if ($Resumed -and [int] $state.stepIndex -ge 1 -and [int] $state.stepIndex -le $stepList.Count) {
        $resumeStep = $stepList[[int] $state.stepIndex - 1]

        if (-not (Test-HDTStepRunInPhase -RunIn ([string] $resumeStep.RunIn) -Phase ([string] $Context.Phase))) {
            $reason = "this machine resumed a task sequence at step {0} '{1}', which must run in the {2} phase - but it has booted into {3}. The run has NOT been continued and nothing has been changed on this disk. A reference build reaches this when the restart before it was meant to land in Windows and landed back on the boot media instead, which is what the firmware boot order decides: check the ConfigureBoot step's setBootOrder property and which device this machine prefers to boot. Continuing would silently skip every {2} step and run only the ones this phase can reach, which on a capture sequence means capturing a machine that was never prepared." -f
                [int] $state.stepIndex, [string] $resumeStep.Name, [string] $resumeStep.RunIn, [string] $Context.Phase

            # run.end AND NOT A NEW EVENT NAME. The vocabulary is a closed set
            # (LogEventVocabulary.Contract), and this IS the end of the run -
            # the earliest possible one, before a single step is attempted.
            Write-HDTLog -Context $log -Severity Error -Event 'run.end' -Message $reason `
                -Data ([ordered] @{
                    stepIndex = [int] $state.stepIndex
                    name      = [string] $resumeStep.Name
                    runIn     = [string] $resumeStep.RunIn
                    phase     = [string] $Context.Phase
                })

            return [pscustomobject] ([ordered] @{
                    Status  = 'Failed'
                    RunId   = [string] $Context.RunId
                    Message = $reason
                    Result  = [pscustomobject[]] @()
                    State   = $state
                })
        }
    }

    # HOW MANY STEPS THIS RUN HAS, set once and carried by every heartbeat from
    # here on. The console tailing Logs\_active\ shows "step 7 of 12", and it
    # cannot count them itself - it is reading a share, not running a sequence.
    $log.StepCount = $stepList.Count

    Write-HDTStatus -Context $log -Path $statusPathValue -Status 'Running' -ActivePath $activeStatusPath

    if ([string] $Context.Phase -ne [string] $state.phase) {
        Write-HDTLog -Context $log -Event 'phase.change' `
            -Message ("The deployment moved from the {0} phase to the {1} phase" -f $state.phase, $Context.Phase) `
            -Data ([ordered] @{ from = [string] $state.phase; to = [string] $Context.Phase })

        $state.phase = [string] $Context.Phase
    }

    try {
        $registry = $StepType
        if ($null -eq $registry) {
            $registry = @(Get-HDTStepType)
        }

        for ($index = [int] $state.stepIndex; $index -le $stepList.Count; $index++) {

            $step = $stepList[$index - 1]
            $stepName = [string] $step.Name
            $stepTypeName = [string] $step.Type

            # READ OFF THE CONTEXT, NOT OFF $logRoot. Once DESIGN 4.4.1's
            # relocation has fired, the log root is on the target volume and a
            # step log built from the captured value would write half its lines
            # to a RAM disk that is about to disappear.
            $currentLogRoot = ([string] $log.LogPath).TrimEnd('\', '/')

            $stepLogPath = '{0}\Steps\{1}' -f $currentLogRoot, (Get-HDTStepLogName -Index $index -Name $stepName)
            if (-not [string]::IsNullOrWhiteSpace([string] $step.Log)) {
                # DESIGN 4.4.4: a step may declare its own log file, in addition
                # to the master.
                $stepLogPath = '{0}\{1}' -f $currentLogRoot, [string] $step.Log
            }

            $Context.Attempt = 1
            $Context.SetStep($index, $stepName, $stepTypeName, $stepLogPath)

            # 0. A RESUMED LEG MAY NOT DESTROY THE MACHINE IT RESUMED ONTO.
            #
            #    THE STRUCTURAL HALF OF THE WinPE-SIDE RESUME (DESIGN 4.3.1).
            #    Get-HDTResumeCandidate decides that a run is in progress; this
            #    is what stops the leg it hands over formatting the disk anyway.
            #
            #    BEFORE THE ALREADY-DONE CHECK, AND THAT ORDER IS THE WHOLE
            #    POINT. On a real capture leg this never fires: the loop starts
            #    at state.stepIndex, which is past the partition step, so the
            #    step is not even visited. It fires only when stepIndex has come
            #    back WRONG - and the very next check below would look that step
            #    up in the same state document, find it recorded Completed, and
            #    skip it. A guard placed after that check is dead code in
            #    precisely the case it exists for, because it would be trusting
            #    the document it is there to disbelieve.
            #
            #    IT FAILS RATHER THAN SKIPS. A skip is quieter and lets the run
            #    go on to capture whatever happens to be on the disk. A resumed
            #    leg that reaches one of these has a defect in it, and this is
            #    how anybody finds out.
            if ($Resumed -and (Test-HDTResumeStepForbidden -Step $step)) {
                $reason = "step {0} '{1}' is a {2} step and this leg is RESUMING a task sequence that is already in progress. A resumed leg runs on a machine that has already been deployed, so a step that formats a disk or overwrites the Windows volume would destroy the installation this run exists to finish. HDT refuses rather than skipping, because a resumed leg that reaches this step means its state document is wrong about where the run had got to - and that is worth stopping for. If this machine really should be deployed from the beginning, delete its state document and boot it again." -f $index, $stepName, $stepTypeName

                Update-HDTRunStateStep -State $state -Index $index -Status Failed -Message $reason -Leg ([int] $state.leg) | Out-Null
                & $saveState

                Write-HDTLog -Context $log -Severity Error -Event 'step.fail' -Message $reason `
                    -Data ([ordered] @{ index = $index; name = $stepName; type = $stepTypeName; resumed = $true })

                [void] $outcome.Add([pscustomobject] ([ordered] @{
                            Index        = $index
                            Name         = $stepName
                            Type         = $stepTypeName
                            Status       = 'Failed'
                            ExitCode     = 0
                            Message      = $reason
                            Attempt      = 0
                            DurationMs   = [long] 0
                            TimedOut     = $false
                            FailureClass = 'Configuration'
                            Reason       = $reason
                        }))

                $failedStep = $step
                $runStatus = 'Failed'
                break
            }

            $found = @(@($state.step) | Where-Object { [int] $_.index -eq $index })
            $recorded = $null
            if ($found.Count -eq 1) {
                $recorded = $found[0]
            }

            # 1. Already done on a previous leg.
            if ($null -ne $recorded -and @('Completed', 'Skipped') -contains [string] $recorded.status) {
                $where = 'an earlier leg'
                if ($null -ne $recorded.leg) {
                    $where = 'leg {0}' -f $recorded.leg
                }

                $reason = "step {0} '{1}' was already {2} on {3}" -f $index, $stepName, ([string] $recorded.status).ToLowerInvariant(), $where

                Write-HDTLog -Context $log -Event 'step.skip' -Message $reason `
                    -Data ([ordered] @{ index = $index; name = $stepName; type = $stepTypeName; reason = $reason })

                [void] $outcome.Add([pscustomobject] ([ordered] @{
                            Index        = $index
                            Name         = $stepName
                            Type         = $stepTypeName
                            Status       = 'Skipped'
                            ExitCode     = 0
                            Message      = $reason
                            Attempt      = [int] $recorded.attempt
                            DurationMs   = [long] 0
                            TimedOut     = $false
                            FailureClass = $null
                            Reason       = $reason
                        }))

                continue
            }

            # 2. Interrupted on a previous leg.
            if ($null -ne $recorded -and [string] $recorded.status -eq 'Running') {
                if ([bool] $step.Resumable) {
                    Write-HDTLog -Context $log -Severity Warning `
                        -Message ("step {0} '{1}' was interrupted on an earlier leg and declares resumable: true, so it is being run again" -f $index, $stepName) `
                        -Data ([ordered] @{ index = $index; name = $stepName; resumable = $true })
                } else {
                    $reason = "step {0} '{1}' was interrupted and does not declare resumable: true, so HDT will not run it again. Half-applied work is not silently repeated." -f $index, $stepName

                    Update-HDTRunStateStep -State $state -Index $index -Status Failed -Message $reason -Leg ([int] $state.leg) | Out-Null
                    & $saveState

                    Write-HDTLog -Context $log -Severity Error -Event 'step.fail' -Message $reason `
                        -Data ([ordered] @{ index = $index; name = $stepName; resumable = $false })

                    [void] $outcome.Add([pscustomobject] ([ordered] @{
                                Index        = $index
                                Name         = $stepName
                                Type         = $stepTypeName
                                Status       = 'Failed'
                                ExitCode     = 0
                                Message      = $reason
                                Attempt      = [int] $recorded.attempt
                                DurationMs   = [long] 0
                                TimedOut     = $false
                                FailureClass = 'Configuration'
                                Reason       = $reason
                            }))

                    $failedStep = $step
                    $runStatus = 'Failed'
                    break
                }
            }

            # 2a. SWITCHED OFF BY THE ADMINISTRATOR, which outranks every reason
            #     below it. A disabled step is not evaluated for phase or
            #     condition at all: those answer "would this apply here", and
            #     somebody has already said it should not run anywhere. Reporting
            #     a phase mismatch for a step that is switched off would send a
            #     technician looking for the wrong thing.
            if ([bool] $step.Disabled) {
                & $skipStep $index $step ("step {0} '{1}' is disabled" -f $index, $stepName)

                continue
            }

            # 3. The phase filter.
            if (-not (Test-HDTStepRunInPhase -RunIn ([string] $step.RunIn) -Phase ([string] $Context.Phase))) {
                & $skipStep $index $step ("step {0} '{1}' declares runIn {2} and this leg is running in the {3} phase" -f
                    $index, $stepName, $step.RunIn, $Context.Phase)

                continue
            }

            # 4. The group conditions, outermost first. The reason names the
            #    GROUP, so a technician reading six skip records knows they are
            #    one decision rather than six.
            $skippedByGroup = $false
            foreach ($ancestor in @($step.GroupCondition)) {
                $unresolved = New-Object -TypeName System.Collections.ArrayList

                $met = Test-HDTStepCondition -Condition ([string] $ancestor.Condition) `
                    -Variable $Context.Variable -Unresolved $unresolved

                & $reportUnresolved $unresolved ("the condition of the group '{0}'" -f $ancestor.Group)

                if (-not $met) {
                    & $skipStep $index $step ("the group '{0}' is skipped: its condition {1} is false" -f
                        $ancestor.Group, $ancestor.Condition)

                    $skippedByGroup = $true
                    break
                }
            }
            if ($skippedByGroup) {
                continue
            }

            # 5. The step's own condition.
            $unresolved = New-Object -TypeName System.Collections.ArrayList

            $met = Test-HDTStepCondition -Condition ([string] $step.Condition) `
                -Variable $Context.Variable -Unresolved $unresolved

            & $reportUnresolved $unresolved ("the condition of step {0} '{1}'" -f $index, $stepName)

            if (-not $met) {
                & $skipStep $index $step ("step {0} '{1}' is skipped: its condition {2} is false" -f
                    $index, $stepName, $step.Condition)

                continue
            }

            # 6. Applicability.
            if (-not (Test-HDTStepApplicable -Step $step -Context $Context -StepType $registry)) {
                & $skipStep $index $step ("step {0} '{1}' is skipped: the {2} step type reported that it does not apply to this machine" -f
                    $index, $stepName, $stepTypeName)

                continue
            }

            # 7. Run it. The Running checkpoint is what makes case 2 detectable.
            Update-HDTRunStateStep -State $state -Index $index -Status Running -Attempt 1 `
                -Leg ([int] $state.leg) -StartedUtc ($clock.GetUtcNow()) | Out-Null
            & $saveState

            # AND THE HEARTBEAT, HERE, WHERE THE STEP CHANGES. It used to be
            # written at the start of the run, at a reboot and at the end - so a
            # console tailing the share showed step 1 for the whole deployment
            # and then a verdict. "Step 7 of 12" is the one thing that view is
            # for, and it needs a write per step to say it.
            #
            # $log ALREADY CARRIES THE STEP: the context was told about it above,
            # which is what Write-HDTStatus reads. This adds no new fact, only
            # the moment at which it is published.
            Write-HDTStatus -Context $log -Path $statusPathValue -Status 'Running' `
                -ActivePath $activeStatusPath

            $attempt = Invoke-HDTStepAttempt -Step $step -Context $Context -StepType $registry

            # A REBOOT NOBODY CAN COME BACK FROM IS A FAILED STEP, AND IT IS
            # DECIDED HERE - before the step is recorded, so it travels through
            # the same recording, the same log line and the same Failed branch
            # as any other failure rather than needing a path of its own.
            #
            # ONE PASSWORD, AND THE ADMINISTRATOR SET IT (DESIGN 4.5.2: "The
            # administrator sets the password; HDT does not invent one"). The
            # unattend arms the FIRST logon with %HDTAdminPassword%, so that is
            # what the deployed machine's Administrator account carries; arming a
            # later leg with anything else means Winlogon trying a password the
            # account does not have, and the resume stops at a logon screen with
            # nothing to explain it.
            #
            # An earlier draft minted a random secret per deployment and kept it
            # in the state document. It was abandoned for the reason the design
            # gives: a deployment that fails halfway leaves a machine nobody can
            # log into, at exactly the moment somebody needs to get into it.
            # AND ONLY WHEN SOMETHING AFTER THE RESTART ACTUALLY LOGS ON.
            #
            # An autologon exists to get a FULL-OS leg running again. A leg that
            # resumes in WinPE is started by the boot media and needs nothing
            # armed - so demanding a password for it refuses a restart that would
            # have worked perfectly.
            #
            # THAT IS NOT HYPOTHETICAL: it is the reference build. DESIGN 9.3's
            # sequence syspreps the machine, restarts into the boot media and
            # captures it, and Invoke-HDTSysprepStep CLEARS THE AUTOLOGON one
            # step before this - correctly, because an image that kept it would
            # log itself in and re-enter a finished deployment on every machine
            # built from it. The restart then asked for the secret sysprep had
            # just removed and took the run down at step 11 of 12, on a machine
            # that had already been generalized and so could not be picked up
            # where it left off. Watched end to end on 2026-08-31.
            $needsAutoLogon = Test-HDTAutoLogonNeeded -Step $stepList -AfterIndex $index
            if ([string] $attempt.Status -eq 'RebootRequested' -and $needsAutoLogon -and
                [string]::IsNullOrWhiteSpace([string] $(
                    if ($Context.Variable.Contains('HDTAdminPassword')) { $Context.Variable['HDTAdminPassword'] } else { '' }))) {

                # MUTATED, NOT REPLACED. Invoke-HDTStepAttempt adds Attempt and
                # DurationMs to what New-HDTStepResult returned, and the recorder
                # below reads both - a fresh result object carries neither and
                # takes the whole run down through the engine's own catch.
                $attempt.Status = 'Failed'
                $attempt.Message = "this step asks for a restart, but nothing supplies HDTAdminPassword - so autologon cannot be armed and the sequence would not come back. Set it in the fallback rule of rules.yaml (MDT's [Default] section), in Control\machines\<UUID>.yaml for this machine, or on the wizard's administrator password page."
                $attempt.Data = [ordered] @{ errorId = 'HDTConfigurationError' }
            }

            $recordedStatus = 'Failed'
            if (@('Completed', 'RebootRequested') -contains [string] $attempt.Status) {
                $recordedStatus = 'Completed'
            }

            # A STEP THAT OWNS A LIST ASKS TO BE COME BACK TO. Recording a
            # RebootRequested step Completed advances stepIndex past it, which is
            # right for a Restart step and wrong for an InstallApplications step
            # that got a 3010 halfway down its list - the applications after it
            # would be silently skipped and the run would report success having
            # installed half the software. Pending leaves stepIndex where it is,
            # so the next leg runs the step again and it picks up from the
            # progress it checkpointed into a variable.
            if ([string] $attempt.Status -eq 'RebootRequested' -and [bool] $attempt.Reenter) {
                $recordedStatus = 'Pending'
            }

            Update-HDTRunStateStep -State $state -Index $index -Status $recordedStatus `
                -Attempt ([int] $attempt.Attempt) -Leg ([int] $state.leg) `
                -ExitCode ([int] $attempt.ExitCode) -Message ([string] $attempt.Message) `
                -EndedUtc ($clock.GetUtcNow()) -DurationMs ([long] $attempt.DurationMs) | Out-Null
            & $saveState

            [void] $outcome.Add([pscustomobject] ([ordered] @{
                        Index        = $index
                        Name         = $stepName
                        Type         = $stepTypeName
                        Status       = [string] $attempt.Status
                        ExitCode     = [int] $attempt.ExitCode
                        Message      = [string] $attempt.Message
                        Attempt      = [int] $attempt.Attempt
                        DurationMs   = [long] $attempt.DurationMs
                        TimedOut     = [bool] $attempt.TimedOut
                        FailureClass = $attempt.FailureClass
                        Reason       = $null
                    }))

            # ON $recordedStatus, NOT ON THE ATTEMPT'S OWN STATUS, so the log
            # says what the checkpoint says. A Restart step returns
            # RebootRequested and is recorded Completed - correctly, because
            # stepIndex has to advance past it - and this used to emit nothing
            # for it at all. Get-HDTDeploymentProgress counts step.complete and
            # step.skip by index, so the one step every rebooting deployment
            # has was never counted: on LT-7FJ45S2, run-20260829-190105 - eleven
            # steps, nine Completed and two Skipped in state.json, ended
            # Succeeded - the progress screen finished reading "10 of 11, 90%".
            #
            # A REENTERING STEP IS RECORDED Pending AND STILL SAYS NOTHING, which
            # is the point of that branch: it has not finished, the next leg runs
            # it again, and a completion record for it would be a lie the bar
            # could not take back.
            if ($recordedStatus -eq 'Completed') {
                Write-HDTLog -Context $log -Event 'step.complete' `
                    -Message ("step {0} '{1}' completed" -f $index, $stepName) `
                    -DurationMs ([long] $attempt.DurationMs) `
                    -Data ([ordered] @{ index = $index; attempt = [int] $attempt.Attempt; exitCode = [int] $attempt.ExitCode })
            }

            # THE RELOCATION KEEPS THE TRIGGER IT HAD - a step whose own attempt
            # reported Completed. A step that asked for a reboot is about to have
            # the log carried forward by the reboot path instead, and moving it
            # here would move the log out from under the arming that follows.
            if ([string] $attempt.Status -eq 'Completed') {

                # DESIGN 4.4.1's RELOCATION, and DESIGN 4.3's state mirror, at
                # the one point that sees every step finish. It runs AFTER the
                # step's own completion record, so the RAM-disk copy carries a
                # whole account of the step that caused the move.
                #
                # A DEPLOYMENT THAT DIES IN WinPE LOSES ITS LOG AT THE REBOOT,
                # and dying in WinPE is exactly when the log is wanted: X: is a
                # RAM disk. The moment a step formats a volume and publishes
                # HDTOSVolume there is somewhere for the log to live that
                # survives the power going off, so it goes there.
                #
                # THE STEP DOES NOT DO THIS ITSELF. A step does not own the log
                # context, and one that reached into it would be the wrong shape.
                #
                # Four conditions, and this is all of them: the WinPE phase, a
                # non-empty HDTOSVolume, a log still on the RAM disk, and a step
                # that reported Completed - which is the branch this is in.
                if ([string] $Context.Phase -eq 'WinPE' -and
                    ([string] $log.LogPath) -eq (Get-HDTLogPath -Phase WinPE) -and
                    $Context.Variable.Contains('HDTOSVolume') -and
                    -not [string]::IsNullOrWhiteSpace([string] $Context.Variable['HDTOSVolume'])) {

                    # Set-HDTLogPath never throws: a target volume that cannot be
                    # written leaves the context on X: and returns the old path,
                    # and then nothing below fires either.
                    $relocated = Set-HDTLogPath -Context $log `
                        -TargetVolume ([string] $Context.Variable['HDTOSVolume']) `
                        -Variable $Context.Variable

                    if ($relocated -ne (Get-HDTLogPath -Phase WinPE)) {
                        # THE STATE MIRROR RIDES ALONG, because it is the same
                        # trigger and the same information. DESIGN 4.3 says the
                        # state document is mirrored to the target disk's \HDT\
                        # as soon as a formatted volume exists - and
                        # -MirrorStatePath was until now a literal path the
                        # caller had to know in advance, which a boot-time
                        # payload cannot, for exactly the reason it cannot know a
                        # drive letter (SPIKES S9.1). A caller who DID name one
                        # is not overruled.
                        #
                        # Built from the path actually reached, so the mirror and
                        # the log agree about the volume without normalising a
                        # letter twice.
                        $volumeRoot = [System.IO.Path]::GetPathRoot($relocated)

                        if (-not $mirrorStateWasGiven) {
                            $saveArgument['MirrorPath'] = [System.IO.Path]::Combine($volumeRoot, 'HDT\state.json')
                        }

                        # DESIGN 4.4.6's heartbeat lives IN the log directory,
                        # and the copy-back ships that directory. One left behind
                        # on the RAM disk would put a stale 'Running' in the copy
                        # a technician reads, while the live one died with the
                        # reboot.
                        if (-not $statusPathWasGiven) {
                            $statusPathValue = '{0}\status.json' -f $relocated.TrimEnd('\', '/')
                        }

                        # AND SO DOES THE STATE DOCUMENT, FOR THE SAME REASON -
                        # which is not obvious, and cost a full lab run to find.
                        #
                        # By default the state document lives IN the log
                        # directory. Set-HDTLogPath mirrors the whole tree, so a
                        # copy of state.json arrives on the target volume; if the
                        # writes keep going to the RAM disk that copy is FROZEN at
                        # the moment of the move, and Copy-HDTLog then ships the
                        # frozen one to the share. The first real -Task e2e run
                        # after 05-03 read it back reporting three steps Pending
                        # on a deployment that had succeeded, booted, and come up
                        # with the right computer name.
                        #
                        # A STALE STATE DOCUMENT IS WORSE THAN AN ABSENT ONE,
                        # because it is believed. Nothing on the RAM disk survives
                        # the reboot, so leaving the live copy there buys nothing:
                        # the abandoned file stays where it is, exactly as the
                        # abandoned log does, and every write from here lands
                        # beside the log it belongs to.
                        #
                        # A CALLER WHO PUT IT SOMEWHERE ELSE IS NOT OVERRULED, and
                        # nor is one who put it outside the log directory: only a
                        # path that was under the OLD log root is rebased onto the
                        # new one.
                        $oldRoot = $logRoot.TrimEnd('\', '/')

                        if ($statePathValue.StartsWith(($oldRoot + [System.IO.Path]::DirectorySeparatorChar),
                                [System.StringComparison]::OrdinalIgnoreCase)) {

                            $statePathValue = '{0}{1}' -f $relocated.TrimEnd('\', '/'),
                            $statePathValue.Substring($oldRoot.Length)

                            $saveArgument['Path'] = $statePathValue
                        }
                    }
                }

                continue
            }

            if ([string] $attempt.Status -eq 'RebootRequested') {
                # The ceremony. Its order is argued in the description, and it is
                # asserted from the cross-service journal rather than assumed.
                $delaySecond = 0
                if ($null -ne $attempt.Data) {
                    if ($attempt.Data -is [System.Collections.IDictionary]) {
                        if ($attempt.Data.Contains('DelaySecond')) {
                            $delaySecond = [int] $attempt.Data['DelaySecond']
                        }
                    } elseif ($null -ne $attempt.Data.PSObject.Properties['DelaySecond']) {
                        $delaySecond = [int] $attempt.Data.DelaySecond
                    }
                }

                # THE ENGINE GOES ONTO THE DISK BEFORE THE LOGON IS ARMED.
                #
                # DESIGN 4.5.1 launches the resume from <os volume>\HDT\, and for
                # five milestones nothing put it there: the payload and the
                # module were staged into the BOOT IMAGE at X:\HDT\, and X: is a
                # RAM disk that does not survive this restart. The machine
                # rebooted, autologged on and ran nothing, silently skipping
                # every step in a FullOS group while the run reported success.
                #
                # ONLY FROM WinPE, AND ONLY ONCE A VOLUME EXISTS. A full-OS leg
                # is already running from the staged copy, and a sequence that
                # restarts before it has partitioned anything has nowhere to put
                # one - inventing a drive letter is what SPIKES S9.1 forbids.
                #
                # A BOOT IMAGE THAT CANNOT SUPPLY ONE DOES NOT FAIL THE
                # DEPLOYMENT. Windows is already on the disk; refusing here would
                # destroy a machine over a stale image. It warns, reboots, and
                # stops after this leg - which is what it did before this existed,
                # except that now the log says why.
                if ([string] $Context.Phase -eq 'WinPE' -and
                    $Context.Variable.Contains('HDTOSVolume') -and
                    -not [string]::IsNullOrWhiteSpace([string] $Context.Variable['HDTOSVolume'])) {

                    try {
                        # THE SHARE THIS RUN ACTUALLY REACHED, CARRIED ACROSS THE
                        # REBOOT. bootstrap.json is baked into the boot image, so
                        # it names whatever deploy root was true when the image
                        # was built. A technician who corrects the share at the
                        # Welcome screen - because the address moved - fixed the
                        # WinPE leg and nothing else: the full-OS leg asked for
                        # the dead address again, mapped no drive, and every step
                        # needing content failed. Watched end to end on
                        # 2026-08-21.
                        #
                        # A UNC ONLY, AND THAT IS THE WHOLE CARE HERE. A share is
                        # the same string from both legs. A local root is not -
                        # media that is D: in WinPE is commonly another letter
                        # once Windows has assigned its own, so writing the
                        # resolved path would hand the resume a letter that has
                        # moved. Those keep the image's own value and resolve it
                        # again, which is what Resolve-HDTDeployRoot is for.
                        $carried = ''
                        if ($Context.Variable.Contains('_HDTDeployRoot')) {
                            $resolvedRoot = [string] $Context.Variable['_HDTDeployRoot']

                            if ($resolvedRoot.StartsWith('\\')) { $carried = $resolvedRoot }
                        }

                        $agent = Copy-HDTResumeAgent -TargetVolume ([string] $Context.Variable['HDTOSVolume']) `
                            -DeployRoot $carried `
                            -FileSystem ($Context.Service.GetRequired('FileSystem', 'Restart')) -Confirm:$false

                        Write-HDTLog -Context $log -Component 'Restart' `
                            -Message ("the resume agent was staged to '{0}' ({1} file(s))" -f
                                $agent.Path, $agent.FileCount) `
                            -Data ([ordered] @{ path = [string] $agent.Path; fileCount = [int] $agent.FileCount })
                    } catch {
                        Write-HDTLog -Context $log -Severity Warning -Component 'Restart' `
                            -Message ("the resume agent could not be staged, so this deployment will stop after the restart and any step in a full-OS group will not run: {0}" -f
                                $_.Exception.Message)
                    }
                }

                # -- and the logon, ONLY IF ANYTHING AFTER THIS RESTART LOGS ON --
                #
                # THE SAME QUESTION THE GUARD ABOVE ASKED, asked again at the
                # moment of arming and answered by the same function, so the two
                # cannot disagree: a refusal that fired while the arming went
                # ahead - or the reverse - would be a machine armed for a logon
                # nothing needs, or refused for one nothing wanted.
                #
                # WHAT IT BUYS IS THE REFERENCE BUILD'S LAST RESTART. The capture
                # leg resumes in WinPE off the boot media, so there is nothing to
                # arm and nothing to arm it with: sysprep cleared the LSA secret
                # one step earlier, on purpose, so the image would not carry it.
                if ($needsAutoLogon) {

                # THE PASSWORD IS THE ADMINISTRATOR'S, AND IT WAS CHECKED BEFORE
                # THIS STEP WAS EVER RECORDED - see the guard beside
                # Invoke-HDTStepAttempt above. By here it is known to be set.
                $password = [string] $Context.Variable['HDTAdminPassword']

                # UNLESS THIS LEG READ IT OUT OF state.json, WHERE IT IS NOT
                # WRITTEN DOWN ANY MORE.
                #
                # Save-HDTRunState redacts a secret's value on the way to disk,
                # because that file is copied to the deployment share and moved
                # to C:\Windows\Logs\HDT on the deployed machine. A leg that
                # resumed after a reboot rehydrates its variable bag from that
                # file, so it holds the redaction rather than the password - and
                # arming Winlogon with the literal "(set, not shown)" would leave
                # the machine sitting at a logon screen with nothing in any log
                # to explain it. That is a worse failure than the leak was.
                #
                # SO IT COMES BACK FROM THE PLACE THAT LEGITIMATELY HOLDS IT.
                # The autologon LSA secret is admin-only, it is how this leg
                # logged itself on at all, and it is the same value by
                # construction: the unattend set the account's password from
                # %HDTAdminPassword% and armed the first logon with it (DESIGN
                # 4.5.2). Reading it here is a recovery, not a second store.
                $restartLsa = $Context.Service.GetRequired('Lsa', 'Restart')

                # The redaction's wording from the one place that defines it,
                # rather than a second copy of the literal here.
                $redaction = [string] (Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'a set value')

                if ($password -eq $redaction) {
                    $recovered = [string] $restartLsa.GetSecret('DefaultPassword')

                    if ([string]::IsNullOrEmpty($recovered)) {
                        throw (New-HDTErrorRecord -ErrorId 'HDTConfigurationError' `
                                -Message ("step '{0}' asks for a restart on a resumed leg, but the administrator password is not recoverable: state.json carries the redaction rather than the value and the autologon LSA secret is empty. Nothing can arm the next logon, so the sequence would not come back." -f $step.Name))
                    }

                    $password = $recovered
                }

                $remainingLeg = 1
                for ($ahead = $index + 1; $ahead -le $stepList.Count; $ahead++) {
                    if ([string] $stepList[$ahead - 1].Type -eq 'Restart') {
                        $remainingLeg++
                    }
                }

                $armArgument = @{
                    Registry     = $Context.Service.GetRequired('Registry', 'Restart')
                    Lsa          = $restartLsa
                    UserName     = $AutoLogonUserName
                    Password     = $password
                    RemainingLeg = $remainingLeg
                    DomainName   = $AutoLogonDomainName
                    State        = $state
                    LogContext   = $log
                }
                if ($PSBoundParameters.ContainsKey('ResumeCommand')) {
                    $armArgument['ResumeCommand'] = $ResumeCommand
                }

                Set-HDTAutoLogon @armArgument

                } else {
                    Write-HDTLog -Context $log -Component 'Restart' `
                        -Message ("no autologon was armed: every step after '{0}' runs in WinPE, so the boot media starts the next leg and nothing has to log on." -f $step.Name) `
                        -Data ([ordered] @{ autoLogonArmed = $false })
                }

                # The second save: autoLogon.armed has to be durable too.
                & $saveState

                Write-HDTStatus -Context $log -Path $statusPathValue -Status 'RebootPending' -ActivePath $activeStatusPath

                # -- the log goes onto the disk before the machine goes ---------
                #
                # MDT'S MININT, AND FOR MDT'S REASON. LiteTouch keeps its logs in
                # MININT\SMSOSD\OSDLOGS and moves that folder onto the target
                # volume before the WinPE leg restarts. The log then survives the
                # reboot on the disk the machine is about to boot from, and
                # LTICleanup collects it at the end from there.
                #
                # HDT HAD NO SUCH COPY, AND LOST EVERY WinPE LOG THAT REBOOTED.
                # The WinPE log lives on X: - the RAM disk - and reached the share
                # only from the tail of Start-HDTDeployment.ps1, after the
                # sequence returns. A Restart step restarts from INSIDE the
                # sequence, so that tail is not reached: X: evaporates and the
                # share gets nothing. Observed on a real machine, whose whole
                # WinPE leg had to be recovered from the VHDX afterwards - and
                # the share copy could not have saved it either, because the
                # share was what it could not reach.
                #
                # THE SAME VOLUME THE RESUME AGENT WENT TO, and the same folder
                # the full-OS leg logs into, so the two legs of one deployment
                # end up in one place. That is what reading a deployment end to
                # end requires, and it is the only copy that needs no network.
                #
                # IT NEVER STOPS THE RESTART. A machine that cannot be given its
                # log is still a machine that must reboot to carry on; the
                # failure is worth a line, not a stalled deployment.
                if ([string] $Context.Phase -eq 'WinPE' -and
                    $Context.Variable.Contains('HDTOSVolume') -and
                    -not [string]::IsNullOrWhiteSpace([string] $Context.Variable['HDTOSVolume'])) {

                    # 'W', 'W:' AND 'W:\' ARE ONE VOLUME, AND THE STEP PUBLISHES
                    # THE FIRST OF THEM. Invoke-HDTDiskPartitionStep sets
                    # HDTOSVolume to the bare letter, and a bare letter composed
                    # straight into a path gives 'W\HDT\Logs' - which is
                    # RELATIVE. It resolves against the current directory, on the
                    # RAM disk, so the copy meant to outlive the restart died
                    # with it. Seen on a real machine, whose log line read
                    #   the log was copied to 'W\HDT\Logs\MININT-EF6QJGH-...'
                    # Set-HDTLogPath and Copy-HDTResumeAgent normalise for this
                    # reason; this was the one place that did not.
                    $volume = ([string] $Context.Variable['HDTOSVolume']).Trim().TrimEnd('\', '/')
                    if ($volume -notmatch ':$') {
                        $volume = '{0}:' -f $volume.TrimEnd(':')
                    }

                    # Get-HDTLogPath owns where logs live on a volume, and this
                    # branch runs in WinPE only.
                    $volumeLogRoot = Get-HDTLogPath -Phase WinPE -TargetVolume $volume

                    # NAMED FOR THE MACHINE BEING DEPLOYED. Copy-HDTLog defaults
                    # to this process's own name, which in WinPE is MININT-xxxxxxx,
                    # so the disk's copy and the share's copy - which is named
                    # from %HDTComputerName% - carried two different names for
                    # one deployment.
                    $copyArgument = @{ Context = $log; Destination = $volumeLogRoot }
                    if ($Context.Variable.Contains('HDTComputerName') -and
                        -not [string]::IsNullOrWhiteSpace([string] $Context.Variable['HDTComputerName'])) {

                        $copyArgument['ComputerName'] = [string] $Context.Variable['HDTComputerName']
                    }

                    try {
                        $onDisk = Copy-HDTLog @copyArgument

                        if ($onDisk.Succeeded) {
                            Write-HDTLog -Context $log -Component 'Restart' `
                                -Message ("the log was copied to '{0}', which survives the restart" -f $onDisk.Path) `
                                -Data ([ordered] @{ path = [string] $onDisk.Path })
                        } else {
                            Write-HDTLog -Context $log -Severity Warning -Component 'Restart' `
                                -Message ("the log could not be copied to '{0}', so this leg's log lives only on the RAM disk and will not survive the restart: {1}" -f
                                    $volumeLogRoot, $onDisk.Message)
                        }
                    } catch {
                        Write-HDTLog -Context $log -Severity Warning -Component 'Restart' `
                            -Message ("the log could not be copied to '{0}', so this leg's log lives only on the RAM disk and will not survive the restart: {1}" -f
                                $volumeLogRoot, $_.Exception.Message)
                    }
                }

                # -- THE LAST DURABLE THING THIS LEG DOES ----------------------
                #
                # THE CHECKPOINT GOES AFTER THE LAST RECORD, NOT BEFORE IT. The
                # save above runs before the log is copied to the disk, and the
                # copy writes a record of its own - so state.seq was one short
                # of what this leg had actually emitted. The next leg seeds its
                # counter from that number and correctly issues seq+1, which is
                # the number that record already used.
                #
                # AND THE finally's CLOSING SAVE NEVER RUNS ON A REAL MACHINE.
                # $power.Restart returns, but Windows terminates this process
                # moments later; the finally that would have caught up is dead
                # with it. Measured on run-20260829-223623: the WinPE leg's last
                # record is seq 203, state.json says 202, the full-OS leg's
                # reboot.resume opens at 203 a second time - and there is no
                # run.end for leg 1 in that log at all. A fake power service
                # returns and lets the finally run, which is why the benchmark
                # was green for it.
                #
                # A GAP IS FINE; A COLLISION IS NOT. DESIGN 4.4.2 asks for a
                # MONOTONIC seq, so a run can be sorted into its true order when
                # WinPE's clock has skewed. Nothing reads it as a count. If this
                # leg dies between a record and this line the next one simply
                # starts higher, which loses nothing - where chasing contiguity
                # would mean the resumed leg GUESSING how many records the dead
                # leg got out, and guessing low reissues them.
                & $saveState

                $power = $Context.Service.GetRequired('Power', 'Restart')
                $power.Restart($delaySecond)

                $runStatus = 'RebootPending'
                break
            }

            # Failed.
            #
            # AND THE DIAGNOSTICS TRAVEL WITH IT. Invoke-HDTStepAttempt keeps the
            # ErrorRecord's full detail on the outcome - every exception layer,
            # the file, the line, the stack - because it is the last place the
            # ErrorRecord still exists. This is the record an administrator opens,
            # so this is where that detail has to surface. A step that FAILED
            # rather than THREW carries no Diagnostic, and the record simply has
            # the fields below.
            $failData = [ordered] @{
                index        = $index
                attempt      = [int] $attempt.Attempt
                exitCode     = [int] $attempt.ExitCode
                failureClass = $attempt.FailureClass
                timedOut     = [bool] $attempt.TimedOut
            }

            # READ DEFENSIVELY: a third-party step type dot-sourced from Modules\
            # may return an outcome this engine did not build.
            if ($null -ne $attempt.PSObject.Properties['Diagnostic'] -and $null -ne $attempt.Diagnostic) {
                foreach ($field in @($attempt.Diagnostic.Keys)) {
                    $failData[$field] = $attempt.Diagnostic[$field]
                }
            }

            Write-HDTLog -Context $log -Severity Error -Event 'step.fail' `
                -Message ("step {0} '{1}' failed: {2}" -f $index, $stepName, $attempt.Message) `
                -DurationMs ([long] $attempt.DurationMs) `
                -Data $failData

            if ([bool] $step.ContinueOnError) {
                Write-HDTLog -Context $log -Severity Warning `
                    -Message ("step {0} '{1}' failed and declares continueOnError: true, so the run continues" -f $index, $stepName) `
                    -Data ([ordered] @{ index = $index; name = $stepName; exitCode = [int] $attempt.ExitCode })

                continue
            }

            $failedStep = $step
            $runStatus = 'Failed'

            if ([bool] $state.pauseOnError) {
                # DESIGN 4.3's LTISuspend, minus the prompt. See the description.
                Write-HDTLog -Context $log -Severity Error `
                    -Message ("The run is paused at step {0} '{1}' because pauseOnError is set. The state is loaded and saved at '{2}'; the caller decides whether to open a prompt." -f
                        $index, $stepName, $statePathValue) `
                    -Data ([ordered] @{ index = $index; name = $stepName; statePath = $statePathValue })

                Write-HDTStatus -Context $log -Path $statusPathValue -Status 'Failed' -ActivePath $activeStatusPath
            }

            break
        }
    } catch {
        # Anything the loop itself could not handle. A step's own exception was
        # already turned into a Failed result by Invoke-HDTStepAttempt, so
        # reaching here means the engine failed rather than the deployment.
        $runStatus = 'Failed'

        # -- THE RECORD THAT HAD TO EXPLAIN A DEPLOYMENT AND COULD NOT --------
        #
        # This line used to be $_.Exception.Message and nothing else. On
        # run-20260830-204613 that produced, as the ENTIRE record for a fatal
        # failure: 'The task sequence stopped: Exception calling "SetValue" with
        # "4" argument(s): "The running command stopped because the preference
        # variable "ErrorActionPreference" or common parameter is set to Stop:
        # Cannot delete a subkey tree because the subkey does not exist."'
        #
        # Three quoted layers deep, naming a SET while the failure was a DELETE,
        # with no type, no file, no line and no stack - and the outermost layer,
        # which is PowerShell describing its own method-call plumbing, is the one
        # that won. Nobody can act on that at 2am on a machine they cannot touch.
        #
        # SO THE SENTENCE NAMES THE CAUSE AND THE DIAGNOSTICS GO IN data, where
        # JSONL can carry them and the CMTrace twin stays one scannable line per
        # record. Get-HDTErrorDetail has the reasoning and the full field list.
        $fatal = Get-HDTErrorDetail -ErrorRecord $_
        $fatal['sequenceId'] = [string] $Sequence.Id

        Write-HDTLog -Context $log -Severity Error -Event 'step.fail' `
            -Message (Get-HDTErrorSummary -ErrorRecord $_) -Data $fatal
    } finally {
        $log.ClearStep()

        $state.status = 'Running'
        if (@('Succeeded', 'Failed') -contains $runStatus) {
            $state.status = $runStatus
        }

        # The checkpoint may fail - a share that went away, a disk that filled -
        # and the teardown below must not be what pays for it.
        try {
            & $saveState
        } catch {
            Write-HDTLog -Context $log -Severity Error `
                -Message ("The run state could not be checkpointed at '{0}': {1}. Autologon teardown continues regardless." -f
                    $statePathValue, $_.Exception.Message)
        }

        # DESIGN 4.5.2: teardown is a failsafe, not a step. The one outcome that
        # keeps the machine armed is a pending reboot - it has to come back.
        #
        # It runs BEFORE run.end and before copy-back so the log that reaches the
        # share carries the teardown record, and so run.end is genuinely the last
        # line of the run.
        if ($runStatus -ne 'RebootPending') {

            # -- THE HEARTBEAT IS NOT SWEPT HERE, AND THE SWEEP THAT USED TO BE
            #    HERE NEVER RAN TO ANY EFFECT -------------------------------
            #
            # This block deleted <share>\Logs\_active\<RunId>.json, and then the
            # verdict heartbeat at the end of this same finally WROTE IT
            # STRAIGHT BACK - with the run's final status, which is the whole
            # point of that write. So the delete was undone microseconds later
            # on every run that reached it, and the comment that stood here
            # claimed a behaviour the code did not have. Both markers on this
            # lab's share outlived it: run-20260829-223623 reading Succeeded and
            # run-20260830-204613 reading Failed.
            #
            # AND LEAVING THE MARKER IS THE BEHAVIOUR THE PRODUCT WANTS. It is
            # the one artifact that survives a pruned log tree - twice here it
            # was all that was left of a deployment - so a run that FAILED has to
            # be able to say so from it. Get-HDTConsoleMonitorSummary already
            # counts finished runs in _active as a normal state rather than an
            # error, and Remove-HDTMonitorRun is the command that clears one when
            # somebody decides to.
            #
            # A run that is still coming back keeps its marker for a different
            # reason again: RebootPending never reaches this branch at all, so a
            # restarting machine never vanishes from the console.

            $registryService = $Context.Service.Registry
            $lsaService = $Context.Service.Lsa

            if ($null -eq $registryService -or $null -eq $lsaService) {
                Write-HDTLog -Context $log -Severity Warning `
                    -Message 'Autologon teardown was skipped: this run was started without a registry service or an LSA service, and the teardown checklist cannot run without both.'
            } else {
                $teardown = Clear-HDTAutoLogon -Registry $registryService -Lsa $lsaService `
                    -FileSystem $fileSystem -State $state -StatePath $statePathValue -Clock $clock -LogContext $log

                if (@($teardown.Failed).Count -gt 0) {
                    # Reported, never promoted: the run's own status is what the
                    # caller acts on, and a teardown failure must not hide it.
                    Write-HDTLog -Context $log -Severity Warning `
                        -Message ("Autologon teardown left {0} item(s) unfinished: {1}." -f
                            @($teardown.Failed).Count, (@($teardown.Failed | ForEach-Object { $_.Item }) -join ', ')) `
                        -Data ([ordered] @{ failed = [string[]] @($teardown.Failed | ForEach-Object { $_.Item }) })
                }
            }
        }

        # TALLIED FROM THE CHECKPOINT, NOT FROM THIS PROCESS'S OWN LIST.
        #
        # THE COUNTERS ARE PER-PROCESS AND A DEPLOYMENT SPANS PROCESSES;
        # state.json IS THE ONLY THING THAT SPANS THEM. $outcome holds what THIS
        # leg's loop touched, and a leg that resumes after a reboot starts at
        # state.stepIndex - so everything the earlier legs did is simply not in
        # it. Measured on LT-7FJ45S2, run-20260829-190105: state.json recorded
        # nine Completed and two Skipped, and run.end told the technician
        # "1 completed, 0 failed, 0 skipped", because the full-OS leg executed
        # exactly one step. A single-leg run tallied correctly, which is why it
        # went unnoticed for as long as it did.
        #
        # AND THE TWO LISTS DISAGREED WITHIN A SINGLE LEG TOO. $outcome carries
        # the attempt's raw status, so the step that asks for the reboot is
        # 'RebootRequested' there and Completed in the state - counted by
        # neither bucket, which cost leg one a step of its own as well.
        #
        # There is no fast path kept alongside this: two sources of the same
        # number is exactly how it drifted. $outcome remains the RETURN value,
        # which is this call's own result and correctly per-process.
        $completedCount = @(@($state.step) | Where-Object { [string] $_.status -eq 'Completed' }).Count
        $failedCount = @(@($state.step) | Where-Object { [string] $_.status -eq 'Failed' }).Count
        $skippedCount = @(@($state.step) | Where-Object { [string] $_.status -eq 'Skipped' }).Count


        # WHERE THE RUN GOT TO, SAID OUT LOUD.
        #
        # $log has had ClearStep called on it by the step that just ended, and
        # correctly so - a finished step is not the current step. But this is
        # the VERDICT, and it used to inherit that cleared context: every run
        # ended by writing stepIndex 0 with no name, so a deployment that ran
        # all twelve steps and succeeded was drawn '(no step yet)' and
        # '0 of 12', and a failed one threw away the single fact anybody opens
        # the Monitoring node to find - WHICH step it died on.
        #
        # THE FAILING STEP, NOT THE LAST ONE ATTEMPTED. A step with
        # continueOnError set lets the run carry on past a failure, so the last
        # entry is not necessarily the one that went wrong; on a failed run the
        # last FAILED entry is what somebody is looking for.
        # INDEXED ONLY AFTER COUNTING. A run can end having attempted NO step at
        # all - a checkpoint that cannot be written fails the run before the
        # first one - and @()[0] on an empty array throws under StrictMode
        # rather than yielding $null.
        $reached = $null

        if ($runStatus -eq 'Failed') {
            # NOT $failedStep - THAT NAME IS ALREADY THE RUN'S. It holds the
            # step this function RETURNS as FailedStep, and reusing it here
            # overwrote a single step with the whole list of failures, so a run
            # with a tolerated failure before a fatal one returned both.
            $failedOutcome = @($outcome | Where-Object { $_.Status -eq 'Failed' })
            if ($failedOutcome.Count -gt 0) { $reached = $failedOutcome[$failedOutcome.Count - 1] }
        }

        if ($null -eq $reached) {
            $attempted = @($outcome)
            if ($attempted.Count -gt 0) { $reached = $attempted[$attempted.Count - 1] }
        }

        $statusArgument = @{
            Context    = $log
            Path       = $statusPathValue
            Status     = $runStatus
            ActivePath = $activeStatusPath
        }

        # A RUN THAT REACHED NO STEP AT ALL says so by leaving these unset,
        # which keeps the cleared context's zero rather than inventing one.
        if ($null -ne $reached) {
            $statusArgument['StepIndex'] = [int] $reached.Index
            $statusArgument['StepName'] = [string] $reached.Name
            $statusArgument['StepType'] = [string] $reached.Type
        }

        Write-HDTStatus @statusArgument

        # -- run.end IS THE LAST LINE OF THE RUN, AND THAT IS ASSERTED --------
        #
        # It used to be written BEFORE the verdict heartbeat above, which was
        # harmless only while Write-HDTStatus logged nothing. It logs its
        # transition now - every status change is a record, and the terminal one
        # is the record that says how the deployment ended - so writing the
        # heartbeat first is what keeps run.end genuinely last.
        #
        # ANYTHING READING THIS LOG READS run.end AS THE END. The reboot teardown
        # above is ordered against it for the same reason, and
        # Invoke-HDTTaskSequence.Ordering.Tests.ps1 asserts it directly.
        Write-HDTLog -Context $log -Event 'run.end' `
            -Message ("Run {0} ended {1}: {2} completed, {3} failed, {4} skipped" -f
                $Context.RunId, $runStatus, $completedCount, $failedCount, $skippedCount) `
            -Data ([ordered] @{
                status    = $runStatus
                completed = $completedCount
                failed    = $failedCount
                skipped   = $skippedCount
                leg       = [int] $state.leg
            })

        # THE LAST THING THE SCREEN IS TOLD, and the only update that carries a
        # verdict: run.end has just been written, so this is where Running
        # becomes Succeeded or Failed on a technician's screen instead of
        # staying on whichever step was last starting.
        #
        # IN THE finally, SO IT HAPPENS ON THE FAILING RUNS TOO - which are the
        # runs somebody is standing in front of.
        Update-HDTProgressDisplay -Context $Context

        if ($PSBoundParameters.ContainsKey('LogDestination')) {
            # DESIGN 4.4.1: copy-back happens on failure too. Copy-HDTLog is
            # documented never to throw and this catches anyway - nothing in a
            # finally block may be allowed to replace the run's own outcome with
            # its own failure.
            $copyArgument = @{ Context = $log; Destination = $LogDestination }
            if ($Context.Variable.Contains('HDTComputerName') -and
                -not [string]::IsNullOrWhiteSpace([string] $Context.Variable['HDTComputerName'])) {

                $copyArgument['ComputerName'] = [string] $Context.Variable['HDTComputerName']
            }

            try {
                # AND THE ANSWER IS READ. Copy-HDTLog reports a share it could
                # not write to on its result rather than by throwing, so a
                # caller that discarded it turned a failed copy-back into
                # silence - which is the shape this whole guard exists to
                # avoid.
                $copied = Copy-HDTLog @copyArgument

                if (-not $copied.Succeeded) {
                    Write-HDTLog -Context $log -Severity Warning -Component 'Logging' `
                        -Message ("The deployment logs could not be copied to '{0}': {1}" -f $LogDestination, $copied.Message) `
                        -Data ([ordered] @{ path = [string] $copied.Path })
                }
            } catch {
                Write-HDTLog -Context $log -Severity Warning -Component 'Logging' `
                    -Message ("The deployment logs could not be copied to '{0}': {1}" -f $LogDestination, $_.Exception.Message)
            }
        }

        if ($runStatus -eq 'RebootPending') {
            # One last checkpoint, after the final log record, so the state
            # carries the seq the log stream actually reached. The next leg seeds
            # its counter from this number, and without it the first record after
            # the reboot would reuse the number run.end just consumed.
            try {
                & $saveState
            } catch {
                $null = $_
            }
        }
    }

    return [pscustomobject] ([ordered] @{
            Status     = $runStatus
            State      = $state
            Result     = [object[]] $outcome.ToArray()
            FailedStep = $failedStep
        })
}
