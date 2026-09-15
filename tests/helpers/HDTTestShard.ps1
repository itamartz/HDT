# One worker of a sharded ./build.ps1 -Task test run.
#
# IT IS A FILE AND NOT AN INLINE -Command STRING because the alternative is
# building PowerShell source by string concatenation in build.ps1 and escaping
# it twice - once for the parent parser and once for the child. Invoke-HDTSelfCheck
# does that for its one-line exit-code probe and it is already at the limit of
# what is readable; a whole Pester configuration would not survive it.
#
# IT REPORTS THROUGH FILES, NOT STDOUT. The suite writes to the information and
# warning streams as it runs - real warnings, from real code under test - so the
# child's stdout is not a channel anything can parse. The two artefacts it
# writes are:
#
#   -SummaryPath   the counts and the names of any container that failed to run
#   -DurationPath  per-file seconds, which the NEXT run reads to balance itself
#
# NO SUMMARY FILE MEANS THE WORKER DIED, and Merge-HDTPesterSummary treats that
# as a failure rather than as zero tests. That is the point of writing it last.
#
# IT RUNS ITS LIST IN BATCHES, EACH IN A PROCESS OF ITS OWN, and that is what
# -BatchSize selects. See "THE MEMORY DOES NOT COME BACK" below.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ListPath,

    [Parameter(Mandatory = $true)]
    [string] $SummaryPath,

    [Parameter(Mandatory = $true)]
    [string] $DurationPath,

    [Parameter(Mandatory = $true)]
    [string] $ResultPath,

    [Parameter()]
    [string] $Verbosity = 'None',

    # HOW MANY TEST FILES ONE PROCESS RUNS BEFORE A FRESH ONE TAKES OVER.
    # 0 means "run the whole list here", which is what a batch process is
    # started with and is therefore what stops the recursion.
    #
    # FIVE, AND THE NUMBER IS MEASURED RATHER THAN CHOSEN. Peak private bytes
    # of one real 68-file shard - 541 files across the default 8 workers - at
    # four batch sizes, whole process tree, same file list every time:
    #
    #     unbatched   876 MB   228s
    #     20          878 MB   234s     <- no change at all
    #     8           724 MB   287s
    #     5           570 MB   368s
    #
    # TWENTY BOUGHT NOTHING because the retention is additive and twenty files
    # is most of what one shard holds anyway. Five is where it stops improving,
    # and that is a floor rather than a coincidence: a worker costs 255 MB
    # before it has run a single test - 61 MB of powershell.exe, 59 MB more for
    # Pester, 135 MB more for the engine - and the heaviest single test file in
    # the sample adds about 200 MB on its own. The worst batch of five measured
    # 463 MB, which is those two numbers and almost nothing else, so batching
    # below five buys process starts and no memory.
    #
    # THE TIME IS THE PRICE AND IT IS PAID ON PURPOSE. Each batch is a fresh
    # process that imports Pester and the engine again, about 10 seconds, so 14
    # batches cost the shard 140 seconds. The suite runs its workers in
    # parallel, so the build pays that once rather than eight times - and a
    # build that takes two minutes longer is worth a great deal more than one
    # that dies of System.OutOfMemoryException at an unpredictable point.
    [Parameter()]
    [ValidateRange(0, 100000)]
    [int] $BatchSize = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$path = @(Get-Content -LiteralPath $ListPath | Where-Object { $_ })

