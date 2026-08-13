# The guard 04-VERIFICATION asked for and nobody wrote (SPIKES S9.15).
#
# Pester's discovery and run phases DO NOT SHARE A SCOPE. A $script: variable
# assigned in BeforeDiscovery is what the -Skip: on a Describe reads while
# discovering; reading it inside BeforeAll throws under Set-StrictMode -Version
# Latest - which is what ./build.ps1 sets and a bare Invoke-Pester does not - and
# WITHOUT StrictMode it evaluates to $null, so 'if (-not $null)' is TRUE and the
# expensive body runs on a machine that was supposed to be skipping it.
#
# That took tests/integration down for the whole of phase 04 and hid, because
# every run of the file had been a bare Invoke-Pester. Phase 05 adds three more
# slow suites with skip conditions, so the scanner lands BEFORE they are written
# rather than after each has been debugged once.
#
# AST, NOT REGEX, for the parseable case: the assignment and the read are the
# same token, and a text scan cannot tell one from the other.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/slowskip'
    $script:violationPath = Join-Path -Path $script:fixtureRoot -ChildPath 'DiscoveryReadInBeforeAll.ps1'
    $script:fixedPath = Join-Path -Path $script:fixtureRoot -ChildPath 'RecomputedInBeforeAll.ps1'
    $script:discoveryOnlyPath = Join-Path -Path $script:fixtureRoot -ChildPath 'DiscoveryOnly.ps1'
    $script:unparseablePath = Join-Path -Path $script:fixtureRoot -ChildPath 'Unparseable.ps1'
}

Describe 'Get-HDTSlowSuiteSkipViolation' {

    Context 'the shape that broke tests/integration' {

        It 'reports a variable set in BeforeDiscovery and read in BeforeAll' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:violationPath)

            $violation.Count | Should -Be 1
            $violation[0].Variable | Should -BeExactly 'skipSlow'
        }

        It 'reports the file, the line and the variable name' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:violationPath)

            $violation[0].Path | Should -BeExactly ([System.IO.Path]::GetFullPath($script:violationPath))
            $violation[0].Line | Should -BeGreaterThan 0
            $violation[0].Message | Should -BeLike '*skipSlow*'
            $violation[0].Message | Should -BeLike '*BeforeDiscovery*'
            $violation[0].Message | Should -BeLike '*BeforeAll*'
        }

        It 'names SPIKES S9.15 in the message' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:violationPath)

            $violation[0].Message | Should -BeLike '*S9.15*'
        }
    }

    Context 'the shapes that are correct' {

        It 'reports nothing when BeforeAll recomputes it first' {
            @(Get-HDTSlowSuiteSkipViolation -Path $script:fixedPath).Count | Should -Be 0
        }

        It 'reports nothing for a variable only used in the Describe -Skip:' {
            @(Get-HDTSlowSuiteSkipViolation -Path $script:discoveryOnlyPath).Count | Should -Be 0
        }

        It 'reports nothing for a file with no BeforeDiscovery at all' {
            @(Get-HDTSlowSuiteSkipViolation -Path (Join-Path -Path $script:repoRoot -ChildPath 'tests/unit/FakeJournal.Tests.ps1')).Count |
                Should -Be 0
        }
    }

    Context 'a file it cannot parse' {

        It 'falls back to a line scan for a file it cannot parse' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:unparseablePath)

            $violation.Count | Should -BeGreaterThan 0
            $violation[0].Variable | Should -BeExactly 'skipSlow'
        }

        It 'says in the message that the file did not parse' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path $script:unparseablePath)

            $violation[0].Message | Should -BeLike '*did not parse*'
        }
    }

    Context 'input' {

        It 'accepts several files at once' {
            $violation = @(Get-HDTSlowSuiteSkipViolation -Path @($script:violationPath, $script:fixedPath))

            $violation.Count | Should -Be 1
        }

        It 'accepts pipeline input' {
            $violation = @(@($script:violationPath, $script:fixedPath) | Get-HDTSlowSuiteSkipViolation)

            $violation.Count | Should -Be 1
        }

        It 'throws for a file that does not exist' {
            { Get-HDTSlowSuiteSkipViolation -Path 'C:\HDTLab\nothing-here\NoSuch.Tests.ps1' } |
                Should -Throw -ExpectedMessage '*NoSuch.Tests.ps1*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Get-HDTSlowSuiteSkipViolation -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTSlowSuiteSkipViolation'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
