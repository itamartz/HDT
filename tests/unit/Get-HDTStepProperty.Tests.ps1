# The shared step-property reader (DESIGN 4.2).
#
# Five step types arrive in phase 04, and every one of them reads properties out
# of a YAML step the same way: by name, case-insensitively, with a default, with
# %Var% expansion, and coerced to the type the property means. Five copies of
# that would be five subtly different answers to "what does an absent property
# mean" - and the one that matters, "index: abc", would be reported five
# different ways.
#
# THE COERCION MESSAGE IS THE POINT. An authoring mistake must read
# "index: 'abc' is not a whole number on step 'Apply OS'", not
# "Cannot convert value "abc" to type "System.Int32"". The first sentence names
# the file the technician has to edit; the second names a type system.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTStepProperty' {

    BeforeAll {
        # A flattened step, as Import-HDTSequenceDocument produces one: the
        # property bag is an ordered, case-insensitive dictionary of every key
        # that is not a common step key.
        $script:newStep = {
            param([string] $Name, [System.Collections.IDictionary] $Property)

            $bag = $null
            if ($null -ne $Property) {
                $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
            }

            return [pscustomobject] @{ Index = 1; Name = $Name; Type = 'ApplyImage'; Property = $bag }
        }

        $script:newContext = {
            param([System.Collections.IDictionary] $Variable)

            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))
            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }
    }

    Context 'reading' {

        It 'returns a property by name' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = 'Win11-LTSC-2024' })

                Get-HDTStepProperty -Step $step -Name 'os' | Should -BeExactly 'Win11-LTSC-2024'
            }
        }

        It 'returns a property case-insensitively' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ minDiskGB = 60 })

                Get-HDTStepProperty -Step $step -Name 'mindiskgb' | Should -Be 60
            }
        }

        It 'returns the default when the property is absent' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = 'Win11' })

                Get-HDTStepProperty -Step $step -Name 'target' -Default 'primary' | Should -BeExactly 'primary'
            }
        }

        It 'returns the default for an empty string' {
            # 'target: ' in YAML is a key the author did not fill in, which is
            # the absent case rather than a request for the empty drive letter.
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ target = '   ' })

                Get-HDTStepProperty -Step $step -Name 'target' -Default 'primary' | Should -BeExactly 'primary'
            }
        }

        It 'returns null when there is no default' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = 'Win11' })

                Get-HDTStepProperty -Step $step -Name 'index' | Should -BeNullOrEmpty
            }
        }

        It 'tolerates a step whose Property dictionary is null' {
            # The step contract hands every type a minimal step, and a third
            # party's flattener may hand one with no bag at all.
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' $null

                Get-HDTStepProperty -Step $step -Name 'os' -Default 'fallback' | Should -BeExactly 'fallback'
            }
        }
    }

    Context 'expansion' {

        It 'expands a %Var% with -Expand' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep; NewContext = $script:newContext } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = '%HDTOSImage%' })
                $context = & $NewContext ([ordered] @{ HDTOSImage = 'Win11-LTSC-2024' })

                Get-HDTStepProperty -Step $step -Name 'os' -Context $context -Expand |
                    Should -BeExactly 'Win11-LTSC-2024'
            }
        }

        It 'does not expand without -Expand' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep; NewContext = $script:newContext } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = '%HDTOSImage%' })
                $context = & $NewContext ([ordered] @{ HDTOSImage = 'Win11-LTSC-2024' })

                Get-HDTStepProperty -Step $step -Name 'os' -Context $context | Should -BeExactly '%HDTOSImage%'
            }
        }

        It 'leaves an unresolved token literal' {
            # 02-03's rule: a token that silently became '' is how a machine ends
            # up named 'PC-'.
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep; NewContext = $script:newContext } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ os = '%HDTNeverGathered%' })
                $context = & $NewContext $null

                Get-HDTStepProperty -Step $step -Name 'os' -Context $context -Expand |
                    Should -BeExactly '%HDTNeverGathered%'
            }
        }

        It 'expands nothing when the value is not a string' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep; NewContext = $script:newContext } {
                $step = & $NewStep 'Validate' ([ordered] @{ minDiskGB = 60 })
                $context = & $NewContext $null

                Get-HDTStepProperty -Step $step -Name 'minDiskGB' -Context $context -Expand | Should -Be 60
            }
        }
    }

    Context 'coercion' {

        It 'coerces to an integer with -As Int' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ index = '2' })

                $value = Get-HDTStepProperty -Step $step -Name 'index' -As Int

                $value | Should -Be 2
                $value | Should -BeOfType ([int])
            }
        }

        It 'coerces to a long with -As Long' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Validate' ([ordered] @{ minDiskGB = '60' })

                $value = Get-HDTStepProperty -Step $step -Name 'minDiskGB' -As Long

                $value | Should -Be 60
                $value | Should -BeOfType ([long])
            }
        }

        It 'coerces to a bool with -As Bool' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Format and Partition' ([ordered] @{ wipe = $true })

                $value = Get-HDTStepProperty -Step $step -Name 'wipe' -As Bool

                $value | Should -BeTrue
                $value | Should -BeOfType ([bool])
            }
        }

        It 'accepts the string true for a bool' {
            # A rules.yaml value and an expanded %Var% both arrive as text.
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Format and Partition' ([ordered] @{ wipe = 'true' })

                Get-HDTStepProperty -Step $step -Name 'wipe' -As Bool | Should -BeTrue
            }
        }

        It 'accepts the string false for a bool' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                # [bool] 'false' is TRUE in PowerShell - any non-empty string is -
                # so a reader that cast rather than parsed would make
                # 'setBootOrder: false' mean true.
                $step = & $NewStep 'Prepare Boot' ([ordered] @{ setBootOrder = 'false' })

                Get-HDTStepProperty -Step $step -Name 'setBootOrder' -As Bool | Should -BeFalse
            }
        }

        It 'returns the default without coercing it when the property is absent' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Prepare Boot' $null

                Get-HDTStepProperty -Step $step -Name 'recovery' -Default $true -As Bool | Should -BeTrue
            }
        }

        It 'coerces to a string with -As String' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Format and Partition' ([ordered] @{ diskNumber = 1 })

                $value = Get-HDTStepProperty -Step $step -Name 'diskNumber' -As String

                $value | Should -BeExactly '1'
                $value | Should -BeOfType ([string])
            }
        }

        It 'throws HDTConfigurationError naming the step and the property for a value that will not convert' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ index = 'abc' })

                $record = $null
                try { Get-HDTStepProperty -Step $step -Name 'index' -As Int } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike "*index*"
                $record.Exception.Message | Should -BeLike "*abc*"
                $record.Exception.Message | Should -BeLike "*Apply OS*"
            }
        }

        It 'throws for a bool that is neither true nor false' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep } {
                $step = & $NewStep 'Format and Partition' ([ordered] @{ wipe = 'maybe' })

                $record = $null
                try { Get-HDTStepProperty -Step $step -Name 'wipe' -As Bool } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*maybe*'
            }
        }

        It 'coerces after expanding' {
            InModuleScope Hephaestus -Parameters @{ NewStep = $script:newStep; NewContext = $script:newContext } {
                $step = & $NewStep 'Apply OS' ([ordered] @{ index = '%HDTImageIndex%' })
                $context = & $NewContext ([ordered] @{ HDTImageIndex = 2 })

                Get-HDTStepProperty -Step $step -Name 'index' -Context $context -Expand -As Int | Should -Be 2
            }
        }
    }
}
