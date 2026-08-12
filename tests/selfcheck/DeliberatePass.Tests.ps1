# The mirror image of DeliberateFailure.Tests.ps1.
#
# A harness that reports failure for everything would pass the failure check and
# still be useless, so the self-check asserts a green run stays green and exits
# zero. See tests/helpers/README.md.

Describe 'HDT harness self-check (deliberate pass)' {

    It 'passes on purpose so the harness can prove it reports success' {
        $true | Should -BeTrue -Because 'this test exists to be green'
    }
}
