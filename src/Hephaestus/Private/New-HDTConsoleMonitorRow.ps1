function New-HDTConsoleMonitorRow {
    <#
        .SYNOPSIS
            One deployment's row on the monitoring view.

        .DESCRIPTION
            Split out of Get-HDTConsoleMonitor because reading a heartbeat and
            judging a heartbeat are two jobs, and the second one has all the
            decisions in it: what health means, what the row says, and what a
            file that would not parse still gets to show.

            HEALTH IS FOUR STATES AND NOT A BOOLEAN. Live and Stalled are the
            two an operator acts on; Finished exists so a completed run cannot
            age into a red row; Unreadable exists so a file caught mid-write
            still puts its machine on the screen.

            AN UNREADABLE HEARTBEAT KEEPS ITS ID, because the id is in the file
            NAME - <RunId>.json - and that is legible when nothing inside the
            file is. It sorts to the top by having no age of its own, which is
            where a machine nobody can see the state of belongs.

            THE ROW LEADS WITH THE RUN AND THE STEP. Those are what a person
            scanning twenty rows is matching against: which machine, and how far
            has it got.

        .PARAMETER RunId
            The run, taken from the file name.

        .PARAMETER Path
            The heartbeat file.

        .PARAMETER Document
            The parsed heartbeat, or nothing if it would not parse.

        .PARAMETER Now
            The instant to measure age against, in UTC.

        .PARAMETER StaleMinute
            How long a heartbeat may go unwritten before its run is stalled.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            New-HDTConsoleMonitorRow -RunId 'RUN-0001' -Path $path -Document $document -Now $now -StaleMinute 20
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds one row of a display model in memory; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 3)]
        [datetime] $Now,

        [Parameter(Mandatory = $true, Position = 4)]
        [int] $StaleMinute
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $command = "ConvertFrom-Json -InputObject ((New-HDTFileSystem).ReadAllText('{0}'))" -f $Path

    # -- the file that would not parse -------------------------------------

    if ($null -eq $Document) {
        return [pscustomobject] @{
            RunId       = $RunId
            Phase       = ''
            RunStatus   = ''
            StepIndex   = 0
            StepCount   = 0
            StepText    = ''
            StepName    = ''
            StepType    = ''
            Updated     = $null
            SinceSecond = -1
            SinceText   = ''
            Health      = 'Unreadable'
            Icon        = [string] ([char] 0x26A0)      # warning sign
            Text        = '{0} - the heartbeat could not be read' -f $RunId
            Path        = $Path
            Command     = $command
        }
    }

    $property = @($Document.PSObject.Properties.Name)

    $read = {
        param([string] $Name, [object] $Fallback)

        if ($property -contains $Name) { return $Document.$Name }
        return $Fallback
    }

    $phase = [string] (& $read 'phase' '')
    $runStatus = [string] (& $read 'status' '')
    $stepIndex = [int] (& $read 'stepIndex' 0)
    $stepCount = [int] (& $read 'stepCount' 0)
    $stepName = [string] (& $read 'stepName' '')
    $stepType = [string] (& $read 'stepType' '')

    # -- how long since it said anything -----------------------------------

    $updated = $null

    # -1 MEANT TWO DIFFERENT THINGS AND THAT WAS THE BUG. It was the sentinel for
    # "this heartbeat carries no timestamp", and it was ALSO what the arithmetic
    # produced when the machine's clock was AHEAD of the console's - which is the
    # normal state of a machine in WinPE, where nothing syncs a clock and there
    # is no time zone until the sequence sets one. A live deployment eight hours
    # ahead was therefore branded Unreadable, counted as finished, and shown with
    # its last heartbeat as "(never)".
    #
    # So the two are separate now: $hasStamp says whether one was read at all,
    # and $since is free to be negative.
    $hasStamp = $false
    $since = -1

    $stamp = & $read 'updated' $null

    # ConvertFrom-Json ALREADY TURNED IT INTO A [datetime], and casting that back
    # to a string is where three hours went missing. PowerShell's JSON reader
    # silently converts an ISO-8601 string into a DateTime - a LOCAL one - so
    # [string] renders it in the current culture ("16/08/2026 01:00:00"), and
    # parsing THAT as a round-trip timestamp reads the local wall clock as
    # though it were UTC. Every age on this screen came out one time-zone
    # offset too large, on a host east of UTC, and the failures pointed at the
    # arithmetic rather than at the cast.
    #
    # So the value is taken as it arrives, whichever it is. A share is also
    # entitled to hold a heartbeat written by something that quoted the field
    # differently, and the string path still reads it.
    if ($stamp -is [datetime]) {
        $updated = ([datetime] $stamp).ToUniversalTime()
        $since = [int] ($Now - $updated).TotalSeconds
        $hasStamp = $true
    } elseif (-not [string]::IsNullOrWhiteSpace([string] $stamp)) {
        $parsed = [datetime]::MinValue

        # RoundtripKind ALONE, and the conversion by hand. Write-HDTStatus
        # formats with 'o' precisely so this can be read back without a culture
        # in the middle of it, and 'o' carries the offset - which is what
        # RoundtripKind honours. It cannot be combined with AdjustToUniversal:
        # .NET rejects the pair outright rather than ignoring one of them.
        if ([datetime]::TryParse([string] $stamp, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {

            $updated = $parsed.ToUniversalTime()
            $since = [int] ($Now - $updated).TotalSeconds
            $hasStamp = $true
        }
    }

    # A HEARTBEAT FROM THE FUTURE IS NOT OLD. Clamping to zero keeps it out of
    # the stale threshold and off the "(never)" path, and "in 8 hours" is not
    # something anybody needs on this screen: what matters is that the machine
    # is still talking.
    if ($hasStamp -and $since -lt 0) { $since = 0 }

    # -- what that makes it ------------------------------------------------
    #
    # WHAT THE ENGINE SAID, TAKEN AT ITS WORD. Invoke-HDTTaskSequence writes
    # four statuses - Running, RebootPending, Succeeded and Failed - and this
    # used to ask only "is it the literal string Running?", calling everything
    # else Finished. Three different things wore one green tick:
    #
    #   - a run waiting to REBOOT read as Finished, halfway through its
    #     sequence. It was caught sitting at 'Finished' on step 9 of 12;
    #   - a run that FAILED read as Finished, with a green tick and no warning,
    #     which made a failure invisible on the one screen built to surface it;
    #   - a run that SUCCEEDED read as Finished, the only one that was right.
    #
    # AN UNKNOWN STATUS DOES NOT GET TO CLAIM SUCCESS. Anything not recognised
    # here - including the blank a heartbeat from an older engine carries - is
    # treated as still in flight and left to the stale rule below. Being wrong
    # about "still going" costs a second look; being wrong about "finished"
    # costs a machine nobody goes back to.
    $health = 'Live'

    if ($runStatus -eq 'Succeeded') {
        $health = 'Finished'
    } elseif ($runStatus -eq 'Failed') {
        $health = 'Failed'
    } elseif ($runStatus -eq 'RebootPending') {
        $health = 'Rebooting'
    }

    # A VERDICT IS NOT AGED; A CLAIM IS.
    #
    # Succeeded and Failed are terminal - a completed heartbeat is not a
    # heartbeat that stopped, and ageing one into a red row teaches a technician
    # to ignore red. Failed also survives a missing timestamp, because the
    # verdict is known even when the clock is not, and Unreadable would throw
    # away the one fact that matters.
    #
    # Running and RebootPending are the opposite: both CLAIM something is still
    # happening, so silence past the stale window means the claim is what went
    # wrong. A machine that rebooted and never came back is precisely the
    # failure this screen exists for.
    if ($health -eq 'Live' -or $health -eq 'Rebooting') {
        if (-not $hasStamp) {
            # It parsed, but carried no timestamp anybody can read. NOT the same
            # as a timestamp merely ahead of this console's clock.
            $health = 'Unreadable'
        } elseif ($since -gt ($StaleMinute * 60)) {
            $health = 'Stalled'
        }
    }

    $icon = [string] ([char] 0x25B6)                    # play - running
    if ($health -eq 'Rebooting') { $icon = [string] ([char] 0x21BB) }   # clockwise arrow - going round again
    if ($health -eq 'Stalled') { $icon = [string] ([char] 0x26A0) }
    if ($health -eq 'Finished') { $icon = [string] ([char] 0x2714) }
    # A CROSS, NOT THE WARNING TRIANGLE. Stalled means "nobody knows"; Failed
    # means "the engine knows, and it went wrong". Sharing a glyph would flatten
    # a verdict into a doubt.
    if ($health -eq 'Failed') { $icon = [string] ([char] 0x2716) }
    if ($health -eq 'Unreadable') { $icon = [string] ([char] 0x26A0) }

    $sinceText = ''
    if ($since -ge 0) { $sinceText = Format-HDTConsoleDuration -Second $since }

    # WHEN IT SPOKE, NOT ONLY HOW LONG AGO. The tree row is SCANNED - 'is this
    # one still moving?' - and an age answers that. The detail pane is READ, and
    # what gets written into a ticket or lined up against a log is a time.
    #
    # LOCAL, BECAUSE THE CONSOLE IS ON SOMEBODY'S DESK. The heartbeat is stored
    # in UTC and compared in UTC; this is the only place it becomes a wall
    # clock, and it becomes the reader's.
    #
    # AND THE FORMAT IS FIXED RATHER THAN THE CULTURE'S. Three hours went
    # missing once to a [string] cast that rendered a DateTime in the current
    # culture and then had it parsed back as a round-trip stamp - see the note
    # on $stamp above. 'dd/MM' against 'MM/dd' is that trap wearing a hat.
    #
    # A STAMP FROM THE FUTURE IS SHOWN AS IT IS. $since is clamped to zero so a
    # WinPE machine whose clock nothing syncs is not branded stale, but the TIME
    # must not be clamped: a heartbeat that claims a moment eight hours from now
    # is the only thing on this screen that makes that skew visible.
    $updatedText = ''
    if ($hasStamp -and $null -ne $updated) {
        $updatedText = $updated.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $step = Get-HDTConsoleDisplayText -Text $stepName -Fallback '(no step yet)'

    $text = '{0} - {1}' -f $RunId, $step
    if (-not [string]::IsNullOrWhiteSpace($sinceText)) {
        $text = '{0} - {1}  ({2} ago)' -f $RunId, $step, $sinceText
    }

    # "STEP 7" IS A NUMBER NOBODY CAN ACT ON; "step 7 of 12" is a progress bar.
    # The count comes from the heartbeat because the console cannot work it out
    # from a share it is only reading - and a heartbeat written by an older
    # engine carries no count at all, so that case says what it knows rather
    # than inventing a total.
    $stepText = [string] $stepIndex
    if ($stepCount -gt 0) { $stepText = '{0} of {1}' -f $stepIndex, $stepCount }

    return [pscustomobject] @{
        RunId       = $RunId
        Phase       = $phase
        RunStatus   = $runStatus
        StepIndex   = $stepIndex
        StepCount   = $stepCount
        StepText    = $stepText
        StepName    = $stepName
        StepType    = $stepType
        Updated     = $updated
        UpdatedText = $updatedText
        SinceSecond = $since
        SinceText   = $sinceText
        Health      = $health
        Icon        = $icon
        Text        = $text
        Path        = $Path
        Command     = $command
    }
}
