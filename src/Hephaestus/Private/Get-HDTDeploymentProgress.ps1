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

            IT REPORTS TIMES, NOT DURATIONS. A record says WHAT is happening;
            only a clock can say HOW LONG. This has no clock and must not grow
            one - reading one here would make the answer depend on when it was
            asked - so it hands back the times it can read off the stream
            (StepStartTime, RunStartTime) and the view subtracts them from its
            own clock. See the long note at the timestamp parse below for the
            defect that forced the split.

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
            PercentComplete, StepPercent, Activity, Phase, Status,
            StepStartTime, RunStartTime and RunId.

            PercentComplete AND StepPercent ARE DIFFERENT FACTS. The first is
            how many steps of the sequence are done; the second is how far
            through the one that is running - which for an apply is the only
            number that changes for nine minutes. A step reports it with
            step.progress; a step that reports nothing leaves it at zero, and
            a step that starts, finishes or is skipped clears it.

            Activity IS WHICH ONE OF THE MANY. "Install Applications" is one
            step and eleven installers, and a technician watching a machine sit
            on that name for twenty minutes cannot tell Acrobat from the one
            that hung. Every step that loops already writes what it is on -
            "installing 1 of 2: Acrobat Acrobat Reader DC", "staging Latitude
            5420: 64%", "Acrobat ... - still running after 45s" - so this is the
            step.progress record's own message, carried through unchanged.

            THE MESSAGE, NOT SOMETHING REBUILT FROM data. The message is already
            written for a person to read, it is identical in the log and on the
            screen (DESIGN 11.1: they cannot disagree because they are the same
            fact), and it is the ONE field every step type fills the same way -
            data carries application, package or imagePath depending on who
            wrote it, so composing from data would mean a new branch here every
            time somebody adds a step type, and a blank line on screen for the
            one they forgot.

            AND IT CLEARS AT EVERY STEP BOUNDARY, exactly as StepPercent does
            and for the same reason: the last thing the previous step said,
            sitting under the next step's name, is a screen telling a technician
            something that is no longer true.

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
        StepPercent     = 0
        Activity        = ''

        # THE TWO CLOCKS' STARTING POINTS, AND $null MEANS "NOT YET". A run that
        # has not reached its first step has no step to time, and zero here
        # would be the year 1 AD rendered as a fortnight of elapsed.
        StepStartTime   = $null
        RunStartTime    = $null
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

    foreach ($row in $ordered) {

        # -- the timestamps, whatever else the record turns out to be --------
        #
        # A TIME THIS FUNCTION HANDS OVER, AND NEVER A DURATION IT WORKED OUT.
        #
        # THE CLOCK USED TO BE COMPUTED HERE, AND IT FROZE. ElapsedSecond was
        # the sum of the stretches the records' own timestamps ran forwards
        # through, which advances only when something WRITES a record - so
        # between records it was frozen by construction. Measured on LT-D5M1NN3,
        # run-20260829-223623: step 7 "Apply Windows Settings" wrote step.start
        # and then nothing for minutes, and the number on the card did not move
        # once. Gaps of 12.7s, 12.3s, 10.2s and 9.3s in the driver step of that
        # same run. A clock that only ticks when somebody speaks is not a clock.
        #
        # THE BACKWARDS JUMP THAT PUT IT THERE IS REAL, AND NOTHING BELOW MAY
        # "SIMPLIFY" IT AWAY. WinPE boots with an unsynchronised clock (DESIGN
        # 4.4.2 - every WinPE record carries clockUnsynced true), the full OS
        # corrects it at the first sync, and the correction is routinely
        # BACKWARDS. Measured on LT-7FJ45S2, run-20260829-172208: 122 WinPE
        # records stamped 08/30 01:22:10 to 01:29:00, then reboot.resume and 18
        # full-OS records stamped 08/29 14:34:22 to 14:36:36 - ten hours and
        # fifty-three minutes EARLIER. The last record in the file was older
        # than the first, first-to-last went negative, and the technician
        # watched "00:00:00 elapsed" for a run that had been going two and a
        # half hours.
        #
        # WHY MOVING THE SUBTRACTION TO THE VIEW SURVIVES BOTH. The window
        # subtracts StepStartTime from the SAME CLOCK that stamped it - the
        # machine's own, this side of the reboot - so WinPE's skew cancels out
        # of the difference even while the absolute time is nonsense. And the
        # jump cannot be straddled, because the resumed leg is a new process
        # with a new window that starts from the resumed step's own step.start.
        # There is no stretch left for a wrong clock to be measured across, so
        # there is nothing left to bank into segments.
        $rowTime = $null

        $ts = [string] (& $valueOf $row 'ts')
        if (-not [string]::IsNullOrWhiteSpace($ts)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($ts, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {

                # UTC, BECAUSE THE VIEW SUBTRACTS IT FROM UtcNow. ts is written
                # by ConvertTo-HDTLogRecord as ToUniversalTime().ToString('o'),
                # which always carries the Z - so RoundtripKind gives Kind Utc
                # and this converts nothing. A record hand-written without one
                # parses as Unspecified, and it is stamped rather than shifted:
                # every writer of this field writes UTC, so treating it as local
                # would invent the machine's own offset out of nowhere.
                if ($parsed.Kind -eq [System.DateTimeKind]::Unspecified) {
                    $parsed = [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
                }

                $rowTime = $parsed.ToUniversalTime()
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

                if ($null -ne $rowTime) { $result['RunStartTime'] = $rowTime }

                # A RESUME IS A RUN STARTING, and the run before it did not
                # fail just because this one is beginning - but a run that HAS
                # failed and is being retried starts clean.
                $failed = $false
                $endStatus = ''

                # AND NOTHING IS RUNNING AT THE INSTANT A RUN STARTS. The leg
                # before the reboot left its last step.start in this same file;
                # carrying that time across would open the resumed window on a
                # clock that had already been going for the whole of WinPE, and
                # timed by WinPE's wrong clock at that.
                $result['StepStartTime'] = $null
                $result['Activity'] = ''
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

                # WHICH OF THE ELEVEN INSTALLERS IT IS ON. See the header: the
                # record's own message, unchanged, because it was written for a
                # person to read and every step type writes it the same way.
                #
                # A HEARTBEAT IS ONE OF THESE, AND IT CARRIES NO percent - the
                # guard above is what keeps it from resetting the bar, and this
                # line is what puts its "still running after 45s" on the screen,
                # which is the whole reason a step that has gone quiet writes
                # one at all.
                $activity = [string] (& $valueOf $row 'message')
                if (-not [string]::IsNullOrWhiteSpace($activity)) { $result['Activity'] = $activity }
            }

            'step.start' {
                # THE STEP THAT IS STARTING HAS DONE NONE OF ITSELF YET. Without
                # this the bar would open at whatever the last step reached and
                # count down.
                $result['StepPercent'] = 0

                # AND IT HAS NOT SAID WHAT IT IS DOING YET EITHER. Blank is
                # honest for the second or two before the first step.progress
                # arrives; the previous step's last line would be a screen
                # stating something that stopped being true one record ago.
                $result['Activity'] = ''

                # THE CLOCK THE WINDOW RUNS STARTS HERE, and this is the only
                # place it is set. Everything about how long the step has been
                # going is then a subtraction the view does against its own
                # clock, once a second, whether or not anything writes a record.
                if ($null -ne $rowTime) { $result['StepStartTime'] = $rowTime }

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
                # nothing is - and the same is true of the line that says which
                # installer it was on.
                $result['StepPercent'] = 0
                $result['Activity'] = ''

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

    # run.end IS THE ENGINE'S OWN VERDICT and outranks the counting: a run that
    # ended Failed with every step complete is a real shape, because a teardown
    # can fail after the last step.
    $result['Status'] = 'Running'
    if ($failed) { $result['Status'] = 'Failed' }
    if (-not [string]::IsNullOrWhiteSpace($endStatus)) { $result['Status'] = $endStatus }

    return [pscustomobject] $result
}
