#requires -Version 5.1

# ONE PLACE OF TRUTH FOR THE LAB MEMORY BUDGET (CLAUDE.md rule 8), TESTED
# AGAINST THE SET.
#
# The number lived in SIX files until 2026-09-06: New-HDTLabVirtualMachine, and
# five tests/e2e/*.E2E.Tests.ps1 suites that each re-implemented the same
# running-total check inline. Raising it from 12 GB to 32 GB meant finding all
# six, and nothing anywhere would have reported the one that was missed. A test
# that names only the copy somebody just removed passes for that one and fails
# nobody after it - so this one is written against every file in the repository,
# and copy number seven fails the build the day it is written.
#
# NO BYTE LITERAL IS WRITTEN IN THIS FILE. The digits are built from PowerShell's
# own 32GB / 8GB / 12GB constants. Written out, they would match this file and
# every count would be at least one, which is the shape in which a contract test
# quietly stops checking anything.
#
# WHY THE SCAN IS CONTEXTUAL AND NOT A BARE grep. 8589934592 is 8 GB and
# 34359738368 is 32 GB, and both are perfectly ordinary DISK sizes: they appear
# today in eight files as fixture disk rows, a content VHDX size and a volume
# assertion, none of which has anything to do with how much memory a VM may
# hold. A bare-digit count would be red for reasons that are not defects and
# would be silenced by exclusions within a week. So a hit counts when the digits
# stand within two lines of the words that make them a MEMORY budget - which is
# exactly the shape any real copy of this rule would have, and is proven to bite
# by the last assertion in this file.

BeforeAll {
    $script:budgetRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # Built, never written - see the header.
    $script:combinedDigit = ([long] 32GB).ToString()
    $script:perVmDigit = ([long] 8GB).ToString()
    $script:retiredDigit = ([long] 12GB).ToString()

    $script:budgetHome = 'tests\helpers\HDTTestTools\tools\Get-HDTLabMemoryBudget.ps1'

    # THE FILE LIST IS BUILT IN THE RUN PHASE, not in BeforeDiscovery. SPIKES
    # S9.15: the two do not share a scope, and a $script: variable set in
    # discovery is $null here - which makes @($null).Count 1 and every "scans at
    # least one file" guard pass over nothing at all.
    function Get-HDTLabBudgetScanFile {
        return @(
            Get-ChildItem -LiteralPath $script:budgetRepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.md' -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notmatch '\\out\\' -and
                    $_.FullName -notmatch '\\\.git\\' -and
                    $_.FullName -notmatch '\\\.claude\\worktrees\\' -and
                    # Historical plans and summaries record what was true when
                    # they were written. CLAUDE.md's own note: a plan carrying a
                    # stale value is staleness, not a correction.
                    $_.FullName -notmatch '\\\.planning\\phases\\' -and
                    # Generated from src/, so it carries whatever src/ carries.
                    $_.Name -ne 'Hephaestus.bundle.ps1' -and
                    $_.Name -ne 'LabMemoryBudget.Contract.Tests.ps1'
                }
        )
    }

    # A copy of the budget is the digits standing in a memory context. Two lines
    # either side, because the number and the word are rarely on one line: the
    # shape this replaced was a comparison on one line and the throw on the next.
    function Get-HDTLabBudgetCopy {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Digit,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [System.IO.FileInfo[]] $File
        )

        foreach ($item in $File) {
            $line = @(Get-Content -LiteralPath $item.FullName -ErrorAction SilentlyContinue)
            if ($line.Count -eq 0) { continue }

            for ($i = 0; $i -lt $line.Count; $i++) {
                if (([string] $line[$i]) -notmatch $Digit) { continue }

                $from = [math]::Max(0, $i - 2)
                $to = [math]::Min($line.Count - 1, $i + 2)
                $window = (@($line[$from..$to]) -join ' ')

                # A memory word, or one of the identifiers a real copy would
                # have to use to be a memory quantity at all. The words are the
                # rule; the identifiers are the same rule spelled as code, and
                # they are here because a copy written without a comment is
                # exactly the copy this must still catch.
                if ($window -match '(?i)memor|budget|LabByte') {
                    [pscustomobject] @{
                        Path = $item.FullName.Substring($script:budgetRepoRoot.Length + 1)
                        Line = $i + 1
                        Text = ([string] $line[$i]).Trim()
                    }
                }
            }
        }
    }

    $script:budgetScanFile = @(Get-HDTLabBudgetScanFile)
}

