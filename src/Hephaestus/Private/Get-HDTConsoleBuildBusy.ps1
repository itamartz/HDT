function Get-HDTConsoleBuildBusy {
    <#
        .SYNOPSIS
            Whether the build's progress bar should be showing activity rather
            than a position.

        .DESCRIPTION
            A BOOT IMAGE BUILD HAS STEPS THAT REPORT ONCE AND THEN WORK FOR A
            MINUTE. Mounting is one DISM call; committing and exporting is one
            DISM call; injecting a folder of drivers with -Recurse is one DISM
            call. None of them offers a callback, so the bar sat at the same
            pixel for ninety seconds and a technician watching it had no way to
            tell a slow step from a hung one.

            IT IS SILENCE THAT MEANS BUSY, NOT ELAPSED TIME. The obvious rule -
            "this step has been running a while" - is wrong: with the verbose
            driver option on, step 10 runs for seven minutes while reporting
            seventy times, and a bar that went indeterminate there would throw
            away a position it actually has. What says "working, no news" is the
            gap since the LAST REPORT, whichever step it belonged to.

            THE BAR KEEPS ITS MEANING EITHER WAY. Indeterminate is WPF saying
            "something is happening and I cannot say how far"; the step counter
            beside it still reads "step 10 of 17", so the position is never
            actually lost - only the bar stops pretending to measure what it
            cannot.

        .PARAMETER QuietSecond
            How long it has been since the last report.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Get-HDTConsoleBuildBusy -QuietSecond 4.2

            True - nothing has been heard for four seconds, so the bar sweeps.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [double] $QuietSecond
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THREE SECONDS, because the reports that arrive in a burst - nine optional
    # components, seventy drivers - are a second or two apart, and a bar that
    # flickered between sweeping and measuring on every one of them would be
    # worse than either. Below this, the position is the more useful thing.
    return ([double] $QuietSecond -ge 3)
}
