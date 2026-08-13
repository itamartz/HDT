function Write-HDTLog {
    <#
        .SYNOPSIS
            Writes one log entry in both DESIGN 4.4.2 formats, from one call.

        .DESCRIPTION
            "Every log call emits both, from a single Write-HDTLog invocation"
            (DESIGN 4.4.2):

              <_HDTLogPath>\HDT.jsonl   JSON Lines, the structured source of truth
              <_HDTLogPath>\HDT.log     CMTrace, what an administrator already reads

            and, when the context has a step log, the same CMTrace line goes to
            that per-step file as well (DESIGN 4.4.3). Nothing else in HDT writes
            a log anywhere (DESIGN 4.4.1).

            Both writes go through the context's injected IFileSystem, and the
            timestamp through its injected IClock, so the whole of DESIGN 4.4 is
            provable with nothing on disk and no wall clock (DESIGN 12.2.1). The
            adapter writes UTF-8 without a byte order mark; the PowerShell
            file-writing cmdlets are banned here for that reason and are absent
            from this file.

            SEQ IS MONOTONIC AND RESUMABLE. The counter lives on the context and
            is seeded from state.json on resume, so DESIGN 4.4.2's "seq survives
            reboots" holds across a leg boundary. A message dropped by verbosity
            does NOT consume a number and does not touch the filesystem: a hole in
            the numbering would turn a legitimate verbosity setting into evidence
            of a lost record.

            EVENT IS A CONTROLLED VOCABULARY, enforced by ValidateSet, so the
            report renderer and the console filter on a known set rather than
            regexing prose. Thirteen names: DESIGN 4.4.2's eleven, plus
            reboot.teardown for the DESIGN 4.5.3 failsafe and message for a custom
            step's bare call. Adding a fourteenth means editing DESIGN 4.4.2 as
            well - a test asserts the exact list.

            Verbosity order is Error < Warning < Info < Debug, so Level = Warning
            emits Error and Warning only (DESIGN 4.4.5).

        .PARAMETER Context
            A New-HDTLogContext result.

        .PARAMETER Message
            The message. Carriage returns and line feeds survive into the JSONL
            record and are flattened to spaces in the CMTrace line, which is line
            oriented.

        .PARAMETER Severity
            Error, Warning, Info or Debug. Defaults to Info, which is what
            DESIGN 4.4.4's bare Write-HDTLog "Checking vendor BIOS level"
            produces.

        .PARAMETER Event
            One of the thirteen vocabulary names. Defaults to message.

        .PARAMETER Component
            The subsystem the entry came from. Defaults to the context's
            component, which is Engine unless the caller set another.

        .PARAMETER Source
            The CMTrace file attribute. Defaults to the executing step's type, or
            Engine when no step is running.

        .PARAMETER Data
            Step-specific detail, carried under data rather than polluting the top
            level of the record.

        .PARAMETER DurationMs
            How long the thing being reported took.

        .OUTPUTS
            None.

        .EXAMPLE
            Write-HDTLog -Context $context -Message 'Checking vendor BIOS level'

            DESIGN 4.4.4's extensibility point: a custom step logs into the same
            stream, with the step name attached automatically.

        .EXAMPLE
            Write-HDTLog -Context $context -Message 'Applied index 1 to W:\ in 95s' `
                -Event step.complete -Component ImageService -DurationMs 95120 `
                -Data ([ordered] @{ index = 1; target = 'W:\' })

            The full DESIGN 4.4.2 record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event',
        Justification = 'DESIGN 4.4.2 names this field event; it is never PowerShell eventing''s automatic variable.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Severity = 'Info',

        [Parameter()]
        [ValidateSet(
            'message',
            'native.exec',
            'phase.change',
            'reboot.arm',
            'reboot.resume',
            'reboot.teardown',
            'run.end',
            'run.start',
            'step.complete',
            'step.fail',
            'step.skip',
            'step.start',
            'var.resolve')]
        [string] $Event = 'message',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Component,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Data,

        [Parameter()]
        [long] $DurationMs
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Error < Warning < Info < Debug. A call at or below the context's level is
    # emitted; anything more verbose is dropped whole.
    $rank = @{ Error = 0; Warning = 1; Info = 2; Debug = 3 }

    if ($rank[$Severity] -gt $rank[[string] $Context.Level]) {
        return
    }

    $componentName = [string] $Context.Component
    if ($PSBoundParameters.ContainsKey('Component')) {
        $componentName = $Component
    }

    $sourceName = 'Engine'
    if (-not [string]::IsNullOrWhiteSpace([string] $Context.StepType)) {
        $sourceName = [string] $Context.StepType
    }
    if ($PSBoundParameters.ContainsKey('Source')) {
        $sourceName = $Source
    }

    $timestamp = $Context.Clock.GetUtcNow()
    $seq = $Context.NextSeq()

    $argument = @{
        Context   = $Context
        Timestamp = $timestamp
        Seq       = $seq
        Level     = $Severity
        Event     = $Event
        Component = $componentName
        Message   = $Message
    }

    if ($PSBoundParameters.ContainsKey('DurationMs')) {
        $argument['DurationMs'] = $DurationMs
    }

    if ($PSBoundParameters.ContainsKey('Data') -and $null -ne $Data) {
        $argument['Data'] = $Data
    }

    $record = ConvertTo-HDTLogRecord @argument

    # -Compress is mandatory: JSON Lines is one object per PHYSICAL line, and the
    # default rendering spans many.
    $json = ConvertTo-Json -InputObject $record -Depth 8 -Compress

    $line = ConvertTo-HDTCmTraceLine -Message $Message -Component $componentName `
        -Severity $Severity -Timestamp $timestamp -ThreadId ([int] $Context.ThreadId) -File $sourceName

    $Context.FileSystem.AppendAllText($Context.JsonlPath, ($json + "`n"))
    $Context.FileSystem.AppendAllText($Context.MasterLogPath, ($line + "`n"))

    if (-not [string]::IsNullOrWhiteSpace([string] $Context.StepLogPath)) {
        $Context.FileSystem.AppendAllText([string] $Context.StepLogPath, ($line + "`n"))
    }
}