Describe 'Lab memory budget contract' {

    It 'scans at least one file' {
        @($script:budgetScanFile).Count | Should -BeGreaterThan 0 -Because 'a contract that scans nothing proves nothing'
    }

    It 'defines the combined budget byte value in exactly one file' {
        $hit = @(Get-HDTLabBudgetCopy -Digit $script:combinedDigit -File $script:budgetScanFile)

        # The FILE, not just the count. A count of one somewhere else is one
        # copy in the wrong place, and it would pass a count-only assertion.
        @($hit | ForEach-Object { $_.Path } | Sort-Object -Unique) |
            Should -Be @($script:budgetHome) -Because ('the combined budget lives in one file: {0}' -f (($hit | ForEach-Object { '{0}:{1}' -f $_.Path, $_.Line }) -join '; '))
    }

    It 'defines the per-VM cap byte value in exactly one file' {
        $hit = @(Get-HDTLabBudgetCopy -Digit $script:perVmDigit -File $script:budgetScanFile)

        @($hit | ForEach-Object { $_.Path } | Sort-Object -Unique) |
            Should -Be @($script:budgetHome) -Because ('the per-VM cap lives in one file: {0}' -f (($hit | ForEach-Object { '{0}:{1}' -f $_.Path, $_.Line }) -join '; '))
    }

    It 'carries the retired 12 GB byte value nowhere at all' {
        # It was the whole budget until the lab gained a WSUS server and a WDS
        # server that held exactly that much between them.
        $hit = @(Get-HDTLabBudgetCopy -Digit $script:retiredDigit -File $script:budgetScanFile)

        $hit | Should -BeNullOrEmpty -Because ('the 12 GB budget is retired: {0}' -f (($hit | ForEach-Object { '{0}:{1}' -f $_.Path, $_.Line }) -join '; '))
    }

    It 'has every E2E file ask Assert-HDTLabMemoryBudget rather than compute its own total' {
        $e2e = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:budgetRepoRoot -ChildPath 'tests\e2e') -File -Filter '*.E2E.Tests.ps1')
        $e2e.Count | Should -BeGreaterThan 0

        $violation = @()
        foreach ($item in $e2e) {
            $text = Get-Content -LiteralPath $item.FullName -Raw

            if ($text -notmatch 'Assert-HDTLabMemoryBudget') {
                $violation += ('{0}: does not ask Assert-HDTLabMemoryBudget' -f $item.Name)
            }

            # MemoryAssigned is what the five inline running totals summed. Its
            # presence in an e2e file is the old shape growing back.
            if ($text -match 'MemoryAssigned') {
                $violation += ('{0}: totals MemoryAssigned itself' -f $item.Name)
            }
        }

        $violation | Should -BeNullOrEmpty -Because ($violation -join '; ')
    }

    It 'has New-HDTLabVirtualMachine ask Assert-HDTLabMemoryBudget rather than compute its own total' {
        $path = Join-Path -Path $script:budgetRepoRoot -ChildPath 'tests\helpers\HDTTestTools\tools\New-HDTLabVirtualMachine.ps1'
        $text = Get-Content -LiteralPath $path -Raw

        $text | Should -Match 'Assert-HDTLabMemoryBudget'
        $text | Should -Not -Match 'MemoryAssigned'
    }

    It 'states 32 GB, and never 12 GB, on every prose surface that states the number' {
        # Matched on the PHRASE around the number, not on a bare '12 GB'. SPIKES
        # 1519 records a target VHDX growing to 12 GB, which is not this and must
        # not read as a violation.
        $surface = @(
            '.planning\PROJECT.md'
            'CLAUDE.md'
            'build.ps1'
            'tests\e2e\README.md'
            'docs\ROADMAP.md'
            'tests\helpers\README.md'
        )

        $pattern = '(?i)(\d+)\s*GB\s+(combined|lab budget|budget|across every running)'

        $violation = @()
        foreach ($relative in $surface) {
            $path = Join-Path -Path $script:budgetRepoRoot -ChildPath $relative
            $found = 0

            foreach ($line in @(Get-Content -LiteralPath $path)) {
                foreach ($m in @([regex]::Matches([string] $line, $pattern))) {
                    $found++
                    if ($m.Groups[1].Value -ne '32') {
                        $violation += ('{0}: "{1}"' -f $relative, $m.Value)
                    }
                }
            }

            # A surface that stopped stating the number is a surface that stopped
            # being checked.
            if ($found -eq 0) {
                $violation += ('{0}: states no budget at all' -f $relative)
            }
        }

        $violation | Should -BeNullOrEmpty -Because ($violation -join '; ')
    }

    It 'bites on a deliberate violation' {
        # THE ASSERTION THAT STOPS THIS FILE ROTTING INTO DECORATION. Everything
        # above is green when the scan finds nothing - including when the scan is
        # broken and can find nothing. So plant one and prove it is found.
        $planted = Join-Path -Path $script:budgetRepoRoot -ChildPath 'tests\contract\LabMemoryBudget.Violation.tmp.ps1'

        try {
            Set-Content -LiteralPath $planted -Encoding UTF8 -Value @(
                '# A seventh copy of the lab memory budget, planted by the contract test.'
                ('$maximumLabByte = {0}' -f $script:combinedDigit)
            )

            $hit = @(Get-HDTLabBudgetCopy -Digit $script:combinedDigit -File @(Get-Item -LiteralPath $planted))

            @($hit).Count | Should -Be 1 -Because 'a scan that cannot find a planted copy is checking nothing'
            $hit[0].Path | Should -BeLike '*LabMemoryBudget.Violation.tmp.ps1'
        } finally {
            # By explicit -LiteralPath, to the one file this test created.
            if (Test-Path -LiteralPath $planted -PathType Leaf) {
                Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
