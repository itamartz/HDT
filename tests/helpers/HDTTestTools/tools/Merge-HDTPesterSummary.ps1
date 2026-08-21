function Merge-HDTPesterSummary {
    <#
        .SYNOPSIS
            Folds the worker processes' summaries into one Pester-shaped result.

        .DESCRIPTION
            A sharded test run produces one summary per child process. Both
            Write-HDTBuildBadge and Assert-HDTPesterResult already know how to
            read a Pester result, and Assert-HDTPesterResult in particular
            encodes a judgement that cost a phase to learn - that
            FailedContainersCount is a failure even when FailedCount is zero,
            because a file that never got discovered is not a file that passed.
            So this returns that same shape rather than a new one, and sharding
            stays a change to how the suite runs and not to how it is judged.

            THE COUNTS ADD; THE VERDICT DOES NOT. Eight green shards and one red
            shard is a red run, and only the red one's detail is worth carrying.

            A SILENT WORKER IS A FAILURE, NOT A ZERO. If a child process dies -
            killed, crashed host, out of memory - it writes no summary, and the
            caller passes $null in its place. Adding that in as "0 passed, 0
            failed" would produce a green build over a third of a suite that
            never ran. It throws instead.

            AND IT NAMES ALL OF THEM, WITH THE REASON. Reporting only the first
            dead worker cost an investigation: all eight were dying on the same
            Import-Module, the build said "worker 1 of 8", and one-of-eight reads
            as a flaky shard - a race - while eight-of-eight is a broken runner.
            This is the only place that knows which it was. The stderr the caller
            gathered goes in the same sentence, because a build that prints the
            symptom while the cause sits in a log file is a build that gets run
            again rather than read.

        .PARAMETER Summary
            One object per worker, each with PassedCount, FailedCount,
            SkippedCount, FailedContainersCount and ContainerDetail.

        .PARAMETER Reason
            Optional, one string per worker, positionally aligned with Summary:
            why that worker did not report, as Get-HDTShardFailureReason phrases
            it. Only the entries beside a $null summary are ever read.

        .OUTPUTS
            An object with the properties Write-HDTBuildBadge and
            Assert-HDTPesterResult read.

        .EXAMPLE
            $result = Merge-HDTPesterSummary -Summary $shardSummary
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Summary,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Reason
    )

    # @($x) DOES NOT MAKE AN ARRAY OF A NULL [string[]]. On Windows PowerShell
    # 5.1 the array subexpression of a null typed parameter collapses back to
    # $null, and Set-StrictMode -Version Latest then turns the .Count below into
    # "The property 'Count' cannot be found on this object" - the helper that
    # exists to explain a dead worker failing with its own error instead.
    $shard = @()
    if ($null -ne $Summary) {
        $shard = @($Summary)
    }

    $why = @()
    if ($null -ne $Reason) {
        $why = @($Reason)
    }

    if ($shard.Count -eq 0) {
        throw 'Merge-HDTPesterSummary was given no worker result to merge. A run whose workers reported nothing is not a run that passed.'
    }

    # EVERY DEAD WORKER, COUNTED BEFORE ANYTHING IS ADDED UP. The counts of the
    # survivors are worthless if a shard is missing, and how MANY are missing is
    # the difference between a flake and a broken runner.
    $dead = @()
    for ($i = 0; $i -lt $shard.Count; $i++) {
        if ($null -eq $shard[$i]) {
            $dead += $i
        }
    }

    if ($dead.Count -gt 0) {
        $ordinal = @($dead | ForEach-Object { $_ + 1 }) -join ', '

        $noun = 'worker {0} of {1} did not report a result. Its process died before writing one'
        if ($dead.Count -gt 1) {
            $noun = 'workers {0} of {1} did not report a result. Their processes died before writing one'
        }

        $message = ($noun -f $ordinal, $shard.Count) +
        ', so part of the suite did not run and the build cannot be called green.'

        foreach ($index in $dead) {
            if ($index -lt $why.Count -and $why[$index]) {
                $message += '{0}worker {1}: {2}' -f [Environment]::NewLine, ($index + 1), $why[$index]
            }
        }

        throw $message
    }

    $passed = 0
    $failed = 0
    $skipped = 0
    $failedContainer = 0
    $container = @()

    for ($i = 0; $i -lt $shard.Count; $i++) {
        $item = $shard[$i]

        $passed += [int] $item.PassedCount
        $failed += [int] $item.FailedCount
        $skipped += [int] $item.SkippedCount
        $failedContainer += [int] $item.FailedContainersCount

        # Shaped as Pester shapes it, because Assert-HDTPesterResult reads
        # .Item and .ErrorRecord off each one to name the file that broke.
        foreach ($detail in @($item.ContainerDetail)) {
            if ($detail) {
                $container += [pscustomobject] @{
                    Item        = $detail
                    ErrorRecord = @($detail)
                }
            }
        }
    }

    $outcome = 'Passed'
    if ($failed -gt 0 -or $failedContainer -gt 0) {
        $outcome = 'Failed'
    }

    # CodeCoverage IS DELIBERATELY NULL. Pester's coverage is per-process and
    # JaCoCo documents do not merge by concatenation, so a sharded run measures
    # none - and Write-HDTBuildBadge treats null as "leave the coverage badge
    # alone", which keeps the real number the nightly measured on the front
    # page instead of overwriting it with a zero. ./build.ps1 -Task test
    # -Coverage runs on one worker for exactly this reason.
    return [pscustomobject] @{
        PassedCount           = $passed
        FailedCount           = $failed
        SkippedCount          = $skipped
        FailedContainersCount = $failedContainer
        TotalCount            = $passed + $failed + $skipped
        Containers            = @($container)
        CodeCoverage          = $null
        Result                = $outcome
    }
}
