# DESIGN 4.2's runIn, decided in one place.
#
# A step declares WinPE, FullOS or Any; a leg is running in WinPE or in FullOS.
# The rule is small enough to inline and important enough not to: it is what
# stops a full-OS step running against a RAM disk, and what stops a WinPE-only
# step running after the machine has rebooted into Windows.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTStepRunInPhase' {

    It 'runs an Any step in WinPE' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'Any' -Phase 'WinPE' | Should -BeTrue
        }
    }

    It 'runs an Any step in FullOS' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'Any' -Phase 'FullOS' | Should -BeTrue
        }
    }

    It 'runs a WinPE step in WinPE' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'WinPE' -Phase 'WinPE' | Should -BeTrue
        }
    }

    It 'skips a WinPE step in FullOS' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'WinPE' -Phase 'FullOS' | Should -BeFalse
        }
    }

    It 'runs a FullOS step in FullOS' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'FullOS' -Phase 'FullOS' | Should -BeTrue
        }
    }

    It 'skips a FullOS step in WinPE' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'FullOS' -Phase 'WinPE' | Should -BeFalse
        }
    }

    It 'treats a null runIn as Any' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn $null -Phase 'WinPE' | Should -BeTrue
            Test-HDTStepRunInPhase -RunIn $null -Phase 'FullOS' | Should -BeTrue
        }
    }

    It 'treats an empty runIn as Any' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn '' -Phase 'FullOS' | Should -BeTrue
        }
    }

    It 'compares case-insensitively, the way every other HDT comparison does' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'winpe' -Phase 'WinPE' | Should -BeTrue
        }
    }

    It 'returns a boolean, not a truthy string' {
        InModuleScope Hephaestus {
            Test-HDTStepRunInPhase -RunIn 'Any' -Phase 'WinPE' | Should -BeOfType ([bool])
        }
    }
}
