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

        .PARAMETER Progress
            What Get-HDTDeploymentProgress returned.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one line, at most eighty characters.

        .EXAMPLE
            Format-HDTProgressLine -Progress (Get-HDTDeploymentProgress -Record $record)

            [ 3/8  25%] WinPE  Apply Windows 11 Enterprise LTSC 202  00:01:24
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
        [object] $Progress
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
    $elapsed = [int] (& $valueOf 'ElapsedSecond' 0)

    # A COUNT NOBODY STATED IS NOT PRINTED AS ZERO. '3/0' is a wrong fact where
    # '3' is an incomplete one.
    $counter = '{0,2}' -f $stepNumber
    if ($stepCount -gt 0) { $counter = '{0,2}/{1,-2}' -f $stepNumber, $stepCount }

    $header = '[{0} {1,3}%]' -f $counter.PadRight(5), $percent

    $span = [timespan]::FromSeconds($elapsed)
    $clock = '{0:00}:{1:00}:{2:00}' -f [int] $span.TotalHours, $span.Minutes, $span.Seconds

    # ONLY WHEN SOMETHING HAPPENED - see the header.
    $flag = ''
    if ($status -eq 'Failed') { $flag = ' FAILED' }
    if ($status -eq 'Succeeded') { $flag = ' DONE' }

    $phaseText = ''
    if (-not [string]::IsNullOrWhiteSpace($phase)) { $phaseText = ' {0,-6}' -f $phase }

    # WHAT IS LEFT AFTER THE PARTS THAT MAY NOT SHRINK. Two spaces before the
    # clock keep the columns apart when a name runs the full width.
    $fixed = $header.Length + $phaseText.Length + $flag.Length + $clock.Length + 3
    $room = 80 - $fixed

    if ($room -lt 0) { $room = 0 }

    $name = $stepName
    if ($name.Length -gt $room) { $name = $name.Substring(0, $room) }

    return ('{0}{1} {2}  {3}{4}' -f $header, $phaseText, $name.PadRight($room), $clock, $flag).TrimEnd()
}
