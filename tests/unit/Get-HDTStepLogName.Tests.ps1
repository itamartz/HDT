# DESIGN 4.4.2's numbered per-step log file name.
#
#   Steps\
#     001-Validate.log
#     002-DiskPartition.log
#     003-ApplyImage.log
#
# "Step files are numbered in execution order, so the directory listing itself
# tells you the sequence and where it stopped - the thing you want first when a
# deployment fails."
#
# Which means two things this function has to get right: the number comes from
# the EXECUTION index rather than from the document, and a step name authored by
# a human has to survive becoming a file name.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTStepLogName' {

    It 'zero pads the index to three digits' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 3 -Name 'Validate' | Should -BeExactly '003-Validate.log'
        }
    }

    It 'keeps a simple name' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 12 -Name 'ApplyImage' | Should -BeExactly '012-ApplyImage.log'
        }
    }

    It 'does not truncate an index past three digits' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 1234 -Name 'Late' | Should -BeExactly '1234-Late.log'
        }
    }

    It 'replaces a space with a dash' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 1 -Name 'Apply OS' | Should -BeExactly '001-Apply-OS.log'
        }
    }

    It 'replaces every character outside the safe set' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 3 -Name 'Apply OS (index 3)' | Should -BeExactly '003-Apply-OS-index-3.log'
        }
    }

    It 'keeps a dot, an underscore and a dash' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 4 -Name 'Set_HDT.Var-1' | Should -BeExactly '004-Set_HDT.Var-1.log'
        }
    }

    It 'refuses a path separator' {
        InModuleScope Hephaestus {
            # A step named 'A\B' must not produce a name that escapes the Steps
            # directory.
            Get-HDTStepLogName -Index 5 -Name 'A\B/C' | Should -BeExactly '005-A-B-C.log'
        }
    }

    It 'collapses repeated dashes' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 6 -Name 'A   ///   B' | Should -BeExactly '006-A-B.log'
        }
    }

    It 'trims a trailing dash' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 7 -Name 'Reboot!' | Should -BeExactly '007-Reboot.log'
        }
    }

    It 'trims a leading dash' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 8 -Name '(Optional) thing' | Should -BeExactly '008-Optional-thing.log'
        }
    }

    It 'truncates a very long name to forty characters' {
        InModuleScope Hephaestus {
            $name = 'A' * 120
            $result = Get-HDTStepLogName -Index 9 -Name $name

            $result | Should -BeExactly ('009-{0}.log' -f ('A' * 40))
        }
    }

    It 'ends in .log' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 1 -Name 'Anything' | Should -BeLike '*.log'
        }
    }

    It 'falls back for a name that sanitises to nothing' {
        InModuleScope Hephaestus {
            Get-HDTStepLogName -Index 2 -Name '!!!' | Should -BeExactly '002-step.log'
        }
    }

    It 'produces a distinct name for two steps with the same name' {
        InModuleScope Hephaestus {
            $first = Get-HDTStepLogName -Index 2 -Name 'Restart'
            $second = Get-HDTStepLogName -Index 9 -Name 'Restart'

            $first | Should -Not -BeExactly $second
        }
    }
}
