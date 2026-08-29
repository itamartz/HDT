function New-HDTLogContext {
    <#
        .SYNOPSIS
            Builds the log context every Write-HDTLog call is written through.

        .DESCRIPTION
            A log context is DATA: the run id, the phase, the log directory, the
            two injected services, the verbosity, the monotonic seq counter and
            the step currently executing. It performs NO I/O when it is built,
            which is what lets the engine construct one in WinPE before a disk
            exists and hand the same object to every step afterwards.

            THE SEQ COUNTER LIVES HERE rather than in a module variable because it
            is seeded from state.json on resume. seq is required to
            survive reboots, "so the ordering of a multi-leg deployment is
            unambiguous even when timestamps skew across a clock change during
            specialize" - and a counter that reset on every leg would be exactly
            the ambiguity it exists to remove.

            Properties: RunId, Phase, LogPath, FileSystem, Clock, Level, Seq,
            StepIndex, StepName, StepType, StepLogPath, Component, ThreadId,
            ClockNotice, JsonlPath, MasterLogPath.

            Methods:

              SetStep($index, $name, $type, $stepLogPath)
              ClearStep()
              NextSeq()

            SetStep is what makes this true - "entries carry the step name
            automatically, so a custom step's output is attributable without the
            author doing anything".

            It is a [pscustomobject] with ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER RunId
            The deployment run id, also _HDTRunId.

        .PARAMETER Phase
            WinPE or FullOS.

        .PARAMETER LogPath
            The log directory, from Get-HDTLogPath.

        .PARAMETER FileSystem
            An IFileSystem - New-HDTFileSystem in production, the fake in a test.
            Defaults to the real one.

        .PARAMETER Clock
            An IClock - New-HDTClock in production, the fake in a test.

        .PARAMETER Level
            The verbosity floor: Error, Warning, Info or Debug. A call below it is
            dropped without consuming a seq number. Defaults to Info.

        .PARAMETER Seq
            The last seq number already written, restored from state.json on
            resume. Defaults to 0.

        .PARAMETER Component
            The default component for calls that name none. Defaults to Engine.

        .PARAMETER ThreadId
            The thread id stamped into every CMTrace line. Defaults to the
            managed thread id of the thread building the context; a test supplies
            one so it can assert an exact line.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            Write-HDTLog -Context $log -Message 'Starting' -Event run.start

            Everything the engine writes goes through one of these: a JSONL stream and
            a human-readable log beside it, from the same call.

        .EXAMPLE
            $log.JsonlPath

            The file Get-HDTRunLogRecord reads back, and the one both the progress window
            and the failure window are derived from. One source of truth, so the
            screen and the log cannot disagree.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory context object; it changes no state and performs no I/O.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $LogPath,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Level = 'Info',

        [Parameter()]
        [long] $Seq = 0,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Component = 'Engine',

        [Parameter()]
        [int] $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId,

        # WHO IS WRITING, rendered into CMTrace's own context column. Empty for
        # a deployment - see the property below - and set by the console.
        [Parameter()]
        [AllowEmptyString()]
        [string] $User = '',

        # WHERE THE SAME LINES GO WHILE THE RUN IS STILL GOING, as opposed to
        # where they are copied when it ends. MDT's SLShareDynamicLogging: a
        # UNC under the share, so a deployment can be watched in CMTrace rather
        # than waited for - and so a run that dies has already written its
        # reason somewhere that outlives the RAM disk.
        #
        # EMPTY MEANS ONE COPY, which is what every deployment did before this.
        [Parameter()]
        [AllowEmptyString()]
        [string] $DynamicPath = '',

        # WHAT THE PAIR OF FILES IS CALLED. 'HDT' gives HDT.jsonl and HDT.log,
        # which is every deployment and the reason this defaults rather than
        # asks. The console writes Console.log beside them in the share's Logs
        # folder, because a deployment log and a console log in one file would
        # interleave two machines' worth of story into one thread.
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BaseName = 'HDT'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $trimmed = $LogPath.TrimEnd('\', '/')

    $context = [pscustomobject] @{
        RunId         = $RunId
        Phase         = $Phase
        LogPath       = $trimmed
        FileSystem    = $FileSystem
        Clock         = $Clock
        Level         = $Level
        Seq           = $Seq
        StepIndex     = 0

        # HOW MANY STEPS THE RUN HAS, which is a fact about the SEQUENCE rather
        # than about the step - so it is set once by Invoke-HDTTaskSequence and
        # left alone by SetStep and ClearStep. It is here so the status heartbeat
        # can carry it: "step 7" is a number nobody can act on, and the console
        # tailing Logs\_active\ cannot work the total out from a share it is
        # only reading.
        StepCount     = 0
        StepName      = $null
        StepType      = $null
        StepLogPath   = $null
        Component     = $Component
        ThreadId      = $ThreadId

        # WHO, FOR THE LOGS THAT HAVE A WHO. Empty for a deployment: the engine
        # runs as SYSTEM in WinPE, nobody is sitting at it, and filling this
        # would change every line of every existing deployment log for no
        # answer anybody wanted. The console sets it, because its log is on the
        # share and more than one administrator writes to it.
        User          = $User

        # WHICH LOG FILES HAVE BEEN TOLD ABOUT THE CLOCK, keyed by path. WinPE's
        # clock is unsynchronised for the whole of the WinPE leg, so the caveat
        # Write-HDTLog used to suffix to every CMTrace message fired on 93
        # records out of 93 on a real machine - a column of noise rather than a
        # marker. It is announced once per file instead, and this is what
        # remembers that, and what makes a second announcement possible if the
        # answer ever changes. Keyed by PATH because the share mirror is
        # resolved after the wizard and starts mid-run: it needs its own notice,
        # not the local log's.
        ClockNotice   = @{}
        JsonlPath     = ('{0}\{1}.jsonl' -f $trimmed, $BaseName)
        MasterLogPath = ('{0}\{1}.log' -f $trimmed, $BaseName)

        # -- and the same lines, on the share, as they happen ------------------
        #
        # MDT'S SLShareDynamicLogging. HDTSLShare says where the logs go when a
        # run ENDS; this says where they go WHILE it runs, so a deployment can
        # be watched in CMTrace instead of waited for.
        #
        # WHICH IS THE HALF THAT SURVIVES A RUN THAT DIES. The end-of-run copy
        # is guarded on a log destination that is resolved AFTER the wizard, so
        # a wizard that threw took HDT.log and HDT.jsonl down with the RAM disk
        # and left nothing to read - which is exactly what happened on a
        # Latitude, and exactly the run somebody needed the log for.
        #
        # THE LOCAL COPY IS STILL THE ONE THAT MATTERS. This is a second write,
        # never a redirect: WinPE keeps its own log whatever the share does.
        # Write-HDTLog guards every mirrored append, because a share that has
        # gone away is the case this is most useful in and must never be the
        # thing that ends a deployment.
        # EMPTY IS THE DEFAULT AND WRITES ONE COPY, so every deployment built
        # before this existed behaves exactly as it did. -DynamicPath is applied
        # below, THROUGH SetDynamicPath, so the parameter and the method are one
        # composition rather than two that agree until somebody edits one.
        DynamicPath          = ''
        DynamicJsonlPath     = ''
        DynamicMasterLogPath = ''
        DynamicStepLogPath   = $null

        # ON THE CONTEXT BECAUSE A ScriptMethod CANNOT SEE THIS FUNCTION'S
        # LOCALS. Add-Member does not capture the enclosing scope, so
        # SetDynamicPath referencing the $BaseName PARAMETER threw "the variable
        # $BaseName cannot be retrieved because it has not been set" the moment
        # it was called - under StrictMode, which is what turns that into a
        # throw rather than an empty file name. Every other use of $BaseName is
        # evaluated here, at construction, which is why nothing else noticed.
        BaseName             = $BaseName
    }

    # SET AFTER THE FACT, BECAUSE THE ANSWER ARRIVES AFTER THE CONTEXT DOES.
    # The log context is built in the first seconds of a run - before the share
    # is reachable, before rules.yaml has been read and long before
    # HDTSLShareDynamicLogging has resolved. Rebuilding the context then would
    # throw away the sequence counter and every record already written, so the
    # destination is set on the context that already exists.
    #
    # AN EMPTY PATH TURNS THE MIRROR OFF AGAIN, which is what a share that
    # stopped being reachable would want if anything ever asked for it.
    $context | Add-Member -MemberType ScriptMethod -Name SetDynamicPath -Value {
        param([string] $Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            $this.DynamicPath = ''
            $this.DynamicJsonlPath = ''
            $this.DynamicMasterLogPath = ''
            $this.DynamicStepLogPath = $null
            return
        }

        $trimmed = $Path.TrimEnd('\', '/')

        # -- ONE FOLDER PER RUN, UNDER WHATEVER THE RULE RESOLVED --------------
        #
        # HDTSLShareDynamicLogging resolves to a per-MACHINE folder - the
        # shipped rule is Logs\%HDTComputerName% - and every mirrored line went
        # through AppendAllText with nothing ever rolling it. So ONE file
        # accumulated every deployment that machine had ever had. The real one
        # on this lab's share held 206 CRLF and 253 bare LF, because it carried
        # a run from before the CRLF fix beside a run from after it, and CMTrace
        # cannot parse the LF-only stretch at all.
        #
        # ROLL, NEVER TRUNCATE. Truncating destroys the previous run's evidence
        # at exactly the moment somebody re-runs BECAUSE the last one failed.
        # Nor size-based: CCM's .lo_ capping splits one deployment across two
        # files, and a deployment is the unit anybody reads.
        #
        # KEYED ON THE RUN ID, WHICH IS WHAT SURVIVES THE REBOOT. WinPE and the
        # full OS are two processes, two log roots and two contexts, and they
        # are ONE run: leg 1 mints the id, state.json carries it across the
        # restart, and Start-HDTResume builds its context with it. Composing
        # here, from $this.RunId, is what makes both legs land in one file
        # without either payload knowing the shape. Key it on anything the
        # reboot changes - the phase, the log root, the clock - and the fix
        # produces two half-logs and looks like it worked.
        #
        # THE MACHINE FOLDER IS THE ADMINISTRATOR'S AND IS LEFT ALONE. It is
        # what their rule resolved to; the run folder goes INSIDE it, which
        # matches Copy-HDTLog naming its end-of-run folders for the run too. The
        # machine name is not repeated in the leaf because it is already the
        # parent here, where in Copy-HDTLog's <computer>-<runId> it is not.
        #
        # IDEMPOTENT, BECAUSE THE PAYLOAD HANDS THE ANSWER BACK. It creates the
        # directory it was given - $log.DynamicPath, the composed one - and a
        # second call with that would otherwise go two runs deep.
        $lastSegment = $trimmed.Substring($trimmed.LastIndexOfAny([char[]] @('\', '/')) + 1)

        if ($lastSegment -ne [string] $this.RunId) {
            $trimmed = '{0}\{1}' -f $trimmed, $this.RunId
        }

        # $this.BaseName, NOT $BaseName. See the property's own note: a
        # ScriptMethod cannot see the constructing function's parameters.
        $this.DynamicPath = $trimmed
        $this.DynamicJsonlPath = '{0}\{1}.jsonl' -f $trimmed, $this.BaseName
        $this.DynamicMasterLogPath = '{0}\{1}.log' -f $trimmed, $this.BaseName

        # THE STEP LOG FOLLOWS THE STEP, and a step may already be running when
        # this is set - SetStep is what recomputes it, so it is recomputed here
        # from whatever step is current rather than left pointing nowhere.
        $this.DynamicStepLogPath = $null

        if (-not [string]::IsNullOrWhiteSpace([string] $this.StepLogPath)) {
            $leaf = ([string] $this.StepLogPath).Substring($this.LogPath.Length).TrimStart('\', '/')
            $this.DynamicStepLogPath = '{0}\{1}' -f $trimmed, $leaf
        }
    }

    $context | Add-Member -MemberType ScriptMethod -Name SetStep -Value {
        param([int] $Index, [string] $Name, [string] $Type, [string] $StepLogPath)

        $this.StepIndex = $Index
        $this.StepName = $Name
        $this.StepType = $Type
        $this.StepLogPath = $StepLogPath

        # THE STEP LOG IS MIRRORED UNDER THE SAME LEAF, so Steps\003-Format.log
        # on the machine is Steps\003-Format.log on the share. Rebuilt here
        # rather than at write time because the step path is what changes, and
        # a mirror worked out per LINE would be worked out thousands of times
        # for an answer that only moves once a step.
        $this.DynamicStepLogPath = $null

        if (-not [string]::IsNullOrWhiteSpace($this.DynamicPath) -and
            -not [string]::IsNullOrWhiteSpace($StepLogPath)) {

            $leaf = $StepLogPath.Substring($this.LogPath.Length).TrimStart('\', '/')
            $this.DynamicStepLogPath = '{0}\{1}' -f $this.DynamicPath, $leaf
        }
    }

    $context | Add-Member -MemberType ScriptMethod -Name ClearStep -Value {
        $this.StepIndex = 0
        $this.StepName = $null
        $this.StepType = $null
        $this.StepLogPath = $null
    }

    $context | Add-Member -MemberType ScriptMethod -Name NextSeq -Value {
        $this.Seq = $this.Seq + 1

        return $this.Seq
    }

    # -DynamicPath, THROUGH THE METHOD, so there is exactly one place that knows
    # what a mirror path looks like. The parameter used to compose its own -
    # trimmed, then BaseName appended - which is a second source of truth that
    # agrees with SetDynamicPath right up until one of them learns something the
    # other has not. It learned the run folder; the parameter would not have.
    #
    # STILL NO I/O. SetDynamicPath is string work on the context, which is what
    # lets this be built in WinPE before a disk or a share exists.
    if (-not [string]::IsNullOrWhiteSpace($DynamicPath)) {
        $context.SetDynamicPath($DynamicPath)
    }

    return $context
}
