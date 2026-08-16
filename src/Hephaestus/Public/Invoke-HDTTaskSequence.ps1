function Invoke-HDTTaskSequence {
    <#
        .SYNOPSIS
            Runs a flattened task sequence: ordering, conditions, retry,
            reboot-and-resume, and the finally teardown that makes autologon
            safe.

        .DESCRIPTION
            DESIGN 4.3's execution loop. It takes an imported sequence and an
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

              1. mark the step Completed, advancing stepIndex past it
              2. SAVE
              3. take (or generate) the deployment password
              4. Set-HDTAutoLogon for 1 + the Restart steps still ahead
              5. SAVE again, so autoLogon.armed is durable
              6. status heartbeat
              7. IPowerService.Restart

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

            TEARDOWN RUNS FROM finally, NOT FROM A STEP. MDT's
            cleanup is a task sequence step, so a failure before it leaves
            autologon armed. Here every terminal outcome - success, failure, a
            thrown exception, even a failed checkpoint - runs the DESIGN 4.5.3
            checklist. The one outcome that does NOT tear down is RebootPending:
            the machine has to stay armed to come back.

            The finally runs: clear the step, stamp the run status, checkpoint,
            TEAR DOWN, log run.end, write the heartbeat, copy the logs back. The
            teardown comes before run.end so the copied-back log carries its
            record, and so run.end is genuinely the last line of the run.

            PAUSEONERROR DOES NOT PROMPT. DESIGN 4.3's LTISuspend equivalent is
            read from the state document; when it is set and a step fails
            terminally, the loop logs at Error that the run is paused, writes the
            heartbeat and RETURNS with the state loaded. Dropping to a live
            prompt belongs to the caller (Start-HDTDeployment, phase 05): an
            engine that blocked on input could not be unit tested and would hang
            CI.

            TIMEOUTS ARE NOT PRE-EMPTIVE. `timeoutMinutes` is passed to the step
            - only CommandLine can enforce it, through IProcessService - and
            measured by the loop afterwards. HDT does not preempt a synchronous
            step: one that hangs in-process hangs the sequence, exactly as MDT's
            does. Running steps in a child runspace is a post-v1 idea, and
            ForEach-Object -Parallel is not available to an engine that must run
            under Windows PowerShell 5.1.

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
            which is where DESIGN 4.4.2's directory listing puts it. A caller
            that follows DESIGN 4.3's X:\HDT\state.json - Start-HDTResume.ps1
            does - passes it explicitly.

        .PARAMETER MirrorStatePath
            A second location for the same document, conventionally the target
            volume once one is formatted. The mirror is what makes the WinPE to
            full-OS transition survivable.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. Without one the loop discovers
            once per run and hands the same registry to every dispatch.

        .PARAMETER StatusPath
            Where to write DESIGN 4.4.6's status.json heartbeat. Defaults to
            status.json in the log directory.

        .PARAMETER LogDestination
            The share's log root. When given, the log directory is copied back at
            the end of the run - on failure too, because a deployment that dies
            is exactly when the logs matter.

        .PARAMETER AutoLogonUserName
            The account the reboot ceremony arms autologon for. Defaults to
            Administrator, the DESIGN 4.5 model.

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
    if ($PSBoundParameters.ContainsKey('StatusPath')) {
        $statusPathValue = $StatusPath
    }

    $stepList = [object[]] @($Sequence.Step)

    if (-not $PSCmdlet.ShouldProcess([string] $Sequence.Id, ('Run {0} task sequence step(s)' -f $stepList.Count))) {
        return
    }

    $state = $State
    if ($null -eq $state) {
        $state = New-HDTRunState -SequenceId ([string] $Sequence.Id) -RunId ([string] $Context.RunId) `
            -Phase ([string] $Context.Phase) -Clock $clock -Variable $Context.Variable -Step $stepList
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

    # HOW MANY STEPS THIS RUN HAS, set once and carried by every heartbeat from
    # here on. The console tailing Logs\_active\ shows "step 7 of 12", and it
    # cannot count them itself - it is reading a share, not running a sequence.
    $log.StepCount = $stepList.Count

    Write-HDTStatus -Context $log -Path $statusPathValue -Status 'Running'

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

            $attempt = Invoke-HDTStepAttempt -Step $step -Context $Context -StepType $registry

            $recordedStatus = 'Failed'
            if (@('Completed', 'RebootRequested') -contains [string] $attempt.Status) {
                $recordedStatus = 'Completed'
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

            if ([string] $attempt.Status -eq 'Completed') {
                Write-HDTLog -Context $log -Event 'step.complete' `
                    -Message ("step {0} '{1}' completed" -f $index, $stepName) `
                    -DurationMs ([long] $attempt.DurationMs) `
                    -Data ([ordered] @{ index = $index; attempt = [int] $attempt.Attempt; exitCode = [int] $attempt.ExitCode })

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

                # One machine, one secret per run: generated on the first reboot
                # and reused on every one after it.
                $password = [string] $state.deploymentPassword
                if ([string]::IsNullOrEmpty($password)) {
                    $password = New-HDTDeploymentPassword
                    $state.deploymentPassword = $password
                }

                $remainingLeg = 1
                for ($ahead = $index + 1; $ahead -le $stepList.Count; $ahead++) {
                    if ([string] $stepList[$ahead - 1].Type -eq 'Restart') {
                        $remainingLeg++
                    }
                }

                $armArgument = @{
                    Registry     = $Context.Service.GetRequired('Registry', 'Restart')
                    Lsa          = $Context.Service.GetRequired('Lsa', 'Restart')
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

                # The second save: autoLogon.armed has to be durable too.
                & $saveState

                Write-HDTStatus -Context $log -Path $statusPathValue -Status 'RebootPending'

                $power = $Context.Service.GetRequired('Power', 'Restart')
                $power.Restart($delaySecond)

                $runStatus = 'RebootPending'
                break
            }

            # Failed.
            Write-HDTLog -Context $log -Severity Error -Event 'step.fail' `
                -Message ("step {0} '{1}' failed: {2}" -f $index, $stepName, $attempt.Message) `
                -DurationMs ([long] $attempt.DurationMs) `
                -Data ([ordered] @{
                    index        = $index
                    attempt      = [int] $attempt.Attempt
                    exitCode     = [int] $attempt.ExitCode
                    failureClass = $attempt.FailureClass
                    timedOut     = [bool] $attempt.TimedOut
                })

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

                Write-HDTStatus -Context $log -Path $statusPathValue -Status 'Failed'
            }

            break
        }
    } catch {
        # Anything the loop itself could not handle. A step's own exception was
        # already turned into a Failed result by Invoke-HDTStepAttempt, so
        # reaching here means the engine failed rather than the deployment.
        $runStatus = 'Failed'

        Write-HDTLog -Context $log -Severity Error -Event 'step.fail' `
            -Message ("The task sequence stopped: {0}" -f $_.Exception.Message) `
            -Data ([ordered] @{ sequenceId = [string] $Sequence.Id })
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

        $completedCount = @($outcome | Where-Object { $_.Status -eq 'Completed' }).Count
        $failedCount = @($outcome | Where-Object { $_.Status -eq 'Failed' }).Count
        $skippedCount = @($outcome | Where-Object { $_.Status -eq 'Skipped' }).Count

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

        Write-HDTStatus -Context $log -Path $statusPathValue -Status $runStatus

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
                Copy-HDTLog @copyArgument | Out-Null
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
