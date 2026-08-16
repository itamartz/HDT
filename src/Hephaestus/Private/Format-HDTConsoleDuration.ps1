function Format-HDTConsoleDuration {
    <#
        .SYNOPSIS
            A number of seconds, written the way somebody reads it off a screen.

        .DESCRIPTION
            "1m 30s", not "90", and not "00:01:30". A technician watching a wall
            of deployments is answering one question - has this one been sitting
            there too long - and the two largest units are what answers it. The
            third would be noise: nobody cares about the seconds on something
            that has been running two hours.

            IT ROUNDS DOWN, deliberately. A step that has been going 119 seconds
            is "1m 59s" rather than "2m", because this number is read as an
            argument for whether to intervene and rounding it up makes the case
            for intervening early.

            SECONDS ALONE UNDER A MINUTE, so a heartbeat that just landed reads
            "12s" rather than "0m 12s".

        .PARAMETER Second
            How many seconds. Negative is treated as none - a heartbeat stamped
            in the future is a clock disagreement, not a negative age.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Format-HDTConsoleDuration -Second 90

            1m 30s
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [double] $Second
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $total = [int] [System.Math]::Floor($Second)

    # A machine whose clock is ahead of the console's writes a heartbeat stamped
    # in the future. That is a fact about the clocks, not about the deployment,
    # and reading it as "-4m" would send somebody looking for the wrong problem.
    if ($total -lt 0) { $total = 0 }

    if ($total -lt 60) {
        return '{0}s' -f $total
    }

    $minute = [int] [System.Math]::Floor($total / 60)

    if ($minute -lt 60) {
        return '{0}m {1}s' -f $minute, ($total % 60)
    }

    $hour = [int] [System.Math]::Floor($minute / 60)

    if ($hour -lt 24) {
        return '{0}h {1}m' -f $hour, ($minute % 60)
    }

    return '{0}d {1}h' -f [int] [System.Math]::Floor($hour / 24), ($hour % 24)
}
