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
    [string] $Verbosity = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$path = @(Get-Content -LiteralPath $ListPath | Where-Object { $_ })

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
