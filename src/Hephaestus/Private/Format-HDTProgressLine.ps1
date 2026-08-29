function Format-HDTProgressLine {
    <#
        .SYNOPSIS
            Renders one line of deployment progress for a machine that cannot
            draw a window.

        .DESCRIPTION
            DESIGN 11.1'S CONSOLE FALLBACK, and the half of it a technician
            actually reads: "If XAML fails to load - a boot image built without
            the right components, an exotic display, a serial console - the
            engine logs the reason and WRITES STYLED CONSOLE LINES INSTEAD, then
            carries on."

            EIGHTY COLUMNS, BECAUSE THAT IS WHAT IT HAS. A WinPE command prompt
            and a serial console are both eighty wide and neither wraps kindly;
            a line that spills leaves a technician reading half of every second
            line, which is worse than a shorter line that does not.

            THE STEP NAME IS THE PART THAT GIVES WAY. Where a deployment is up
            to - the counter, the percentage, the phase, the clock - is fixed
            width and always survives. WHICH step it is on is allowed to be
            abbreviated, because a truncated name still identifies a step to
            somebody watching, and a missing counter does not identify anything.

            THE FIXED WIDTHS ARE WHAT MAKES IT "STYLED". Consecutive lines form
            columns rather than ragged text, so a technician reads down the
            numbers instead of hunting along each line for them. That is the
            whole of what styling can mean where there is no window.

            IT SHOUTS ONLY WHEN SOMETHING HAPPENED. A line that says RUNNING on
            every step is a line nobody is reading by the fourth one, and then
            FAILED goes past unnoticed.

            ELAPSED IS A CLOCK, NOT A COUNT OF SECONDS. Nobody divides by sixty
            at a bench.

            AND IT IS A CLOCK IN THE OTHER SENSE TOO: HOW LONG THE STEP HAS BEEN
            RUNNING, worked out here from the step's start time and the time
            passed in. Get-HDTDeploymentProgress used to hand over an
            ElapsedSecond it had summed from the records' own timestamps, which
            advanced only when something wrote a record - so on a step that went
            quiet the number was frozen by construction (measured on
            LT-D5M1NN3, run-20260829-223623). The time now comes from a clock,
            and this stays pure by being told what the clock says.

        .PARAMETER Progress
            What Get-HDTDeploymentProgress returned.

        .PARAMETER Now
            The current time, in UTC, for the subtraction against
            Progress.StepStartTime.

            INJECTED SO THIS STAYS DETERMINISTIC - every assertion about the
            clock in the tests would otherwise depend on when the suite ran. It
            DEFAULTS rather than being mandatory on purpose: a caller that
            forgot would otherwise either prompt (and a mandatory-parameter
            prompt on a WinPE console is a deployment that stops for a keystroke
            nobody is there to press) or silently print 00:00:00 forever, which
            is the very defect this replaced.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one line, at most eighty characters.

        .EXAMPLE
            Format-HDTProgressLine -Progress (Get-HDTDeploymentProgress -Record $record)

            [ 3/8  25%] WinPE  Apply Windows 11 Enterprise LTSC  37%  00:01:24
    #>
    # $Progress IS used - inside the $valueOf closure below, which the analyzer
    # does not follow. Removing it to satisfy the rule would remove the input.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Progress,

        [Parameter(Position = 1)]
        [datetime] $Now = ([datetime]::UtcNow)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $valueOf = {
        param([string] $Name, [object] $Default)

        if ($null -eq $Progress.PSObject.Properties[$Name]) { return $Default }
        if ($null -eq $Progress.$Name) { return $Default }

        return $Progress.$Name
    }

    $stepNumber = [int] (& $valueOf 'StepNumber' 0)
    $stepCount = [int] (& $valueOf 'StepCount' 0)
    $percent = [int] (& $valueOf 'PercentComplete' 0)
    $phase = [string] (& $valueOf 'Phase' '')
    $stepName = [string] (& $valueOf 'StepName' '')
    $status = [string] (& $valueOf 'Status' '')
    $stepPercent = [int] (& $valueOf 'StepPercent' 0)

    # HOW LONG THE STEP HAS BEEN GOING, AGAINST THE CLOCK RATHER THAN AGAINST
    # THE RECORDS. $null is a run that has not reached its first step, and it
    # prints 00:00:00 rather than nothing: the columns are the whole of the
    # styling this fallback has, and a clock that came and went would move every
    # other one sideways.
    #
    # NEGATIVE IS CLAMPED, NOT RENDERED. WinPE's clock corrects itself mid-run
    # (DESIGN 4.4.2), and a correction landing between the step's start and this
    # subtraction is a real shape - [timespan] on a negative would print through
    # the format string below as a huge hour count on a wall.
    $span = [timespan]::Zero
    $stepStart = & $valueOf 'StepStartTime' $null

    if ($null -ne $stepStart) {
        $span = $Now - ([datetime] $stepStart)
        if ($span.Ticks -lt 0) { $span = [timespan]::Zero }
    }

    # A COUNT NOBODY STATED IS NOT PRINTED AS ZERO. '3/0' is a wrong fact where
    # '3' is an incomplete one.
    $counter = '{0,2}' -f $stepNumber
    if ($stepCount -gt 0) { $counter = '{0,2}/{1,-2}' -f $stepNumber, $stepCount }

    $header = '[{0} {1,3}%]' -f $counter.PadRight(5), $percent

    $clock = '{0:00}:{1:00}:{2:00}' -f [int] $span.TotalHours, $span.Minutes, $span.Seconds

    # ONLY WHEN SOMETHING HAPPENED - see the header.
    $flag = ''
    if ($status -eq 'Failed') { $flag = ' FAILED' }
    if ($status -eq 'Succeeded') { $flag = ' DONE' }

    $phaseText = ''
    if (-not [string]::IsNullOrWhiteSpace($phase)) { $phaseText = ' {0,-6}' -f $phase }

    # THE STEP'S OWN PERCENTAGE, AND THE COLUMN IS RESERVED EVEN WHEN NOTHING
    # REPORTED ONE. Five characters, blank for a step that says nothing about
    # itself: a column that appeared and disappeared would shift the clock
    # sideways mid-deployment, and consecutive lines forming columns is the
    # whole of the styling this fallback has.
    $stepText = '     '
    if ($stepPercent -gt 0) { $stepText = ' {0,3}%' -f $stepPercent }

    # WHAT IS LEFT AFTER THE PARTS THAT MAY NOT SHRINK. Two spaces before the
    # clock keep the columns apart when a name runs the full width.
    $fixed = $header.Length + $phaseText.Length + $stepText.Length + $flag.Length + $clock.Length + 3
    $room = 80 - $fixed

    if ($room -lt 0) { $room = 0 }

    $name = $stepName
    if ($name.Length -gt $room) { $name = $name.Substring(0, $room) }

    return ('{0}{1} {2}{3}  {4}{5}' -f $header, $phaseText, $name.PadRight($room), $stepText, $clock, $flag).TrimEnd()
}
