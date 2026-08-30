function Write-HDTStatus {
    <#
        .SYNOPSIS
            Writes the status.json heartbeat.

        .DESCRIPTION
            "The engine writes a small status.json heartbeat each step. The
            console tails that directory. No web service, no SQL, no monitoring
            server to stand up".

            It OVERWRITES rather than appends, which makes it the one log-adjacent
            writer that uses WriteAllText: a heartbeat is the current state of a
            run, not a history of it, and a console tailing a directory wants to
            read one small object rather than seek to the end of a growing file.

            The document:

              { "schemaVersion": 1, "runId", "phase", "status", "stepIndex",
                "stepCount", "stepName", "stepType", "updated" }

            THE TIMESTAMP IS A FORMATTED STRING. ConvertTo-Json renders a raw
            [datetime] as "\/Date(...)\/" under Windows PowerShell 5.1, which is
            the engine running in WinPE where this file is written.

        .PARAMETER Context
            A New-HDTLogContext result. Supplies the run id, the phase, the
            current step, the injected filesystem and the injected clock.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\status.json, and
            mirrored to <share>\Logs\_active\<RunId>.json for the console.

        .PARAMETER Status
            The run status. Defaults to Running.

        .PARAMETER StepIndex
            The step the run reached, for a caller writing a verdict after the
            context has been cleared. Omitted, the context's own step is written.

        .PARAMETER StepName
            The name of that step. Omitted, the context's own.

        .PARAMETER StepType
            The type of that step. Omitted, the context's own.

        .OUTPUTS
            None.

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) `
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log
            Write-HDTStatus -Context $context -Path 'X:\HDT\Logs\status.json'

            One small file saying where the run has got to, rewritten as it moves. The
            console's monitor reads it rather than parsing the whole JSONL.

        .EXAMPLE
            Write-HDTStatus -Context $context -Path 'X:\HDT\Logs\status.json' -WhatIf

            Names the file and writes nothing.

    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Status = 'Running',

        # WHERE THE CONSOLE LOOKS. <share>\Logs\_active\<RunId>.json, which
        # Get-HDTConsoleMonitor tails. Empty means write locally and nothing
        # else - a full-OS leg with no share, or a caller that has no console
        # to feed.
        [Parameter()]
        [AllowEmptyString()]
        [string] $ActivePath = '',

        # WHERE THE RUN GOT TO, WHEN THE CONTEXT NO LONGER KNOWS.
        #
        # The engine calls SetStep before a step and ClearStep after it, and the
        # VERDICT is written after the loop - so the last heartbeat of every run
        # reported stepIndex 0 and no name. A deployment that ran all twelve
        # steps and succeeded was drawn '(no step yet)' with '0 of 12', and a
        # deployment that FAILED discarded the one fact anybody opens the
        # Monitoring node to find: which step it died on.
        #
        # ClearStep is not the bug - a step that has ended is not the current
        # step, and the logger must not tag later records with it. So the caller
        # that knows the run is over says what it reached.
        #
        # UNSUPPLIED IS NOT ZERO, which is why these are tested with
        # ContainsKey rather than given sentinel defaults: a run that failed
        # before any step began really did reach step 0, and every per-step
        # heartbeat must still read the context or a live row would stop moving.
        [Parameter()]
        [int] $StepIndex,

        [Parameter()]
        [AllowEmptyString()]
        [string] $StepName,

        [Parameter()]
        [AllowEmptyString()]
        [string] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $updated = $Context.Clock.GetUtcNow().ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $stepIndexValue = $Context.StepIndex
    $stepNameValue = $Context.StepName
    $stepTypeValue = $Context.StepType

    if ($PSBoundParameters.ContainsKey('StepIndex')) { $stepIndexValue = $StepIndex }
    if ($PSBoundParameters.ContainsKey('StepName')) { $stepNameValue = $StepName }
    if ($PSBoundParameters.ContainsKey('StepType')) { $stepTypeValue = $StepType }

    $document = [ordered] @{
        schemaVersion = 1
        runId         = $Context.RunId
        phase         = $Context.Phase
        status        = $Status
        stepIndex     = $stepIndexValue

        # ALWAYS PRESENT, EVEN AS ZERO. A key that is sometimes absent is a key
        # every reader has to test for, and this one is read by a console that
        # may be looking at a share written by an older engine.
        stepCount     = $Context.StepCount
        stepName      = $stepNameValue
        stepType      = $stepTypeValue
        updated       = $updated
    }

    $json = ConvertTo-Json -InputObject $document -Depth 4

    if ($PSCmdlet.ShouldProcess($Path, 'Write run status')) {
        $Context.FileSystem.WriteAllText($Path, $json)
    }

    # -- and a copy where somebody watching can see it ------------------------
    #
    # MDT'S SLShareDynamicLogging, WHICH IS THE HALF HDT WAS MISSING. HDTSLShare
    # says where the logs go when a run ENDS; this is what puts something on the
    # share while the machine is still working, so an administrator can watch
    # rather than wait.
    #
    # THE CONSOLE WAS ALREADY BUILT FOR IT. Get-HDTConsoleMonitor tails
    # <share>\Logs\_active\ and rebuilds that branch every fifteen seconds, and
    # the help above this function has always said the status was mirrored
    # there. Nothing wrote it: the Monitoring branch could not show a live
    # deployment, and on the first one anybody watched it stayed empty from
    # start to finish.
    #
    # ONE DOCUMENT, TWO PATHS. Not a second shape for a second reader - the
    # console parses exactly what the machine wrote locally.
    #
    # AND THE SHARE IS NEVER ALLOWED TO END A DEPLOYMENT. The local write is the
    # one that matters; this is a courtesy to somebody watching, and a machine
    # that stopped deploying because nobody was would be absurd. A share that
    # has gone is also the case this is most useful in.
    $mirrored = $false
    $mirrorError = ''

    if (-not [string]::IsNullOrWhiteSpace($ActivePath)) {
        try {
            if ($PSCmdlet.ShouldProcess($ActivePath, 'Mirror run status for the console')) {
                $Context.FileSystem.WriteAllText($ActivePath, $json)
                $mirrored = $true
            }
        } catch {
            # -- A MIRROR THAT FAILED USED TO SAY SO TO NOBODY -----------------
            #
            # This was Write-Verbose, which in a deployment goes nowhere at all.
            # <share>\Logs\_active\<RunId>.json is the ONE artifact that survives
            # a pruned log tree, so a machine whose mirror quietly stopped
            # updating leaves a marker frozen at whatever step it last managed to
            # write - and a run that FAILED then reads, to anyone looking, as one
            # still going. Twice here the marker was all that was left.
            #
            # STILL NOT ALLOWED TO END THE DEPLOYMENT. The local status.json is
            # the one that matters and it is already written; this is a courtesy
            # to somebody watching, and a machine that stopped deploying because
            # nobody was would be absurd. A share that has gone is exactly when
            # this line is worth having.
            $mirrorError = [string] $_.Exception.Message

            Write-HDTLog -Context $Context -Severity Warning -Component 'Status' `
                -Message ("the run status could not be mirrored to '{0}', so a console watching this share will keep showing whatever was written there last: {1}" -f
                    $ActivePath, $mirrorError) `
                -Data ([ordered] @{
                        activePath = $ActivePath
                        status     = $Status
                        stepIndex  = $stepIndexValue
                        error      = $mirrorError
                    })
        }
    }

    # -- EVERY TRANSITION, SAID OUT LOUD --------------------------------------
    #
    # Running is the per-step heartbeat and there is one per step, so it goes at
    # Debug where it adds volume without drowning the file. EVERYTHING ELSE IS A
    # TRANSITION - RebootPending, Failed, Succeeded - and an administrator needs
    # it to understand the outcome, so it goes at Info where they will see it
    # without re-running anything.
    #
    # It says where BOTH copies went and whether the mirror actually landed,
    # because "the marker disagrees with status.json" is otherwise a question
    # with nothing in the log to answer it.
    $severity = 'Info'
    if ($Status -eq 'Running') { $severity = 'Debug' }

    Write-HDTLog -Context $Context -Severity $severity -Component 'Status' `
        -Message ("run status is {0} at step {1} of {2}; written to '{3}'{4}" -f
            $Status, $stepIndexValue, $Context.StepCount, $Path,
            @(
                ''
                (" and mirrored to '{0}'" -f $ActivePath)
            )[[int] $mirrored]) `
        -Data ([ordered] @{
                status     = $Status
                stepIndex  = $stepIndexValue
                stepCount  = $Context.StepCount
                stepName   = $stepNameValue
                stepType   = $stepTypeValue
                path       = $Path
                activePath = $ActivePath
                mirrored   = $mirrored
                updated    = $updated
            })
}
