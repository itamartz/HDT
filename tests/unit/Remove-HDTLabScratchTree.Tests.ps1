# The teardown the E2E suites use to give back the gigabyte each of them builds,
# asserted through its REFUSALS - because the whole risk of a cleanup helper is
# the one call that names the wrong thing.
#
# WHY IT EXISTS. The four files in tests/e2e each build a boot image into its
# own root under C:\HDTLab\scratch and none of them ever removed it: 7.1 GB had
# accumulated there, 5 GB of it dead build roots from runs weeks apart. An
# AfterAll that removes a VM but leaves 2 GB of mounted-and-committed WIM
# staging is half a teardown.
#
# WHY IT IS A COMMAND AND NOT FOUR COPIES OF Remove-Item. CLAUDE.md, "Paths that
# must never be deleted": never pass a variable to Remove-Item -Recurse without
# asserting first that it is one of the permitted locations. Written once, the
# assertion can be proven; written four times it is four chances to get it
# wrong, and the one that is wrong deletes the staged media.
#
# NOTHING HERE DELETES ANYTHING THAT MATTERS. Every refusal test passes a path
# the function must reject, so no removal happens at all. The one test that does
# remove works on a directory IT CREATES under C:\HDTLab\scratch with an HDT-*
# name - the exact case CLAUDE.md permits - and is skipped when the lab is not
# on this machine.

