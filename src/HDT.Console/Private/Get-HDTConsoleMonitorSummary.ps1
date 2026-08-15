function Get-HDTConsoleMonitorSummary {
    <#
        .SYNOPSIS
            The one line somebody scans before reading any of the rows.

        .DESCRIPTION
            AN EMPTY LIST LOOKS LIKE A BROKEN SCREEN. A monitoring view with no
            rows and no caption is indistinguishable from one that failed to
            read the share, and the difference matters at exactly the moment
            somebody is looking - so it says, in words, that nothing is running.

            IT LEADS WITH WHAT IS WRONG. Stalled and unreadable come before the
            count of healthy ones, because they are the reason to keep looking;
            a line that opened with "12 running" would bury the one that stopped.

            IT COUNTS FINISHED SEPARATELY AND LAST. A finished run in
            Logs\_active\ is a run whose file has not been swept yet, which is
            housekeeping rather than news.

        .PARAMETER Live
            Runs that have written a heartbeat recently.

        .PARAMETER Stalled
            Runs whose heartbeat stopped.

        .PARAMETER Finished
            Runs the engine marked done.

        .PARAMETER Unreadable
            Heartbeats that could not be parsed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleMonitorSummary -Live 3 -Stalled 1 -Finished 0 -Unreadable 0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [int] $Live,
        [Parameter(Mandatory = $true)] [int] $Stalled,
        [Parameter(Mandatory = $true)] [int] $Finished,
        [Parameter(Mandatory = $true)] [int] $Unreadable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (($Live + $Stalled + $Finished + $Unreadable) -eq 0) {
        return 'There is no deployment running on this share.'
    }

    $part = New-Object -TypeName System.Collections.ArrayList

    if ($Stalled -gt 0) { [void] $part.Add(('{0} stalled' -f $Stalled)) }
    if ($Unreadable -gt 0) { [void] $part.Add(('{0} unreadable' -f $Unreadable)) }
    if ($Live -gt 0) { [void] $part.Add(('{0} running' -f $Live)) }
    if ($Finished -gt 0) { [void] $part.Add(('{0} finished' -f $Finished)) }

    return ($part -join ', ')
}
