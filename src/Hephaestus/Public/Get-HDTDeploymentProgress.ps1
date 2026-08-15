function Get-HDTDeploymentProgress {
    <#
        .SYNOPSIS
            Works out what the progress window should show, from the log the
            engine is already writing.

        .DESCRIPTION
            DESIGN 11.1'S PROGRESS WINDOW IS DRIVEN BY THE JSONL EVENT STREAM
            AND NOT BY A PARALLEL PROGRESS API. The engine already emits
            run.start, step.start, step.complete, step.fail, step.skip,
            phase.change and run.end with a controlled vocabulary (DESIGN
            4.4.2), so there is exactly ONE source of truth for what a
            deployment is doing: the screen and the log can never disagree, and
            a step author gets progress for free without ever calling a UI
            function.

            THIS IS THAT DERIVATION, AND IT IS PURE. No window, no runspace, no
            clock, no file system - which is what lets the whole of it be
            asserted on a developer machine with no display, and leaves the
            window itself thin enough to stay inside the adapter exemption
            (CLAUDE.md rule 1).

            ELAPSED COMES FROM THE RECORDS' OWN TIMESTAMPS. Reading a clock here
            would make the answer depend on when it was asked, and would count
            time passing during a reboot the deployment was not running through -
            a machine that spent four minutes in Windows Setup did not spend
            them in the step that is on screen.

            COMPLETED IS COUNTED, NOT INFERRED FROM THE CURRENT STEP. A bar
            driven by "current index minus one" advances the moment a step
            STARTS, so it reads 60% while the step that would make it true is
            still running - and it advances on failure, at the one moment a
            technician is reading it closely. A step counts when it reported
            complete or skip, and never when it reported fail.

            A SKIPPED STEP COUNTS. The bar is about how far through the sequence
            the deployment is, not about how much work was done; a sequence
            where half the steps are conditioned out would otherwise sit at 50%
            and finish.

            run.end IS BELIEVED OVER THE COUNTING. It is the engine's own
            verdict, and a run that ended Failed with every step complete is a
            real shape - a teardown can fail after the last step.

        .PARAMETER Record
            The log records, oldest first, as ConvertTo-HDTLogRecord writes
            them: ts, runId, seq, level, phase, stepIndex, stepName, stepType,
            component, event, message, durationMs, data.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with SequenceId,
            StepNumber, StepCount, StepName, StepType, CompletedCount,
            PercentComplete, Phase, Status, ElapsedSecond and RunId.

        .EXAMPLE
            Get-HDTDeploymentProgress -Record $record

        .EXAMPLE
            $progress = Get-HDTDeploymentProgress -Record (Get-Content $jsonl | ConvertFrom-Json)
            $window.Update($progress)

            What the progress window does on every tick: read the stream the
            engine is writing anyway, and render what comes back.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Record
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = [ordered] @{
        RunId           = ''
        SequenceId      = ''
        StepNumber      = 0
        StepCount       = 0
        StepName        = ''
        StepType        = ''
        CompletedCount  = 0
        PercentComplete = 0
        Phase           = ''
        Status          = 'Unknown'
        ElapsedSecond   = 0
    }

    $ordered = @($Record)
    if (@($ordered).Count -eq 0) { return [pscustomobject] $result }

    # A RECORD IS READ FOR WHAT IT HAS, NOT ASSUMED TO HAVE EVERYTHING. The
    # stream is a file on a RAM disk that a deployment may have been cut off in
    # the middle of writing, and a half-written line that reached the parser is
    # not a reason for the window to go blank.
    # A DICTIONARY AND A PSCustomObject BOTH ARRIVE HERE, and they are read
    # differently. ConvertFrom-Json gives the record and its data as objects
    # with properties; the engine builds the same shapes as [ordered] hashtables
    # before they are serialised, and a caller holding one in memory has no
    # reason to round-trip it through JSON first.
    #
    # A HASHTABLE'S KEYS ARE NOT ITS PROPERTIES. $table.PSObject.Properties
    # exposes Count and Keys, never 'sequenceId' - so a property-only lookup
    # silently answers $null for every value in the data block, which is exactly
    # what it did: the fields with a top-level fallback (index, name) appeared to
    # work and the ones without (sequenceId, stepCount, phase, status) came back
    # empty.
    $valueOf = {
        param([object] $Row, [string] $Name)

        if ($null -eq $Row) { return $null }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) { return $null }
            return $Row[$Name]
        }

        if ($null -eq $Row.PSObject.Properties[$Name]) { return $null }

        return $Row.$Name
    }

    $completed = New-Object -TypeName System.Collections.ArrayList
    $failed = $false
    $endStatus = ''

    $firstTicks = 0
    $lastTicks = 0

    foreach ($row in $ordered) {

        # -- the timestamps, whatever else the record turns out to be --------
        $ts = [string] (& $valueOf $row 'ts')
        if (-not [string]::IsNullOrWhiteSpace($ts)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($ts, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {

                if ($firstTicks -eq 0) { $firstTicks = $parsed.Ticks }
                $lastTicks = $parsed.Ticks
            }
        }

        $runId = [string] (& $valueOf $row 'runId')
        if (-not [string]::IsNullOrWhiteSpace($runId)) { $result['RunId'] = $runId }

        # The phase a record was WRITTEN in, until a phase.change says otherwise.
        $phase = [string] (& $valueOf $row 'phase')
        if (-not [string]::IsNullOrWhiteSpace($phase)) { $result['Phase'] = $phase }

        $event = [string] (& $valueOf $row 'event')
        if ([string]::IsNullOrWhiteSpace($event)) { continue }

        $data = & $valueOf $row 'data'

        switch ($event) {

            'run.start' {
                $sequenceId = [string] (& $valueOf $data 'sequenceId')
                if (-not [string]::IsNullOrWhiteSpace($sequenceId)) { $result['SequenceId'] = $sequenceId }

                $stepCount = & $valueOf $data 'stepCount'
                if ($null -ne $stepCount) { $result['StepCount'] = [int] $stepCount }

                # A RESUME IS A RUN STARTING, and the run before it did not
                # fail just because this one is beginning - but a run that HAS
                # failed and is being retried starts clean.
                $failed = $false
                $endStatus = ''
            }

            'phase.change' {
                $to = [string] (& $valueOf $data 'to')
                if (-not [string]::IsNullOrWhiteSpace($to)) { $result['Phase'] = $to }
            }

            'step.start' {
                $index = & $valueOf $data 'index'
                if ($null -eq $index) { $index = & $valueOf $row 'stepIndex' }
                if ($null -ne $index) { $result['StepNumber'] = [int] $index }

                $name = [string] (& $valueOf $data 'name')
                if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] (& $valueOf $row 'stepName') }
                if (-not [string]::IsNullOrWhiteSpace($name)) { $result['StepName'] = $name }

                $type = [string] (& $valueOf $data 'type')
                if ([string]::IsNullOrWhiteSpace($type)) { $type = [string] (& $valueOf $row 'stepType') }
                if (-not [string]::IsNullOrWhiteSpace($type)) { $result['StepType'] = $type }
            }

            { $_ -eq 'step.complete' -or $_ -eq 'step.skip' } {
                # BY INDEX, NOT BY COUNTING RECORDS. A step that was retried
                # logs more than one completion, and a resumed run replays
                # nothing but may complete a step the earlier leg also did.
                $index = & $valueOf $data 'index'
                if ($null -eq $index) { $index = & $valueOf $row 'stepIndex' }

                if ($null -ne $index -and -not $completed.Contains([int] $index)) {
                    [void] $completed.Add([int] $index)
                }
            }

            'step.fail' {
                $failed = $true

                $index = & $valueOf $data 'index'
                if ($null -eq $index) { $index = & $valueOf $row 'stepIndex' }
                if ($null -ne $index) { $result['StepNumber'] = [int] $index }

                $name = [string] (& $valueOf $row 'stepName')
                if (-not [string]::IsNullOrWhiteSpace($name)) { $result['StepName'] = $name }
            }

            'run.end' {
                $status = [string] (& $valueOf $data 'status')
                if (-not [string]::IsNullOrWhiteSpace($status)) { $endStatus = $status }
            }
        }
    }

    $result['CompletedCount'] = @($completed).Count

    if ($result['StepCount'] -gt 0) {
        $percent = [int] [System.Math]::Floor((100.0 * $result['CompletedCount']) / $result['StepCount'])

        # A RESUMED RUN CAN COMPLETE MORE STEPS THAN run.start COUNTED, and a
        # bar past its own end is a bar nobody believes again.
        if ($percent -gt 100) { $percent = 100 }
        $result['PercentComplete'] = $percent
    }

    if ($lastTicks -gt $firstTicks) {
        $result['ElapsedSecond'] = [int] [System.Math]::Floor(
            ([timespan]::FromTicks($lastTicks - $firstTicks)).TotalSeconds)
    }

    # run.end IS THE ENGINE'S OWN VERDICT and outranks the counting: a run that
    # ended Failed with every step complete is a real shape, because a teardown
    # can fail after the last step.
    $result['Status'] = 'Running'
    if ($failed) { $result['Status'] = 'Failed' }
    if (-not [string]::IsNullOrWhiteSpace($endStatus)) { $result['Status'] = $endStatus }

    return [pscustomobject] $result
}
