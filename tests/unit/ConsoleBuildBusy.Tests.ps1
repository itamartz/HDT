# A BAR THAT DOES NOT MOVE IS INDISTINGUISHABLE FROM A BUILD THAT HAS HUNG.
#
# Mounting, committing and a folder of drivers injected with -Recurse are each
# ONE DISM call with no callback, so the boot image build reported once and then
# worked for a minute or more with the bar frozen at the same pixel. A technician
# watching it had nothing to tell "slow" from "stuck".

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTConsoleBuildBusy' {

    It 'is reachable inside the module' {
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTConsoleBuildBusy' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'measures the bar while the reports are still arriving' {
        InModuleScope Hephaestus {
            Get-HDTConsoleBuildBusy -QuietSecond 0 | Should -BeFalse
            Get-HDTConsoleBuildBusy -QuietSecond 1.5 | Should -BeFalse
        }
    }

    It 'sweeps the bar once nothing has been heard for a few seconds' {
        InModuleScope Hephaestus {
            Get-HDTConsoleBuildBusy -QuietSecond 3 | Should -BeTrue
            Get-HDTConsoleBuildBusy -QuietSecond 90 | Should -BeTrue
        }
    }

    # THE RULE IS SILENCE, NOT ELAPSED TIME, and this is the case that decides
    # it. With the verbose driver option on, step 10 runs for seven minutes and
    # reports seventy times - about six seconds apart, which IS quiet enough to
    # sweep, and rightly: between one driver and the next there is no news. What
    # would be wrong is keying on how long the STEP has run, because then a step
    # reporting steadily would still be called idle.
    It 'is about the gap since the last report, whatever step it belonged to' {
        InModuleScope Hephaestus {
            # A burst - nine optional components, a second apart.
            Get-HDTConsoleBuildBusy -QuietSecond 1 | Should -BeFalse

            # The same step, ninety seconds into one silent DISM call.
            Get-HDTConsoleBuildBusy -QuietSecond 90 | Should -BeTrue
        }
    }
}
