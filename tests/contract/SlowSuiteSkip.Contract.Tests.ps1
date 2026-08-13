# SPIKES S9.15, as a contract, over every slow suite in the repository.
#
# "Without StrictMode it evaluated to $null, and 'if (-not $null)' is TRUE - so
# the expensive body ran on a machine that was supposed to be skipping it. A
# guard that means the opposite of what it says when its input is missing is
# worse than no guard."
#
# Pester's discovery and run phases do not share a scope. A $script: variable
# assigned in BeforeDiscovery belongs to discovery, where -Skip: on a Describe
# reads it; a BeforeAll that reads the same variable is reaching across a
# boundary that is not there. Under ./build.ps1, which sets
# Set-StrictMode -Version Latest, that throws inside BeforeAll and takes the
# whole container - every test in the file - down with it. THAT IS WHY THIS RUNS
# IN THE NORMAL SUITE and not only when the slow suites are run: the files it
# judges are the ones nobody runs on an ordinary day.
#
# 04-VERIFICATION asked for this guard and it was never written; phase 05 then
# adds three more slow files with skip conditions. It exists now, before them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:slowSuiteFile = @(
        foreach ($suite in @('tests/integration', 'tests/e2e')) {
            $path = Join-Path -Path $script:repoRoot -ChildPath $suite
            if (Test-Path -LiteralPath $path -PathType Container) {
                Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse |
                    ForEach-Object { $_.FullName }
            }
        }
    )
}

Describe 'no slow suite reads a BeforeDiscovery variable from BeforeAll' {

    It 'finds the slow suites to judge' {
        # A contract that scans nothing passes for the wrong reason
        # (tests/helpers/README.md section 12).
        @($script:slowSuiteFile).Count | Should -BeGreaterThan 0
    }

    It 'reports no violation across tests/integration and tests/e2e' {
        $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:slowSuiteFile)

        $detail = ($violation | ForEach-Object { '{0}({1}): ${2}' -f $_.Path, $_.Line, $_.Variable }) -join "`n"

        $violation.Count | Should -Be 0 -Because (
            "SPIKES S9.15: Pester's discovery and run phases do not share a scope. " +
            "Without StrictMode the read evaluated to `$null, 'if (-not `$null)' is TRUE, " +
            "and the expensive body ran on a machine that was supposed to be skipping it. " +
            "Recompute the condition inside BeforeAll.`n" + $detail)
    }

    It 'still bites on the deliberate fixture' {
        # The assertion above passes for a repository with no slow suites at all,
        # so the scanner is pointed at a file that is known to violate.
        $bait = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/slowskip/DiscoveryReadInBeforeAll.ps1'

        @(Get-HDTSlowSuiteSkipViolation -Path $bait).Count | Should -BeGreaterThan 0
    }
}
