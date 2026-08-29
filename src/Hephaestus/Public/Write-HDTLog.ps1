function Write-HDTLog {
    <#
        .SYNOPSIS
            Writes one log entry in both formats, from one call.

        .DESCRIPTION
            "Every log call emits both, from a single Write-HDTLog invocation"
:

              <_HDTLogPath>\HDT.jsonl   JSON Lines, the structured source of truth
              <_HDTLogPath>\HDT.log     CMTrace, what an administrator already reads

            and, when the context has a step log, the same CMTrace line goes to
            that per-step file as well. Nothing else in HDT writes
            a log anywhere.

            Both writes go through the context's injected IFileSystem, and the
            timestamp through its injected IClock, so the whole of the logging path is
            provable with nothing on disk and no wall clock. The
            adapter writes UTF-8 without a byte order mark; the PowerShell
            file-writing cmdlets are banned here for that reason and are absent
            from this file.

            SEQ IS MONOTONIC AND RESUMABLE. The counter lives on the context and
            is seeded from state.json on resume, so "seq survives
            reboots" holds across a leg boundary. A message dropped by verbosity
            does NOT consume a number and does not touch the filesystem: a hole in
            the numbering would turn a legitimate verbosity setting into evidence
            of a lost record.

            EVENT IS A CONTROLLED VOCABULARY, enforced by ValidateSet, so the
            report renderer and the console filter on a known set rather than
            regexing prose. The names are the ones DESIGN 4.4.2 tabulates, and a
            contract test asserts the two lists against each other in both
            directions - so adding a name here without documenting it fails, and
            documenting one the engine will not accept fails too.

            THE COUNT IS DELIBERATELY NOT WRITTEN HERE. This said "fourteen"
            while the ValidateSet held twenty-two, and the .PARAMETER below said
            "thirteen": the test enforces the NAMES, nothing enforces a number
            in a sentence, and a number in prose beside an enforced list is a
            number that drifts. Read the ValidateSet.

            Verbosity order is Error < Warning < Info < Debug, so Level = Warning
            emits Error and Warning only.

            THE CLOCK CAVEAT IS ANNOUNCED ONCE PER LOG FILE, not appended to
            every message. DESIGN 4.4.2: WinPE's clock is unsynchronised for the
            whole of the WinPE leg, so a per-line marker fires on every line and
            is not a marker. The jsonl keeps clockUnsynced on every record.

        .PARAMETER Context
            A New-HDTLogContext result.

        .PARAMETER Message
            The message. Carriage returns and line feeds survive into the JSONL
            record and are flattened to spaces in the CMTrace line, which is line
            oriented.

        .PARAMETER Severity
            Error, Warning, Info or Debug. Defaults to Info, which is what
            a bare Write-HDTLog "Checking vendor BIOS level"
            produces.

        .PARAMETER Event
            One of the vocabulary names DESIGN 4.4.2 tabulates. Defaults to
            message.

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
            $context = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock (New-HDTClock)
            Write-HDTLog -Context $context -Message 'Checking vendor BIOS level'

            The extensibility point: a custom step logs into the same
            stream, with the step name attached automatically.

        .EXAMPLE
            Write-HDTLog -Context $context -Message 'Applied index 1 to W:\ in 95s' `
                -Event step.complete -Component ImageService -DurationMs 95120 `
                -Data ([ordered] @{ index = 1; target = 'W:\' })

            A full record, with every optional field populated.
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
            # THE DRIVER DECISION IS ITS OWN VOCABULARY, for the reason
            # var.resolve is: "why did this machine get that driver" is a
            # question asked of a finished deployment, and it is answered by
            # FILTERING the log, not by reading it. driver.group says which
            # folder was resolved and whether it was there, driver.fallback says
            # a PnP match happened and why, driver.enumerate how many devices
            # the machine reported, driver.match the id and rank behind each
            # choice, and driver.staged where the package was copied and how
            # many files went with it. MDT put all of this in ZTIDrivers.log;
            # these are the records that let Copy-HDTLog split the same file
            # back out.
            #
            # driver.injected WAS ONE OF THESE and is not any more: the step
            # copies packages to the machine rather than calling DISM per
            # driver, so nothing can emit it. A name the engine will not accept
            # and the design does not document is one nobody can log by
            # accident.
            # THE CONSOLE'S OWN THREE, added because it had no log at all and a
            # reported crash could only be answered by reading source. They are
            # separate names so a session can be filtered down to what was
            # pressed (console.action), what went wrong (console.error), and
            # where a window started and stopped (console.session) - the three
            # questions asked of a UI that misbehaved, in that order.
            'console.action',
            'console.error',
            'console.session',
            'driver.enumerate',
            'driver.fallback',
            'driver.group',
            'driver.match',
            'driver.staged',
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
            'step.progress',
            'step.skip',
            'step.start',
            # TWO NAMES, BECAUSE ONE OF THEM MEANT THREE THINGS. var.resolve is
            # "this variable TOOK this value, and here is where from" - true of a
            # rule resolution, a SetVariable step and a gathered fact alike, with
            # data.source as the discriminator, which is why they share one name
            # rather than having three: a consumer asking "where did
            # HDTComputerName come from" filters ONE name and reads one field.
            #
            # var.unresolved is the opposite claim - the variable did NOT take a
            # value. A %Var% nothing supplied, a fact the machine could not
            # determine, a resolved value KEPT because the gather's answer was a
            # non-answer. Filed under var.resolve, as all of these were, they put
            # rows with no name, no value and no source into
            # ConvertTo-HDTReport's Variables table, which reads exactly those
            # three fields out of data.
            'var.resolve',
            'var.unresolved')]
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

    # THE USER, WHEN THE CONTEXT CARRIES ONE. A deployment's context does not -
    # the engine runs as SYSTEM and its logs are byte-for-byte what they were -
    # but the console's does, because its log lives on the share where two
    # administrators append to one file.
    $userContext = ''
    if ($null -ne $Context.PSObject.Properties['User']) { $userContext = [string] $Context.User }

    $line = ConvertTo-HDTCmTraceLine -Message $Message -Component $componentName `
        -Severity $Severity -Timestamp $timestamp -ThreadId ([int] $Context.ThreadId) -File $sourceName `
        -UserContext $userContext

    # -- the clock caveat, ANNOUNCED ONCE rather than repeated -----------------
    #
    # CMTrace has no column for a field we invented, so clockUnsynced is
    # invisible to the reader most likely to be looking at a skewed timestamp
    # unless the rendering says it. It said it by suffixing "(clock unsynced)"
    # to every message - and WinPE's clock is unsynchronised for the WHOLE of
    # the WinPE leg, so on a real Latitude that fired on 93 records out of 93.
    # A marker that is on every line is not a marker; it is a column of noise
    # down the log, and it made the file materially harder to read.
    #
    # So the run says it ONCE, as its own entry, at the point it first becomes
    # true - and says so again if it ever clears, because a reader then knows
    # exactly which stretch of the log is suspect. The jsonl is untouched: every
    # record still carries the boolean, which is the surface a filter wants and
    # the reason the CMTrace line does not have to repeat it.
    #
    # ONCE PER FILE, NOT ONCE PER PROCESS. HDTSLShareDynamicLogging is resolved
    # after the wizard, so the share mirror starts mid-run; keyed by path, the
    # mirror gets its own notice the first time it is written to instead of
    # inheriting a "told you already" from a file the watcher cannot see.
    #
    # THE STEP LOGS GET NOTHING. The clock is a fact about the run, and a
    # per-step file that opened with a caveat about the run would be the same
    # noise one directory down.
    $clockUnsynced = [bool] $record['clockUnsynced']
    $clockNotice = $null
    if ($null -ne $Context.PSObject.Properties['ClockNotice']) { $clockNotice = $Context.ClockNotice }

    # Returns the notice entry a given file is owed, or '' when it is owed
    # nothing. It does NOT record that the file was told: that is done by the
    # caller, after the append succeeded, so a share that was unreachable for
    # one line is still told when it comes back.
    $clockNoticeFor = {
        param([string] $Path)

        if ($null -eq $clockNotice) { return '' }

        $announced = $null
        if ($clockNotice.Contains($Path)) { $announced = [bool] $clockNotice[$Path] }

        # Nothing to say when the file already knows, and nothing to say to a
        # file whose first record is trustworthy - a full-OS log would otherwise
        # open by announcing that its clock is fine, which nobody asked.
        if ($announced -eq $clockUnsynced) { return '' }
        if ($null -eq $announced -and -not $clockUnsynced) { return '' }

        $noticeMessage = 'Clock synchronised: the timestamps that follow are the deployment''s own'
        $noticeSeverity = 'Info'

        if ($clockUnsynced) {
            $noticeMessage = 'Clock not synchronised: the timestamps that follow are WinPE''s own, not the deployment''s - ordering comes from seq'
            $noticeSeverity = 'Warning'
        }

        return (ConvertTo-HDTCmTraceLine -Message $noticeMessage -Component $componentName `
                -Severity $noticeSeverity -Timestamp $timestamp -ThreadId ([int] $Context.ThreadId) `
                -File $sourceName -UserContext $userContext)
    }

    # TWO FORMATS, TWO SEPARATORS, AND THEY ARE NOT INTERCHANGEABLE.
    #
    # CMTrace's parser is line oriented and breaks entries on CRLF. Given bare
    # line feeds it never separates one entry from the next, its
    # <![LOG[...]LOG]!> match fails, and it shows raw text with the Component,
    # Date/Time and Thread columns EMPTY - every attribute present in the bytes
    # and the reader never reaching them. That is what shipped: sixteen HDT.log
    # files on the lab share, CR=0 in all of them, and a technician correctly
    # reporting that the component was missing from a file that contained it.
    #
    # The tests could not see it because they split on "`n", which matches both.
    #
    # THE JSONL KEEPS THE LINE FEED. JSON Lines defines its separator as \n, so
    # "fix the newlines" applied to all four writes would break the reader that
    # works in order to repair the one that does not.
    #
    # THIS IS THE RULE THE BUILD ALREADY FOLLOWS, not a new one: DESIGN 11 says
    # startnet.cmd is "written ASCII with CRLF and no BOM" for the same reason -
    # a file a Windows tool parses gets the terminator that tool splits on.
    $Context.FileSystem.AppendAllText($Context.JsonlPath, ($json + "`n"))

    # ITS OWN APPEND, not a two-entry string: one append is one CMTrace entry
    # everywhere else in this function, and the CRLF tests hold every write to
    # exactly one terminator each.
    $masterNotice = & $clockNoticeFor ([string] $Context.MasterLogPath)
    if (-not [string]::IsNullOrEmpty($masterNotice)) {
        $Context.FileSystem.AppendAllText($Context.MasterLogPath, ($masterNotice + "`r`n"))
        $clockNotice[[string] $Context.MasterLogPath] = $clockUnsynced
    }

    $Context.FileSystem.AppendAllText($Context.MasterLogPath, ($line + "`r`n"))

    if (-not [string]::IsNullOrWhiteSpace([string] $Context.StepLogPath)) {
        $Context.FileSystem.AppendAllText([string] $Context.StepLogPath, ($line + "`r`n"))
    }

    # -- and the same three, on the share, as they happen ---------------------
    #
    # MDT'S SLShareDynamicLogging. The writes above are the ones that matter and
    # they have already happened; these are a second copy under a UNC so a
    # deployment can be watched in CMTrace rather than waited for.
    #
    # IT IS WHAT SURVIVES A RUN THAT DIES. The end-of-run copy is guarded on a
    # log destination resolved AFTER the wizard, so a wizard that threw took
    # HDT.log down with the RAM disk and left nothing to read - on a real
    # Latitude, on the one run somebody needed the log for.
    #
    # EVERY APPEND IS GUARDED, SEPARATELY. A share that has gone away is the
    # case this is most useful in, and a deployment that ended because its
    # LOGGING failed would be the logging causing the outage it was installed to
    # explain. Write-HDTStatus mirrors its heartbeat under exactly this rule.
    #
    # NOT ONE try ROUND ALL THREE: the jsonl failing must not cost the CMTrace
    # line, which is the one a technician actually reads.
    if ([string]::IsNullOrWhiteSpace([string] $Context.DynamicPath)) { return }

    # The mirror's own copy of the clock notice, because the mirror starts
    # mid-run and would otherwise never carry it - see $clockNoticeFor above.
    # Notice is the flag that says "record that this file has now been told",
    # and it is only set after the append it belongs to has succeeded.
    $mirrorNotice = ''
    if (-not [string]::IsNullOrWhiteSpace([string] $Context.DynamicMasterLogPath)) {
        $mirrorNotice = & $clockNoticeFor ([string] $Context.DynamicMasterLogPath)
    }

    $mirror = @(
        @{ Path = [string] $Context.DynamicJsonlPath; Text = ($json + "`n"); Notice = $false }
        @{ Path = [string] $Context.DynamicMasterLogPath; Text = ($mirrorNotice + "`r`n"); Notice = $true
            Skip = [string]::IsNullOrEmpty($mirrorNotice)
        }
        @{ Path = [string] $Context.DynamicMasterLogPath; Text = ($line + "`r`n"); Notice = $false }
        @{ Path = [string] $Context.DynamicStepLogPath; Text = ($line + "`r`n"); Notice = $false }
    )

    foreach ($current in $mirror) {
        if ([string]::IsNullOrWhiteSpace($current.Path)) { continue }
        if ($current.Contains('Skip') -and $current.Skip) { continue }

        try {
            $Context.FileSystem.AppendAllText($current.Path, $current.Text)

            if ($current.Notice) { $clockNotice[[string] $current.Path] = $clockUnsynced }
        } catch {
            # Write-Verbose, NOT Write-Warning. A share that has gone will fail
            # on every line for the rest of the deployment, and a warning per
            # line would bury the run's own output in its logging's complaints.
            Write-Verbose ("the log could not be mirrored to '{0}': {1}" -f
                $current.Path, $_.Exception.Message)
        }
    }
}
