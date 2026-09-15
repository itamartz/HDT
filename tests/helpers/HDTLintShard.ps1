# One worker of a sharded ./build.ps1 -Task lint run.
#
# WHY LINT IS SHARDED AND NOT MADE CHEAPER. PSScriptAnalyzer costs a flat ~110ms
# per file on this repository and almost none of it belongs to any one rule -
# over the 115 files in src/Hephaestus/Private the full rule set takes 13.0s and
# the same run with PSUseCompatibleSyntax excluded takes 12.7s. Batching the
# calls does not help either: it saves only the per-invocation setup, about 7
# seconds of 78. Nothing about the analysis is redundant, so the only thing left
# is to do it on more than one core.
#
# BEWARE MEASURING THIS IN ONE PROCESS. PSScriptAnalyzer caches per file within
# a session, so whichever of two approaches runs second looks 40x faster than it
# is. Both numbers above come from separate processes.
#
# IT REPORTS THROUGH A FILE for the same reason HDTTestShard.ps1 does: the
# child's stdout is not a channel anything can parse. No file written means the
# worker died, and the parent treats that as a failure rather than as a clean
# shard.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ListPath,

    [Parameter(Mandatory = $true)]
    [string] $DiagnosticPath,

    [Parameter(Mandatory = $true)]
    [string] $SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name PSScriptAnalyzer -Force -ErrorAction Stop

$path = @(Get-Content -LiteralPath $ListPath | Where-Object { $_ })

# FLATTENED TO STRINGS AND PRIMITIVES. A live DiagnosticRecord does not survive
# Export-Clixml intact, and the parent only ever formats these five fields.
$diagnostic = @($path | ForEach-Object {
        $record = @(Invoke-ScriptAnalyzer -Path $_ -Settings $SettingsPath)

        # COLLECT AFTER EVERY FILE, BECAUSE THE ANALYZER LEAVES A LOT BEHIND.
        # Each Invoke-ScriptAnalyzer parses the file into an AST, walks it with
        # every rule, and drops the lot; without a collection between files a
        # worker climbed to about 250 MB and stayed there, and with one it sits
        # flat at about 178 MB. That is 8 x 72 MB not being asked of a host whose
        # commit limit is its physical RAM - the same pressure that made
        # ./build.ps1 -Task ci die of System.OutOfMemoryException.
        #
        # HERE AND NOT IN THE TEST SHARD. Lint plateaus and the test worker did
        # not: a forced collection reclaimed only 31% of a test worker, which is
        # why that one batches into fresh processes instead of collecting.
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        $record
    } | ForEach-Object {
        [pscustomobject] @{
            Severity   = [string] $_.Severity
            RuleName   = [string] $_.RuleName
            ScriptPath = [string] $_.ScriptPath
            Line       = [int] $_.Line
            Message    = [string] $_.Message
        }
    })

# WRAPPED IN AN OBJECT, because a bare empty array does not survive the round
# trip: Export-Clixml of @() comes back from Import-Clixml as a single $null,
# which then reads as one diagnostic with no Severity. A property on an object
# is an empty array on both sides.
#
# WRITTEN LAST, DELIBERATELY, and always - a clean shard is a real result and
# has to be told apart from a worker that never got here at all.
[pscustomobject] @{ Diagnostic = $diagnostic } | Export-Clixml -LiteralPath $DiagnosticPath
