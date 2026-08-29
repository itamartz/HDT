function New-HDTStepHeartbeat {
    <#
        .SYNOPSIS
            Builds the callback a step hands to a service that is about to wait
            a long time, so the progress card keeps moving while it waits.

        .DESCRIPTION
            THE DEFECT THIS EXISTS FOR, MEASURED ON LT-7FJ45S2 RUN
            run-20260829-190105:

              Apply Windows Settings   step.start 03:04:41.370, next record
                                       03:08:02.099. Three minutes twenty-one
                                       with no record of any kind.
              Install Applications     "installing 1 of 2" 16:13:41.358, next
                                       record 16:15:38.176. One minute
                                       fifty-seven while one MSI ran.

            AND SILENCE IS NOT COSMETIC. Get-HDTDeploymentProgress derives
            everything it shows from the records themselves and holds no clock,
            deliberately - reading one there would make the answer depend on
            when it was asked. The consequence is that between two records
            nothing it reports changes at all: a technician watched a motionless
            card for three and a half minutes of a deployment that was working
            perfectly, and reasonably concluded it had hung.

            THE ELAPSED CLOCK IS NO LONGER ONE OF THOSE THINGS, and this text
            used to say it was. It was summed from the records' own timestamps
            and so was frozen between them by construction; the window now
            subtracts the step's start time from its own clock on its repaint
            timer, so the seconds move whether or not anything writes. What a
            heartbeat is still for is everything the clock cannot say: WHICH
            installer, and that the machine was alive at that instant.

            SO THE FIX IS ON THE PRODUCER SIDE. A step that is waiting emits a
            record periodically, and the derivation has something fresh to read.

            MDT'S SHAPE, BECAUSE MDT SOLVED THIS FIRST AND WINS WHERE IT
            DISAGREES. ZTIUtility.vbs's RunCommandLog does not block on a child
            process: it launches with WshShell.Exec and spins on oExec.Status
            with SafeSleep 100 (lines 2173-2201), scraping the tool's own
            percentage out of stdout as it goes - and when the tool says nothing,
            it writes a periodic heartbeat of its own, event 41003, every five
            minutes (lines 2229-2237). Poll rather than block, plus a timed
            record for the gaps. HDT does both. PSD, by contrast, is
            Start-Process -Wait everywhere (PSDUtility.psm1:1170) and has exactly
            the freeze this is fixing. See NOTICE.md.

            IT REUSES step.progress AND ADDS NO NEW EVENT NAME, and that is a
            decision rather than laziness. Get-HDTDeploymentProgress reads
            `percent` off a step.progress record CONDITIONALLY - so a record
            that carries no percent leaves StepPercent exactly where the last
            real progress record put it, while its message still reaches the
            card's activity line, which is the half a heartbeat is for. A
            heartbeat therefore cannot drag a bar backwards, which a
            step.progress carrying percent 0 would do every fifteen seconds in
            the middle of an apply that was 70% done. A new name in the
            vocabulary would have bought nothing and cost four surfaces: DESIGN
            4.4.2's table, Write-HDTLog's ValidateSet, the count the vocabulary
            contract asserts, and every reader that filters on the set.

            FIFTEEN SECONDS, AND NOT MDT'S FIVE MINUTES. MDT can afford five
            because its bar is being repainted from scraped stdout about once a
            second anyway; its heartbeat is a LOG marker, not the thing keeping
            the screen alive. Here it is the only thing moving during an MSI, so
            five minutes would be indistinguishable from the defect. Downwards
            is bounded too: Update-HDTProgressDisplay re-reads and re-parses the
            WHOLE jsonl on every record, so the cost of heartbeating is
            quadratic in the length of the deployment, and the file is read by
            CMTrace over SMB. Fifteen gives four lines a minute - forty for a
            ten-minute installer, against MDT's two - and keeps the worst case
            for a two-hour run in the hundreds of lines rather than the tens of
            thousands. It is also the stride EnableBitLocker already polls at.

            IT RATIONS ITSELF RATHER THAN TRUSTING ITS CALLER. The adapter polls
            twice a second and calls this on every poll; what decides whether a
            line is written is the clock, here. A STEP THAT FINISHES INSIDE THE
            INTERVAL THEREFORE WRITES NOTHING AT ALL, which is the rule that
            keeps a log full of SetVariable and ConfigureBoot steps unchanged.

            IT NEVER FAILS A DEPLOYMENT. Same contract as
            Update-HDTProgressDisplay and for the same reason: this runs from
            inside a service adapter's wait loop, on a machine part-way through
            installing an operating system. A missing clock, a log file that went
            with the RAM disk, a UI runspace that has died - none of them is a
            reason to stop building a computer.

        .PARAMETER Context
            The execution context. Context.Service.Clock and Context.Log are
            read, and both may be absent - a context that cannot support a
            heartbeat gets one that does nothing.

        .PARAMETER Component
            The component name the record is written under, which is the step
            type: 'InstallApplications', 'CommandLine'.

        .PARAMETER Activity
            What is being waited on, in a technician's words - an application's
            name, 'the answer file', 'the image'. IT IS A NAME AND NEVER A
            COMMAND LINE: DESIGN 4.4.5 keeps command lines at Debug because they
            routinely carry a licence key or a service account, and this record
            is written at Info.

        .PARAMETER IntervalSecond
            Seconds between records. Fifteen unless a caller has a reason.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.ScriptBlock, taking no arguments. It is
            a scriptblock rather than an object with a Tick method because
            IProcessService.Start takes an OnTick scriptblock, and an adapter
            must never learn what a log is.

        .EXAMPLE
            $heartbeat = New-HDTStepHeartbeat -Context $Context -Component 'InstallApplications' `
                -Activity ([string] $application.Name)
            $process.Start($comSpec, $argument, $sourcePath, $timeoutMillisecond, $heartbeat)

            The whole of what a step has to do. Everything else - the interval,
            the record's shape, the nudge that makes the window re-read the log -
            is here, once.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a callback object; it changes no state until the adapter invokes it, and the callback writes a log record inside a wait loop where a confirmation prompt would hang a deployment.')]
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Activity,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int] $IntervalSecond = 15
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A CONTEXT THAT CANNOT HEARTBEAT GETS ONE THAT DOES NOTHING, decided ONCE
    # here rather than re-decided on every poll. Two hundred and forty property
    # lookups a minute to establish the same absence is a cost a deployment does
    # not owe, and a caller must never have to ask whether it is worth building
    # one.
    $clock = $null
    if ($null -ne $Context -and
        $null -ne $Context.PSObject.Properties['Service'] -and $null -ne $Context.Service -and
        $null -ne $Context.Service.PSObject.Properties['Clock']) {

        $clock = $Context.Service.Clock
    }

    $log = $null
    if ($null -ne $Context -and $null -ne $Context.PSObject.Properties['Log']) {
        $log = $Context.Log
    }

    if ($null -eq $clock -or $null -eq $log) {
        return {}
    }

    # A HASHTABLE, NOT TWO VARIABLES. GetNewClosure captures by VALUE, so a
    # closed-over [datetime] the callback assigned to would be re-read as the
    # original on the next poll and every tick would fire.
    $state = @{
        StartUtc = $clock.GetUtcNow()
        LastUtc  = $clock.GetUtcNow()
    }

    # THE THREE COMMANDS, RESOLVED HERE RATHER THAN NAMED IN THE CALLBACK, AND
    # IT IS NOT STYLE. A closure built inside a module keeps its captured
    # VARIABLES but loses the module's COMMAND table: GetNewClosure gives the
    # block a fresh session state, and every name in it is then looked up in
    # whatever scope happens to invoke it - which for a service adapter's wait
    # loop is not this module. Format-HDTConsoleDuration and
    # Update-HDTProgressDisplay are private, so they come back CommandNotFound.
    #
    # AND IT FAILS IN THE WORST POSSIBLE WAY. The catch below swallows it, so
    # the heartbeat is built, handed over, invoked on schedule, and writes
    # nothing whatsoever for the entire deployment - a mechanism that is
    # written, tested and documented and has never once run. It was found by
    # running it, not by reading it.
    #
    # A COMMAND OBJECT CARRIES ITS OWN MODULE WITH IT, which a name does not, so
    # the callback invokes these through the reference and resolves correctly
    # wherever it is called from. Module.NewBoundScriptBlock is the other known
    # fix and is wrong here: it restores the command table by REPLACING the
    # session state, which discards the captured $state and $clock - the tick
    # then throws "the variable '$state' cannot be retrieved" instead.
    #
    # THE SAME THREE LINES ApplyImage AND ApplyUnattend ALREADY CARRY, in the
    # same shape and for the same reason: their dism output callbacks are
    # invoked from inside the image service, and the fake image service is a
    # PowerShell class in another module entirely.
    $writeLog = Get-Command -Name 'Write-HDTLog'
    $formatDuration = Get-Command -Name 'Format-HDTConsoleDuration'
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    $tick = {
        try {
            $now = $clock.GetUtcNow()

            # THE RATION. Everything above this line is free; a record is not.
            if (($now - $state['LastUtc']).TotalSeconds -lt $IntervalSecond) { return }

            $state['LastUtc'] = $now

            $elapsed = [int] [System.Math]::Floor(($now - $state['StartUtc']).TotalSeconds)

            # SOMETHING TRUE AND CHANGING, NOT A SPINNER. What is genuinely known
            # here is the name of the thing being waited on and how long it has
            # been waited on; a percentage derived from elapsed time would be a
            # bar that lied, which is the one thing worse than a bar that stops.
            & $writeLog -Context $log -Event 'step.progress' -Component $Component `
                -Message ('{0} - still running after {1}' -f $Activity,
                    (& $formatDuration -Second $elapsed)) `
                -Data ([ordered] @{
                    activity      = $Activity
                    elapsedSecond = $elapsed

                    # THE MARK THAT SAYS THIS IS NOT A MEASUREMENT. A reader
                    # splitting real progress from liveness needs to be able to,
                    # and the ABSENCE of percent is not something a filter can
                    # say out loud.
                    heartbeat     = $true
                })

            # AND THEN TELL THE WINDOW TO LOOK. This was the half missing from
            # ApplyDrivers: the record went to the jsonl and nothing read it
            # back, so a step reported into a file nobody was reading.
            & $updateDisplay -Context $Context
        } catch {
            # THE LAST LINE OF THE CONTRACT, and it is the same one
            # Update-HDTProgressDisplay carries. A heartbeat does not get to stop
            # a deployment, whatever happened to it.
            Write-Verbose ("the step heartbeat could not be written: {0}" -f [string] $_.Exception.Message)
        }
    }.GetNewClosure()

    return $tick
}
