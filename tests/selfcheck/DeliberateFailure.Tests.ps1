# DELIBERATELY RED. This file is not a bug and must not be "fixed".
#
# ROADMAP M0 requires the harness to prove it catches a failing test. This
# fixture is that failing test. build.ps1 -Task selfcheck runs it in a child
# process and FAILS if it does not go red.
#
# tests/selfcheck is never in Run.Path for build.ps1 -Task test, so this never
# turns the real suite red. See tests/helpers/README.md.

Describe 'HDT harness self-check (deliberate failure)' {

    It 'fails on purpose so the harness can prove it catches failures' {
        $true | Should -BeFalse -Because 'this test exists to be red; see tests/helpers/README.md'
    }
}
