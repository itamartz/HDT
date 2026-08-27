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
            JsonlPath, MasterLogPath.

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
        JsonlPath     = ('{0}\{1}.jsonl' -f $trimmed, $BaseName)
        MasterLogPath = ('{0}\{1}.log' -f $trimmed, $BaseName)
    }

    $context | Add-Member -MemberType ScriptMethod -Name SetStep -Value {
        param([int] $Index, [string] $Name, [string] $Type, [string] $StepLogPath)

        $this.StepIndex = $Index
        $this.StepName = $Name
        $this.StepType = $Type
        $this.StepLogPath = $StepLogPath
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

    return $context
}
