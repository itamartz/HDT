# Folding the worker processes' results back into one verdict.
#
# WHAT THIS HAS TO PRODUCE is something Write-HDTBuildBadge and
# Assert-HDTPesterResult accept unchanged, because both already read a Pester
# result and both already encode judgements worth keeping - in particular
# Assert-HDTPesterResult's rule that FailedContainersCount is a failure even
# when FailedCount is zero. Sharding must not be a way to lose that.
#
# THE COUNTS ADD, THE VERDICT DOES NOT. Eight green shards and one red shard is
# a red run, and the red one is the only one whose detail matters.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:newSummary = {
        param($Passed, $Failed, $Skipped, $FailedContainers, $Detail)

        return [pscustomobject] @{
            PassedCount           = $Passed
            FailedCount           = $Failed
            SkippedCount          = $Skipped
            FailedContainersCount = $FailedContainers
            ContainerDetail       = @($Detail)
        }
    }
}

Describe 'Merge-HDTPesterSummary' {

    Context 'the counts add up' {

        It 'sums passed, failed and skipped across the shards' {
            $summary = @(
                (& $script:newSummary 100 0 5 0 @()),
                (& $script:newSummary 250 2 11 0 @()),
                (& $script:newSummary 40 0 0 0 @())
            )

            $merged = Merge-HDTPesterSummary -Summary $summary

            $merged.PassedCount | Should -Be 390
            $merged.FailedCount | Should -Be 2
            $merged.SkippedCount | Should -Be 16
        }

        It 'sums the containers that could not be run at all' {
            $summary = @(
                (& $script:newSummary 10 0 0 1 @('a.Tests.ps1: boom')),
                (& $script:newSummary 10 0 0 2 @('b.Tests.ps1: bang', 'c.Tests.ps1: crash'))
            )

            $merged = Merge-HDTPesterSummary -Summary $summary
            $merged.FailedContainersCount | Should -Be 3
        }

        It 'reports a single shard unchanged' {
            $merged = Merge-HDTPesterSummary -Summary @((& $script:newSummary 8613 0 241 0 @()))

            $merged.PassedCount | Should -Be 8613
            $merged.FailedCount | Should -Be 0
            $merged.SkippedCount | Should -Be 241
        }
    }

    Context 'what Assert-HDTPesterResult reads off it' {

        It 'carries the failing containers detail through, named' {
            # Assert-HDTPesterResult's whole point is that "1 container failed"
            # without a path sends the operator to read three suites.
            $summary = @(
                (& $script:newSummary 10 0 0 0 @()),
                (& $script:newSummary 10 0 0 1 @('tests/unit/Broken.Tests.ps1: a Skip: read an unset variable'))
            )

            $merged = Merge-HDTPesterSummary -Summary $summary

            @($merged.Containers).Count | Should -Be 1
            [string] $merged.Containers[0].Item | Should -BeLike '*Broken.Tests.ps1*'
            (@($merged.Containers[0].ErrorRecord) -join ' ') | Should -BeLike '*unset variable*'
        }

        It 'exposes an empty Containers collection when every shard was green' {
            # StrictMode is on in build.ps1: Assert-HDTPesterResult enumerates
            # .Containers, so the property has to exist even on a clean run.
            $merged = Merge-HDTPesterSummary -Summary @((& $script:newSummary 10 0 0 0 @()))
            @($merged.Containers).Count | Should -Be 0
        }

        It 'measures no coverage, and says so with a null rather than a zero' {
            # Write-HDTBuildBadge writes no coverage badge when CodeCoverage is
            # null, and writes a 0% one when it is present and empty. A sharded
            # run measures nothing, so the badges branch must keep the real
            # number from the last nightly.
            $merged = Merge-HDTPesterSummary -Summary @((& $script:newSummary 10 0 0 0 @()))
            $merged.CodeCoverage | Should -BeNullOrEmpty
        }
    }

    Context 'it refuses to invent a green run' {

        It 'refuses an empty shard list' {
            { Merge-HDTPesterSummary -Summary @() } | Should -Throw -ExpectedMessage '*no worker*'
        }

        It 'counts a shard that reported nothing at all as a failure' {
            # A worker that died - crashed host, killed process - writes no
            # summary. Merging $null as "zero passed, zero failed" is exactly
            # the empty-dispatch defect build.ps1's header warns about.
            { Merge-HDTPesterSummary -Summary @((& $script:newSummary 10 0 0 0 @()), $null) } |
                Should -Throw -ExpectedMessage '*did not report*'
        }

        It 'names every worker that reported nothing, not only the first' {
            # THIS COST AN INVESTIGATION. All eight workers were dying on the
            # same Import-Module and the build said "worker 1 of 8", which reads
            # as one flaky shard out of eight - a race - rather than as a
            # systematic failure of the runner. Eight-of-eight and one-of-eight
            # are different diagnoses and this is the only place that knows.
            { Merge-HDTPesterSummary -Summary @($null, (& $script:newSummary 10 0 0 0 @()), $null) } |
                Should -Throw -ExpectedMessage '*1, 3 of 3*'
        }

        It 'carries the reason the caller gathered for each dead worker' {
            # The parent captures each worker's stderr to a file. Merging is
            # where the counts are judged, so it is where the log has to surface
            # - otherwise the build prints the symptom and the cause stays on
            # disk in a directory the next run deletes.
            {
                Merge-HDTPesterSummary -Summary @((& $script:newSummary 10 0 0 0 @()), $null) `
                    -Reason @('', 'exit code 1; stderr err-1.log: Import-Module : the module was not loaded')
            } | Should -Throw -ExpectedMessage '*Import-Module : the module was not loaded*'
        }

        It 'still refuses a dead worker when no reason was gathered' {
            { Merge-HDTPesterSummary -Summary @((& $script:newSummary 10 0 0 0 @()), $null) -Reason @() } |
                Should -Throw -ExpectedMessage '*did not report*'
        }

        It 'merges a full set of live workers when a reason list is supplied' {
            $merged = Merge-HDTPesterSummary -Summary @(
                (& $script:newSummary 10 0 0 0 @()),
                (& $script:newSummary 5 0 0 0 @())) -Reason @('', '')

            $merged.PassedCount | Should -Be 15
        }
    }
}