# ---------------------------------------------------------------------------
# THE MEMORY DOES NOT COME BACK.
#
# A worker retained about 10 MB per test file, linearly and with no plateau:
# 282 MB after 10 files, 349 MB after 25, 739 MB after 50, 921 MB after 75. Over
# the real suite one worker of eight - 68 of 541 files - peaked at 876 MB, so
# the eight together cost about 7 GB at the same moment. The worker count does
# not change that: the cost is per test FILE, so 8 x 68 costs what 4 x 135 does.
#
# THIS HOST HAS NO PAGE FILE, so the commit limit is physical RAM and idle
# commit already sits near 52 GB of 63.7 GB. `./build.ps1 -Task ci` therefore
# died with System.OutOfMemoryException - and, under pressure, with a WPF
# DWriteFactory AccessViolation that took a whole shard with it - while
# Task Manager still showed physical RAM free.
#
# A FORCED COLLECTION IS NOT ENOUGH. [GC]::Collect() plus
# WaitForPendingFinalizers at 75 files took 921 MB down to 636 MB and no
# further: only 31% of it was garbage at all. The rest is held by Pester's
# result tree, the compiled scriptblocks of every file discovered, and the
# module state each of them imported. A process that EXITS gives all of it
# back, and nothing short of that does.
#
# SO THE WORKER BECAME A SUPERVISOR. It splits its list into contiguous batches
# of -BatchSize files, runs each in a fresh process of the same host, and adds
# the batch summaries up into the one summary the parent already reads. Peak is
# then set by the batch size rather than by how many files the shard was given,
# which is the whole point: it no longer scales.
#
# CONTIGUOUS, NOT INTERLEAVED. Split-HDTTestBucket has already packed this
# shard's list longest-first; re-ordering it here would undo that, and slicing
# it in order keeps "every file exactly once" true by construction.
#
# A BATCH THAT DOES NOT REPORT KILLS THE SHARD, and deliberately leaves no
# shard summary behind. The contract the parent relies on is that a missing
# summary means the worker died - so a supervisor that wrote a summary holding
# only the batches that survived would be a green build over a suite that
# partly did not run, which is the exact failure Merge-HDTPesterSummary exists
# to refuse. It throws instead, and the throw reaches err-N.log, which
# Get-HDTShardFailureReason reads and Merge-HDTPesterSummary prints.
# ---------------------------------------------------------------------------
if ($BatchSize -gt 0 -and $path.Count -gt $BatchSize) {

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # NOT Pester AND NOT THE ENGINE. The supervisor runs no test, and every
    # module it imports is memory it holds for the whole run alongside the
    # batch that is doing the work. HDTTestTools is a handful of functions and
    # buys the failure sentence the parent already knows how to read.

    $batch = @()
    for ($start = 0; $start -lt $path.Count; $start += $BatchSize) {
        $end = [Math]::Min($start + $BatchSize, $path.Count) - 1
        $batch += , @($path[$start..$end])
    }

    # BESIDE THE ARTEFACTS THEY BELONG TO. The batch lists, logs and summaries
    # go in the shard directory the parent made and clears; the NUnit documents
    # go beside the shard's own -ResultPath, because both CI workflows collect
    # out/testResults/*.xml as a glob and a batch document has to be in it.
    $workDirectory = Split-Path -Parent $SummaryPath
    $workStem = [IO.Path]::GetFileNameWithoutExtension($SummaryPath)
    $resultDirectory = Split-Path -Parent $ResultPath
    $resultStem = [IO.Path]::GetFileNameWithoutExtension($ResultPath)

    foreach ($directory in @($workDirectory, $resultDirectory)) {
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -Path $directory -ItemType Directory -Force
        }
    }

    $hostPath = (Get-Process -Id $PID).Path

    $passed = 0
    $failed = 0
    $skipped = 0
    $failedContainer = 0
    $detail = @()
    $duration = @()

    for ($index = 0; $index -lt $batch.Count; $index++) {
        $ordinal = '{0}of{1}' -f ($index + 1), $batch.Count
        $file = @($batch[$index])

        # [IO.Path]::Combine AND NOT Join-Path, for the reason the workspace
        # helpers give: Join-Path resolves the drive and throws DriveNotFound
        # on a path whose root is not mounted, which makes the line untestable.
        $batchList = [IO.Path]::Combine($workDirectory, ('{0}-batch{1}.txt' -f $workStem, $ordinal))
        $batchSummary = [IO.Path]::Combine($workDirectory, ('{0}-batch{1}.clixml' -f $workStem, $ordinal))
        $batchDuration = [IO.Path]::Combine($workDirectory, ('{0}-batch{1}.csv' -f $workStem, $ordinal))
        $batchError = [IO.Path]::Combine($workDirectory, ('{0}-batch{1}.err.log' -f $workStem, $ordinal))
        $batchOutput = [IO.Path]::Combine($workDirectory, ('{0}-batch{1}.out.log' -f $workStem, $ordinal))
        $batchResult = [IO.Path]::Combine($resultDirectory, ('{0}-batch{1}.xml' -f $resultStem, $ordinal))

        # A SUMMARY LEFT BY A PREVIOUS RUN WOULD BE READ AS THIS ONE'S. The
        # parent clears the shard directory before it starts, but a run with
        # fewer batches than the last leaves the tail behind, and this loop
        # reads by name. Removed by literal path to a file this script names.
        if (Test-Path -LiteralPath $batchSummary -PathType Leaf) {
            Remove-Item -LiteralPath $batchSummary -Force
        }

        Set-Content -LiteralPath $batchList -Value $file -Encoding UTF8

        $argument = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $PSCommandPath,
            '-ListPath', $batchList,
            '-SummaryPath', $batchSummary,
            '-DurationPath', $batchDuration,
            '-ResultPath', $batchResult,
            '-Verbosity', $Verbosity,
            '-BatchSize', '0'
        )

        Write-Information ("shard: batch {0}, {1} file(s) -> {2}" -f $ordinal, $file.Count, $batchResult) -InformationAction Continue

        $process = Start-Process -FilePath $hostPath -ArgumentList $argument -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput $batchOutput -RedirectStandardError $batchError

        # -PassThru RETURNING NOTHING IS ITS OWN DEFECT, for the reason
        # Invoke-HDTShardedTest gives: stored unchecked it becomes a null
        # reference several lines later, naming neither the batch nor the cause.
        if ($null -eq $process) {
            throw ("batch {0} of {1} could not be started ({2}), so its {3} file(s) listed in '{4}' did not run." -f
                ($index + 1), $batch.Count, $hostPath, $file.Count, $batchList)
        }

        $exitCode = $null
        try {
            $exitCode = $process.ExitCode
        } catch {
            $exitCode = $null
        }

        $result = $null
        $unreadable = ''

        if (Test-Path -LiteralPath $batchSummary -PathType Leaf) {
            # TEST-PATH IS NOT READABILITY: a batch killed part way through
            # Export-Clixml leaves a truncated document, and an unguarded import
            # throws raw XML where the sentence belongs.
            try {
                $result = Import-Clixml -LiteralPath $batchSummary
            } catch {
                $result = $null
                $unreadable = " Its summary '{0}' exists but could not be read ({1})." -f $batchSummary, $_.Exception.Message
            }
        }

        if ($null -eq $result) {
            throw ("batch {0} of {1} did not report a result, so {2} of this worker's {3} file(s) did not run - they are listed in '{4}'.{5} {6}" -f
                ($index + 1), $batch.Count, $file.Count, $path.Count, $batchList, $unreadable,
                (Get-HDTShardFailureReason -ErrorPath $batchError -ExitCode $exitCode))
        }

        $passed += [int] $result.PassedCount
        $failed += [int] $result.FailedCount
        $skipped += [int] $result.SkippedCount
        $failedContainer += [int] $result.FailedContainersCount

        foreach ($item in @($result.ContainerDetail)) {
            if ($item) {
                $detail += [string] $item
            }
        }

        if (Test-Path -LiteralPath $batchDuration -PathType Leaf) {
            $duration += @(Import-Csv -LiteralPath $batchDuration)
        }
    }

    $duration | Export-Csv -LiteralPath $DurationPath -NoTypeInformation -Encoding UTF8

    # LAST, DELIBERATELY - the same contract the single-batch path keeps.
    [pscustomobject] @{
        PassedCount           = $passed
        FailedCount           = $failed
        SkippedCount          = $skipped
        FailedContainersCount = $failedContainer
        ContainerDetail       = $detail
    } | Export-Clixml -LiteralPath $SummaryPath

    return
}

