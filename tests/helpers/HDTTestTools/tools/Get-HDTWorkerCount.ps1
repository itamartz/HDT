function Get-HDTWorkerCount {
    <#
        .SYNOPSIS
            Resolves how many child processes the test task should start.

        .DESCRIPTION
            0 means decide: one worker per core less two, so the machine stays
            usable while the suite runs, capped at eight.

            EIGHT IS MEASURED, NOT GUESSED. On this repository 4 workers took
            229s against 500s serial and 8 took 197s - the second four bought 32
            seconds. A sharded run cannot finish before its longest single test
            file, so past the point where the buckets are already shorter than
            that file, more workers only add process startup.

            A NUMBER THE CALLER GAVE IS OBEYED, up to the same cap, because
            -Worker 1 is the documented way to get output in a readable order
            when something has failed, and auto-sizing over the top of it would
            take that away.

            IT NEVER RETURNS ZERO. A container reporting one core, or a runner
            reporting two, must still produce a worker: sharding a suite into no
            processes is the empty-dispatch defect build.ps1's header warns
            about, dressed up as a performance feature.

        .PARAMETER Requested
            What -Worker asked for. 0 to decide automatically.

        .PARAMETER ProcessorCount
            Cores to size against. Defaults to this machine's.

        .EXAMPLE
            Invoke-HDTTest -Worker (Get-HDTWorkerCount -Requested $Worker)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()]
        [ValidateRange(0, 128)]
        [int] $Requested = 0,

        [Parameter()]
        [ValidateRange(1, 1024)]
        [int] $ProcessorCount = [Environment]::ProcessorCount
    )

    $ceiling = 8

    if ($Requested -gt 0) {
        return [Math]::Min($Requested, $ceiling)
    }

    $spare = $ProcessorCount - 2

    return [Math]::Max(1, [Math]::Min($spare, $ceiling))
}