# THE LAB CHECK IS IN BeforeDiscovery BECAUSE -Skip: READS IT WHILE DISCOVERING.
# SPIKES S9.15: the two phases do not share a scope, so a $script: variable set
# in BeforeAll is not there for a -Skip: on a Context, and under StrictMode the
# read takes the whole container down. Nothing in a test BODY reads it.
BeforeDiscovery {
    $script:hasLab = Test-Path -LiteralPath 'C:\HDTLab\scratch' -PathType Container
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Remove-HDTLabScratchTree' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Remove-HDTLabScratchTree' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'supports ShouldProcess, because it deletes a directory tree' {
        (Get-Command -Name 'Remove-HDTLabScratchTree').Parameters.Keys |
            Should -Contain 'WhatIf'
    }

    Context 'it refuses a target that is not a scratch directory' {

        # A half-created path is the shape an AfterAll sees when the BeforeAll
        # that was going to set it threw first. $null and '' must refuse, not
        # coerce into something with a meaning.
        It 'refuses a null path' {
            { Remove-HDTLabScratchTree -Path $null -Confirm:$false } |
                Should -Throw -ExpectedMessage '*refuses*'
        }

        It 'refuses an empty path' {
            { Remove-HDTLabScratchTree -Path '' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*refuses*'
        }

        It 'refuses a whitespace path' {
            { Remove-HDTLabScratchTree -Path '   ' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*refuses*'
        }

        # THE SET, not one example. Every one of these is a path this repository
        # has written down as protected, or a parent of the scratch area, or a
        # drive root - and every one of them would be a catastrophe.
        It 'refuses <Target>' -ForEach @(
            @{ Target = 'C:\' }
            @{ Target = 'C:' }
            @{ Target = 'C:\HDTLab' }
            @{ Target = 'C:\HDTLab\' }
            @{ Target = 'C:\HDTLab\media' }
            @{ Target = 'C:\HDTLab\media\Win11-LTSC-2024' }
            @{ Target = 'C:\HDTLab\Share' }
            @{ Target = 'C:\HDTLab\reference' }
            @{ Target = 'C:\HDTLab\vms' }
            @{ Target = 'C:\HDTLab\scratch' }
            @{ Target = 'C:\HDTLab\scratch\' }
            @{ Target = 'C:\Users\Itamartz\Documents\GithubRepos\HDT' }
            @{ Target = 'C:\Users\Itamartz' }
            @{ Target = 'C:\Windows' }
            @{ Target = 'D:\scratch\e2e' }
            @{ Target = '\\server\share\scratch' }
            @{ Target = 'scratch\e2e' }
            @{ Target = 'C:\HDTLab\scratch\..\media' }
            @{ Target = 'C:\HDTLab\scratch\*' }
            @{ Target = 'C:\HDTLab\scratchy\e2e' }
        ) {
            { Remove-HDTLabScratchTree -Path $Target -Confirm:$false } |
                Should -Throw -ExpectedMessage '*refuses*'
        }
    }

    Context 'the live build scratch is never a target' {

        # C:\HDTLab\scratch\bootimage IS THE USER'S OWN BUILD SCRATCH. It is
        # bounded already, because Update-HDTBootImage empties it at the start of
        # every run, and 25 tests read its mount\ tree afterwards to answer "what
        # actually went into my image?". A teardown that removed it would break
        # those and take the debuggability with it.
        It 'refuses C:\HDTLab\scratch\bootimage by name' {
            { Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\bootimage' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*bootimage*'
        }

        It 'refuses anything inside it too' -ForEach @(
            @{ Target = 'C:\HDTLab\scratch\bootimage\work' }
            @{ Target = 'C:\HDTLab\scratch\bootimage\Share' }
            @{ Target = 'C:\HDTLab\scratch\bootimage\work\mount' }
        ) {
            { Remove-HDTLabScratchTree -Path $Target -Confirm:$false } |
                Should -Throw -ExpectedMessage '*bootimage*'
        }

        It 'leaves the directory standing when it refuses' -Skip:(-not $script:hasLab) {
            $before = Test-Path -LiteralPath 'C:\HDTLab\scratch\bootimage'

            $refusal = $null
            try {
                Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\bootimage' -Confirm:$false
            } catch {
                $refusal = $_
            }

            $refusal | Should -Not -BeNullOrEmpty -Because 'the refusal is the point; a silent return would be indistinguishable from a delete that worked'
            (Test-Path -LiteralPath 'C:\HDTLab\scratch\bootimage') | Should -Be $before
        }
    }

    Context 'it accepts a scratch root' {

        It 'accepts a first-level directory under the scratch area' {
            # -WhatIf, so nothing is removed: the assertion is that the guard
            # let it through, not that a directory went away.
            { Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-bootimage' -WhatIf } |
                Should -Not -Throw
        }

        It 'says nothing and does nothing when the directory is not there' {
            { Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\HDT-no-such-tree-here' -Confirm:$false } |
                Should -Not -Throw
        }

        # THE ONE TEST THAT ACTUALLY DELETES. Its target is created by this test,
        # under C:\HDTLab\scratch, with an HDT-* name - CLAUDE.md's third
        # permitted case, in full.
        It 'removes a tree it created, files and all' -Skip:(-not $script:hasLab) {
            $target = 'C:\HDTLab\scratch\HDT-unittest-scratchtree'

            New-Item -Path (Join-Path -Path $target -ChildPath 'deep\deeper') -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'deep\deeper\file.txt') -Value 'x' -Encoding UTF8

            Remove-HDTLabScratchTree -Path $target -Confirm:$false

            Test-Path -LiteralPath $target | Should -BeFalse
        }
    }

    Context 'it never fails the suite that calls it' {

        # An AfterAll runs after a failure, and a teardown that throws there
        # turns one red test into a red container. A tree that cannot be removed
        # - a stranded DISM mount holding files open is the usual cause - has to
        # WARN instead, loudly enough that the leak is noticed.
        It 'warns rather than throws when the removal itself fails' -Skip:(-not $script:hasLab) {
            $target = 'C:\HDTLab\scratch\HDT-unittest-lockedtree'
            $file = Join-Path -Path $target -ChildPath 'locked.bin'

            New-Item -Path $target -ItemType Directory -Force | Out-Null
            $stream = [System.IO.File]::Open($file, 'Create', 'Write', 'None')

            try {
                # CALLED STRAIGHT, not through a { } handed to Should -Not -Throw:
                # -WarningVariable writes into the scope the command runs in, and
                # that scriptblock is a different one, so the capture came back
                # empty while the warning was being written perfectly well.
                $warning = @()
                $thrown = $null
                try {
                    Remove-HDTLabScratchTree -Path $target -Confirm:$false -WarningVariable warning -WarningAction SilentlyContinue
                } catch {
                    $thrown = $_
                }

                $thrown | Should -BeNullOrEmpty -Because 'a teardown that throws turns one red test into a red container'

                # Loud enough to notice: it names the path AND says a leak was
                # left behind, so a green run that leaked still says so.
                ($warning -join ' ') | Should -BeLike '*HDT-unittest-lockedtree*'
                ($warning -join ' ') | Should -BeLike '*LEAK*'
            } finally {
                $stream.Dispose()
                Remove-HDTLabScratchTree -Path $target -Confirm:$false -WarningAction SilentlyContinue
            }
        }
    }
}
