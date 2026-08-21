# Splitting the suite across worker processes, so ./build.ps1 -Task test can run
# more than one at a time.
#
# WHY BUCKETS AND NOT JUST "EVERY Nth FILE". Round-robin over an alphabetical
# list was measured at 197s across 8 workers against 500s serial - a 2.5x on
# twenty cores. The reason it stalls short is that the buckets finish at wildly
# different times: one file used to cost 121s on its own, and no number of
# workers finishes sooner than the longest bucket. Packing longest-first off the
# previous run's timings is what turns 8 workers into something near 8x.
#
# THE DURATIONS ARE ADVISORY, NEVER LOAD-BEARING. They come from the NUnit XML
# of the last run, which ./build.ps1 -Task clean deletes, so the first run after
# a clean has none at all. A missing duration must degrade to a merely-unbalanced
# run, never to a file that does not get run - which is what the "every file
# exactly once" assertions below are guarding.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # Ten files, named so a failure says which one went missing.
    $script:file = @(1..10 | ForEach-Object { 'C:\repo\tests\unit\File{0:D2}.Tests.ps1' -f $_ })
}

Describe 'Split-HDTTestBucket' {

    Context 'every file runs, exactly once' {

        It 'returns one bucket per worker' {
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 4)
            $bucket.Count | Should -Be 4
        }

        It 'places every file in exactly one bucket' {
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 4)
            $flat = @($bucket | ForEach-Object { $_ })

            # -Be on two arrays compares element by element, so sort both: the
            # claim is set equality, not that packing preserved the input order.
            @($flat | Sort-Object) | Should -Be @($script:file | Sort-Object)
            @($flat | Sort-Object -Unique).Count | Should -Be $script:file.Count
        }

        It 'loses nothing when the durations are all unknown' {
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 3)
            @(@($bucket | ForEach-Object { $_ }) | Sort-Object) | Should -Be @($script:file | Sort-Object)
        }

        It 'loses nothing when only some durations are known' {
            $duration = @{ 'C:\repo\tests\unit\File01.Tests.ps1' = 90.0 }
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 3 -Duration $duration)
            @(@($bucket | ForEach-Object { $_ }) | Sort-Object) | Should -Be @($script:file | Sort-Object)
        }

        It 'ignores a duration for a file that is not in the run' {
            # The XML is from the LAST run. A deleted or renamed test file is
            # still in it, and must not conjure a bucket entry for a file that
            # no longer exists.
            $duration = @{ 'C:\repo\tests\unit\Deleted.Tests.ps1' = 500.0 }
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 3 -Duration $duration)
            @(@($bucket | ForEach-Object { $_ }) | Sort-Object) | Should -Be @($script:file | Sort-Object)
        }
    }

    Context 'the worker count' {

        It 'returns a single bucket holding everything for one worker' {
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 1)
            $bucket.Count | Should -Be 1
            @($bucket[0] | Sort-Object) | Should -Be @($script:file | Sort-Object)
        }

        It 'never returns an empty bucket' {
            # An empty bucket is a child process that starts, imports Pester,
            # discovers nothing and reports zero tests - which Assert-HDTPesterResult
            # cannot tell apart from a suite that failed to discover.
            $bucket = @(Split-HDTTestBucket -Path $script:file -Worker 4)
            @($bucket | Where-Object { @($_).Count -eq 0 }).Count | Should -Be 0
        }

        It 'returns no more buckets than there are files' {
            $bucket = @(Split-HDTTestBucket -Path @($script:file[0..2]) -Worker 8)
            $bucket.Count | Should -Be 3
        }

        It 'refuses an empty file list' {
            # A run that sharded nothing is not a run that passed.
            { Split-HDTTestBucket -Path @() -Worker 4 } | Should -Throw -ExpectedMessage '*no test file*'
        }
    }

    Context 'balance' {

        It 'puts the one slow file alone and shares the rest' {
            # Nine files of 1s and one of 100s across two workers: the only
            # sensible packing is 100 | 9, and a round-robin would produce
            # 100+4 | 5 - half as good again as it needs to be.
            $path = @(1..10 | ForEach-Object { 'F{0}' -f $_ })
            $duration = @{}
            foreach ($p in $path) { $duration[$p] = 1.0 }
            $duration['F1'] = 100.0

            $bucket = @(Split-HDTTestBucket -Path $path -Worker 2 -Duration $duration)

            $slow = @($bucket | Where-Object { $_ -contains 'F1' })
            @($slow[0]).Count | Should -Be 1
        }

        It 'keeps the longest bucket within one file of optimal' {
            # Twelve files, durations 1..12 (sum 78) across 3 workers: a perfect
            # split is 26 each and longest-first reaches exactly that.
            $path = @(1..12 | ForEach-Object { 'F{0:D2}' -f $_ })
            $duration = @{}
            for ($i = 0; $i -lt 12; $i++) { $duration[$path[$i]] = [double] ($i + 1) }

            $bucket = @(Split-HDTTestBucket -Path $path -Worker 3 -Duration $duration)

            $total = @($bucket | ForEach-Object {
                    $sum = 0.0
                    foreach ($p in $_) { $sum += $duration[$p] }
                    $sum
                })

            ($total | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 26.0
        }

        It 'orders the buckets longest first' {
            # The dispatcher starts them in order. Starting the heaviest first
            # is what stops the last worker launching into the tail of the run.
            $path = @(1..6 | ForEach-Object { 'F{0}' -f $_ })
            $duration = @{ 'F1' = 60.0; 'F2' = 30.0; 'F3' = 10.0; 'F4' = 5.0; 'F5' = 2.0; 'F6' = 1.0 }

            $bucket = @(Split-HDTTestBucket -Path $path -Worker 3 -Duration $duration)

            $total = @($bucket | ForEach-Object {
                    $sum = 0.0
                    foreach ($p in $_) { $sum += $duration[$p] }
                    $sum
                })

            $total[0] | Should -BeGreaterOrEqual $total[-1]
        }
    }
}
