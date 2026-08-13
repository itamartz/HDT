# Which layout a machine gets, and who decides.
#
# DESIGN 9.1: "the engine selects a layout by firmware unless the sequence pins
# one". Precedence, highest first:
#
#   1  the step's layout: property
#   2  the HDTDiskLayout variable  (DESIGN 3.2's HDT-specific addition)
#   3  firmware - HDTIsUEFI true means uefi-standard
#
# A MACHINE WHOSE FIRMWARE WAS NEVER GATHERED IS NOT A UEFI MACHINE BY DEFAULT.
# Absent HDTIsUEFI resolves to bios-standard WITH A WARNING, because the MBR
# layout is the one that fails visibly on UEFI hardware rather than the one that
# produces an unbootable GPT disk on a BIOS machine.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Resolve-HDTDiskLayoutName' {

    Context 'precedence' {

        It 'returns the layout the step pinned' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{} -Layout 'bios-standard' |
                    Should -BeExactly 'bios-standard'
            }
        }

        It 'prefers the pinned layout over the variable' {
            InModuleScope Hephaestus {
                $variable = @{ HDTDiskLayout = 'uefi-standard' }

                Resolve-HDTDiskLayoutName -Variable $variable -Layout 'bios-standard' |
                    Should -BeExactly 'bios-standard'
            }
        }

        It 'prefers the pinned layout over the firmware' {
            InModuleScope Hephaestus {
                $variable = @{ HDTIsUEFI = $true }

                Resolve-HDTDiskLayoutName -Variable $variable -Layout 'bios-standard' |
                    Should -BeExactly 'bios-standard'
            }
        }

        It 'returns the HDTDiskLayout variable when the step pins nothing' {
            InModuleScope Hephaestus {
                $variable = @{ HDTDiskLayout = 'bios-standard'; HDTIsUEFI = $true }

                Resolve-HDTDiskLayoutName -Variable $variable | Should -BeExactly 'bios-standard'
            }
        }

        It 'ignores an empty pinned layout and falls through' {
            InModuleScope Hephaestus {
                $variable = @{ HDTIsUEFI = $true }

                Resolve-HDTDiskLayoutName -Variable $variable -Layout '' | Should -BeExactly 'uefi-standard'
            }
        }
    }

    Context 'firmware' {

        It 'returns uefi-standard when HDTIsUEFI is true' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{ HDTIsUEFI = $true } | Should -BeExactly 'uefi-standard'
            }
        }

        It 'returns bios-standard when HDTIsUEFI is false' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{ HDTIsUEFI = $false } | Should -BeExactly 'bios-standard'
            }
        }

        It 'returns bios-standard when HDTIsUEFI is missing' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{} -WarningAction SilentlyContinue |
                    Should -BeExactly 'bios-standard'
            }
        }

        It 'warns when HDTIsUEFI is missing' {
            InModuleScope Hephaestus {
                $warning = @()
                $null = Resolve-HDTDiskLayoutName -Variable @{} -WarningVariable warning -WarningAction SilentlyContinue

                @($warning).Count | Should -BeGreaterThan 0
                [string] $warning | Should -BeLike '*HDTIsUEFI*'
            }
        }

        It 'accepts the string True for HDTIsUEFI' {
            InModuleScope Hephaestus {
                # The variable dictionary carries whatever the rules produced, and
                # a rules.yaml value arrives as text.
                Resolve-HDTDiskLayoutName -Variable @{ HDTIsUEFI = 'True' } | Should -BeExactly 'uefi-standard'
            }
        }

        It 'accepts the string False for HDTIsUEFI' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{ HDTIsUEFI = 'False' } | Should -BeExactly 'bios-standard'
            }
        }

        It 'looks the firmware variable up case-insensitively' {
            InModuleScope Hephaestus {
                $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $variable['hdtisuefi'] = $true

                Resolve-HDTDiskLayoutName -Variable $variable | Should -BeExactly 'uefi-standard'
            }
        }
    }

    Context 'expansion' {

        It 'expands a %Var% in the pinned name' {
            InModuleScope Hephaestus {
                # The sample sequence pins layout: "%HDTDiskLayout%".
                $variable = @{ HDTDiskLayout = 'uefi-standard' }

                Resolve-HDTDiskLayoutName -Variable $variable -Layout '%HDTDiskLayout%' |
                    Should -BeExactly 'uefi-standard'
            }
        }

        It 'falls through when a %Var% in the pinned name resolves to nothing' {
            InModuleScope Hephaestus {
                $variable = @{ HDTIsUEFI = $true }

                Resolve-HDTDiskLayoutName -Variable $variable -Layout '%HDTDiskLayout%' -WarningAction SilentlyContinue |
                    Should -BeExactly 'uefi-standard'
            }
        }
    }

    Context 'a pinned name no layout defines' {

        It 'throws HDTConfigurationError' {
            InModuleScope Hephaestus {
                $record = $null
                try { Resolve-HDTDiskLayoutName -Variable @{} -Layout 'uefi-contoso' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'lists the names that exist' {
            InModuleScope Hephaestus {
                $record = $null
                try { Resolve-HDTDiskLayoutName -Variable @{} -Layout 'uefi-contoso' } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*uefi-standard*'
                $record.Exception.Message | Should -BeLike '*bios-standard*'
            }
        }

        It 'throws for an HDTDiskLayout variable no layout defines' {
            InModuleScope Hephaestus {
                $record = $null
                try { Resolve-HDTDiskLayoutName -Variable @{ HDTDiskLayout = 'uefi-contoso' } } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'accepts a name a supplied definition adds' {
            InModuleScope Hephaestus {
                $definition = @{
                    'contoso-single' = @{
                        PartitionStyle = 'GPT'
                        Partition      = @(
                            @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                        )
                    }
                }

                Resolve-HDTDiskLayoutName -Variable @{} -Layout 'contoso-single' -Definition $definition |
                    Should -BeExactly 'contoso-single'
            }
        }
    }

    Context 'the name it returns' {

        It 'returns the canonical casing of the layout, not what was typed' {
            InModuleScope Hephaestus {
                Resolve-HDTDiskLayoutName -Variable @{} -Layout 'UEFI-Standard' | Should -BeExactly 'uefi-standard'
            }
        }

        It 'returns a name Get-HDTDiskLayout accepts' {
            InModuleScope Hephaestus {
                $name = Resolve-HDTDiskLayoutName -Variable @{ HDTIsUEFI = $true }

                (Get-HDTDiskLayout -Name $name).Name | Should -BeExactly $name
            }
        }
    }
}
