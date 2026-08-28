function Test-HDTRunStateAbandoned {
    <#
        .SYNOPSIS
            Reports whether a state document describes a run that is over or dead.

        .DESCRIPTION
            The boot reconcile: Start-HDTResume.ps1 reconciles on
            every boot: if the state document says the run is finished, failed,
            or missing, it clears autologon, the LSA secret, the RunOnce entry
            and C:\HDT\state.json before doing anything else." This is the
            question that reconcile asks.

            Abandoned when:

              status is Succeeded or Failed   the run is over
              status is Running but updatedUtc is older than -MaxAgeHour
                                              the run died between legs
              updatedUtc is missing or unreadable
                                              a document whose timestamp cannot
                                              be read is not evidence that a run
                                              is alive

            The stale case is the one that matters. A teardown that is only a
            sequence step leaves autologon armed forever when the run dies before
            reaching it, so HDT's reconcile plus this check is the second of
            three backstops, the others being the finally-block teardown and
            AutoLogonCount.

            The time comes from the injected IClock, never from the wall clock,
            so a thirteen-hour-old deployment is provable in a unit test.

        .PARAMETER State
            An Import-HDTRunState or New-HDTRunState result.

        .PARAMETER Clock
            An IClock supplying "now".

        .PARAMETER MaxAgeHour
            How long a Running document may go without a save before it is taken
            for dead. Defaults to 12.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            $clock = New-HDTClock
            $state = Import-HDTRunState -Path 'C:\HDT\state.json'
            Test-HDTRunStateAbandoned -State $state -Clock $clock

            Whether a checkpoint belongs to a run nobody is coming back for. A machine
            left logging itself in as Administrator is what this exists to catch.

        .EXAMPLE
            if (Test-HDTRunStateAbandoned -State $state -Clock $clock) { 'tear the autologon down' }

            What the boot-time reconcile does with the answer. It runs before anything
            else, because the alternative is a machine that stays armed.

    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $State,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $MaxAgeHour = 12
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $now = $Clock.GetUtcNow()

    if (@('Succeeded', 'Failed') -contains [string] $State.status) {
        return $true
    }

    # Import-HDTRunState normalises this to a round-trip string, but a document
    # parsed elsewhere under pwsh 7 arrives carrying a [datetime], and both name
    # the same instant.
    if ($State.updatedUtc -is [datetime]) {
        return ((($now - ([datetime] $State.updatedUtc).ToUniversalTime()).TotalHours) -gt $MaxAgeHour)
    }

    $updated = [string] $State.updatedUtc
    if ([string]::IsNullOrWhiteSpace($updated)) {
        return $true
    }

    $stamp = [datetime]::MinValue
    $parsed = [datetime]::TryParse(
        $updated,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref] $stamp)

    if (-not $parsed) {
        return $true
    }

    return (($now - $stamp.ToUniversalTime()).TotalHours -gt $MaxAgeHour)
}