Import-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

# IMPORT THE ENGINE ONCE, HERE, AND SURVIVE LOSING THE RACE TO DO IT.
#
# Hephaestus.psm1 rebuilds Hephaestus.bundle.ps1 whenever a source is newer than
# it, and all 301 test files import the engine. Eight workers starting at once
# therefore all find the same stale bundle and all try to write it: seven lose
# with "the process cannot access the file ... because it is being used by
# another process", and because that happens inside a BeforeAll it fails every
# test in the file rather than one.
#
# ONE WINNER IS ENOUGH. Whoever writes it makes the bundle newer than the
# sources, so a worker that waits and retries finds nothing left to rebuild and
# the per-test imports after this one are all no-ops. Retrying is the whole fix;
# the sleep only stops eight processes retrying in lockstep.
#
# THE LAST FAILURE IS RETHROWN. A worker that genuinely cannot load the engine
# must die here and be reported as a dead shard, not run 40 test files that all
# fail for a reason nobody will read twice.
#
# TWO Split-Path, NOT ONE. This file lives in tests\helpers, so the repository
# root is two levels up - one level gives tests\, and the manifest then resolves
# to tests\src\Hephaestus\Hephaestus.psd1, which has never existed. That was one
# character of difference and it killed all eight workers of every sharded run.
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$engineManifest = Join-Path -Path $repositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'

