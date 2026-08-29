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
            PercentComplete, StepPercent, Phase, Status, ElapsedSecond and
            RunId.

            PercentComplete AND StepPercent ARE DIFFERENT FACTS. The first is
            how many steps of the sequence are done; the second is how far
            through the one that is running - which for an apply is the only
            number that changes for nine minutes. A step reports it with
            step.progress; a step that reports nothing leaves it at zero, and
            a step that starts, finishes or is skipped clears it.

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
        StepPercent     = 0
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

    # ELAPSED IS THE SUM OF THE STRETCHES THE CLOCK RAN FORWARDS THROUGH, NOT
    # FIRST-TO-LAST. It was first-to-last, and on every deployment that reboots
    # it reported ZERO.
    #
    # WHY: WinPE boots with an unsynchronised clock (DESIGN 4.4.2 - every WinPE
    # record carries clockUnsynced true), the full OS corrects it at the first
    # sync, and the correction is routinely BACKWARDS. Measured on LT-7FJ45S2,
    # run-20260829-172208: 122 WinPE records stamped 08/30 01:22:10 to 01:29:00,
    # then reboot.resume and 18 full-OS records stamped 08/29 14:34:22 to
    # 14:36:36 - ten hours and fifty-three minutes EARLIER. The last record in
    # the file was older than the first, so the subtraction went negative, the
    # guard on it refused to write, and ElapsedSecond kept its initialised zero.
    # The technician watched "00:00:00 elapsed" for the whole of the full-OS leg
    # of a deployment that had been running two and a half hours.
    #
    # A CLOCK THAT NEVER STARTED LOOKS EXACTLY LIKE A CLOCK THAT IS STUCK, which
    # is why this was read as a heartbeat problem first.
    #
    # SEGMENTS RATHER THAN MIN-TO-MAX, AND THE DIFFERENCE IS HONESTY. Across the
    # jump nothing is measurable - the two legs are timed by two different
    # clocks and there is no offset to recover - so min-to-max would report ten
    # hours of "deployment" that was really one wrong clock, at the top of the
    # screen, in the field somebody uses to decide whether to intervene. Each
    # forward stretch is measured against itself and the measurements are added.
    # That undercounts the reboot, which is time the deployment was not running
    # anyway, and it never invents time that was not spent.
    $elapsedTicks = [long] 0
    $segmentStartTicks = [long] 0
    $previousTicks = [long] 0

    foreach ($row in $ordered) {

        # -- the timestamps, whatever else the record turns out to be --------
        $ts = [string] (& $valueOf $row 'ts')
        if (-not [string]::IsNullOrWhiteSpace($ts)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($ts, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {

                $currentTicks = [long] $parsed.Ticks

                if ($segmentStartTicks -eq 0) {
                    $segmentStartTicks = $currentTicks
                } elseif ($currentTicks -lt $previousTicks) {

                    # THE CLOCK WENT BACKWARDS, so the stretch that was being
                    # measured has ended and a new one begins here. Banking what
                    # was measured before starting again is what keeps the WinPE
                    # leg's minutes on the screen after the reboot.
                    $elapsedTicks += ($previousTicks - $segmentStartTicks)
                    $segmentStartTicks = $currentTicks
                }

                $previousTicks = $currentTicks
            }
        }

        $runId = [string] (& $valueOf $row 'runId')
        if (-not [string]::IsNullOrWhiteSpace($runId)) { $result['RunId'] = $runId }

        # The phase a record was WRITTEN in, until a phase.change says otherwise.
        $phase = [string] (& $valueOf $row 'phase')
        if (-not [string]::IsNullOrWhiteSpace($phase)) { $result['Phase'] = $phase }

        $eventName = [string] (& $valueOf $row 'event')
        if ([string]::IsNullOrWhiteSpace($eventName)) { continue }

        $data = & $valueOf $row 'data'

        switch ($eventName) {

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

            'step.progress' {
                # HOW FAR THROUGH THE STEP, WHICH IS A DIFFERENT FACT FROM HOW
                # FAR THROUGH THE SEQUENCE. For the nine minutes an apply takes,
                # it is the only number on the screen that moves.
                $percent = & $valueOf $data 'percent'
                if ($null -ne $percent) { $result['StepPercent'] = [int] $percent }
            }

            'step.start' {
                # THE STEP THAT IS STARTING HAS DONE NONE OF ITSELF YET. Without
                # this the bar would open at whatever the last step reached and
                # count down.
                $result['StepPercent'] = 0

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
                # A FINISHED STEP IS NOT A STEP THAT IS 60% DONE. The step bar
                # belongs to whatever is running now, and between two steps
                # nothing is.
                $result['StepPercent'] = 0

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

    # The stretch still open when the records ran out - which on a live run is
    # the one the machine is in - closed the same way the earlier ones were.
    if ($previousTicks -gt $segmentStartTicks) {
        $elapsedTicks += ($previousTicks - $segmentStartTicks)
    }

    if ($elapsedTicks -gt 0) {
        $result['ElapsedSecond'] = [int] [System.Math]::Floor(
            ([timespan]::FromTicks($elapsedTicks)).TotalSeconds)
    }

    # run.end IS THE ENGINE'S OWN VERDICT and outranks the counting: a run that
    # ended Failed with every step complete is a real shape, because a teardown
    # can fail after the last step.
    $result['Status'] = 'Running'
    if ($failed) { $result['Status'] = 'Failed' }
    if (-not [string]::IsNullOrWhiteSpace($endStatus)) { $result['Status'] = $endStatus }

    return [pscustomobject] $result
}
