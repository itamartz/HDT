# How many child processes ./build.ps1 -Task test starts when nobody said.
#
# THE DEFAULT HAS TO BE SAFE ON A MACHINE THIS REPOSITORY HAS NEVER SEEN. It is
# read on the lab host (20 cores), on a GitHub runner (2 or 4), and inside a
# container that may report 1. Every one of those has to produce a number that
# runs the suite - a zero or a negative would shard the run into nothing, which
# is the empty-dispatch defect build.ps1's own header warns about.
#
# WHY IT IS CAPPED. Measured on this repository: 4 workers took 229s against
# 500s serial, and 8 took 197s. The extra four bought 32 seconds because a
# sharded run cannot finish before its longest single test file, and past that
# point more workers only add process startup. Eight is where the curve flattens,
# not a guess about the hardware.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTWorkerCount' {

    Context 'an explicit request wins' {

        It 'returns exactly what was asked for' -ForEach @(1, 2, 4, 8) {
            Get-HDTWorkerCount -Requested $_ -ProcessorCount 20 | Should -Be $_
        }

        It 'holds an over-large request down to the cap' -ForEach @(16, 32, 128) {
            # The cap is a measurement, not a preference: past eight workers this
            # suite is bounded by its longest single file, so the extra processes
            # only compete for the cores the other eight are using.
            Get-HDTWorkerCount -Requested $_ -ProcessorCount 20 | Should -Be 8
        }

        It 'honours 1, so a failure can be read in order' {
            # -Worker 1 is the documented escape hatch from interleaved output.
            # Auto-sizing over the top of it would take that away.
            Get-HDTWorkerCount -Requested 1 -ProcessorCount 64 | Should -Be 1
        }

        It 'does not let an explicit request exceed the core count by much' {
            # 128 workers on 2 cores is thrash, not parallelism.
            Get-HDTWorkerCount -Requested 128 -ProcessorCount 2 | Should -BeLessOrEqual 8
        }
    }

    Context 'zero means decide for me' {

        It 'leaves two cores for the rest of the machine' {
            Get-HDTWorkerCount -Requested 0 -ProcessorCount 6 | Should -Be 4
        }

        It 'caps at eight however many cores there are' {
            Get-HDTWorkerCount -Requested 0 -ProcessorCount 20 | Should -Be 8
            Get-HDTWorkerCount -Requested 0 -ProcessorCount 128 | Should -Be 8
        }

        It 'still returns a usable worker on a small runner' -ForEach @(1, 2, 3) {
            Get-HDTWorkerCount -Requested 0 -ProcessorCount $_ | Should -BeGreaterOrEqual 1
        }

        It 'never returns zero or less' -ForEach @(1, 2, 3, 4, 8, 16, 64) {
            Get-HDTWorkerCount -Requested 0 -ProcessorCount $_ | Should -BeGreaterThan 0
        }
    }

    Context 'on this machine' {

        It 'reads the processor count when it is not told one' {
            $count = Get-HDTWorkerCount -Requested 0
            $count | Should -BeGreaterThan 0
            $count | Should -BeLessOrEqual 8
        }
    }
}