# A MANIFEST THAT IS NOT THERE IS NOT A RACE. The retry below exists for one
# thing only - losing the race to rebuild Hephaestus.bundle.ps1 - and a path
# that does not exist cannot win it on the tenth attempt. Retrying it burns 4.5s
# of sleeps in every worker and then reports a lock contention that never
# happened, so the missing file is named here instead.
if (-not (Test-Path -LiteralPath $engineManifest -PathType Leaf)) {
    throw ("The engine manifest '{0}' does not exist, so this worker can run no test. Its repository root was resolved as '{1}' from '{2}'." -f
        $engineManifest, $repositoryRoot, $PSScriptRoot)
}

for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        Import-Module -Name $engineManifest -Force -ErrorAction Stop
        break
    } catch {
        if ($attempt -eq 10) {
            throw
        }
        Start-Sleep -Milliseconds (100 * $attempt)
    }
}

# A TestRegistry ONLY IF THIS WORKER'S OWN FILES USE ONE. Pester creates a GUID
# key under a single HKCU:\Software\Pester for every container, so eight workers
# doing that at once race and some third worker's file dies enumerating it -
# "Test-Path : No more data is available", reported as "Framework failed" against
# a file that never touched the registry.
#
# READ FROM THE FILES THEMSELVES, not from a list kept somewhere else: a list is
# a thing to forget to update the day a test starts using TestRegistry:.
$needsRegistry = $false
foreach ($candidate in $path) {
    if ((Get-Content -LiteralPath $candidate -Raw -ErrorAction SilentlyContinue) -match 'TestRegistry') {
        $needsRegistry = $true
        break
    }
}

$configuration = New-HDTPesterConfiguration -Path $path -ResultPath $ResultPath `
    -Verbosity $Verbosity -TestRegistry:$needsRegistry

# THE FAILURE STAYS THE FAILURE. If Invoke-Pester throws - a malformed list file
# gives "Illegal characters in path" out of its own Find-File - then $result is
# never assigned, and Set-StrictMode -Version Latest turns the $result.Containers
# below into a SECOND error, "The property 'Containers' cannot be found on this
# object", which is the one that ends up at the tail of err-N.log and buries the
# real one. Catching here keeps the cause first and names the list it was given.
$result = $null
try {
    $result = Invoke-Pester -Configuration $configuration
} catch {
    throw ("Invoke-Pester could not run this worker's {0} file(s) listed in '{1}': {2}" -f
        $path.Count, $ListPath, $_.Exception.Message)
}

if ($null -eq $result) {
    throw ("Invoke-Pester returned nothing for this worker's {0} file(s) listed in '{1}'." -f $path.Count, $ListPath)
}

# THE SAME DETAIL Assert-HDTPesterResult WOULD HAVE NAMED. Flattened to strings
# here because the parent reads this back out of CLIXML and a live Pester
# container object does not survive the round trip.
$detail = @($result.Containers |
        Where-Object { @($_.ErrorRecord).Count -gt 0 } |
        ForEach-Object {
            '{0}: {1}' -f $_.Item, (@($_.ErrorRecord | ForEach-Object { [string] $_ }) -join '; ')
        })

# PER-FILE SECONDS FOR THE NEXT RUN TO PACK WITH. Keyed by the full path, which
# is what Split-HDTTestBucket is handed. A file that vanishes before the next
# run just goes unread.
$duration = @($result.Containers | ForEach-Object {
        [pscustomobject] @{
            Path    = [string] $_.Item
            Seconds = [double] $_.Duration.TotalSeconds
        }
    })

$duration | Export-Csv -LiteralPath $DurationPath -NoTypeInformation -Encoding UTF8

# LAST, DELIBERATELY. Its absence is how the parent detects a worker that died.
[pscustomobject] @{
    PassedCount           = [int] $result.PassedCount
    FailedCount           = [int] $result.FailedCount
    SkippedCount          = [int] $result.SkippedCount
    FailedContainersCount = [int] $result.FailedContainersCount
    ContainerDetail       = $detail
} | Export-Clixml -LiteralPath $SummaryPath
