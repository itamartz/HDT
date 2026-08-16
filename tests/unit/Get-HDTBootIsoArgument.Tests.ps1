# The oscdimg argument list, and the place SPIKES S2 lives.
#
# S2, verbatim and load-bearing: -bootdata: CANNOT TAKE A QUOTED PATH, and the
# ADK lives under 'C:\Program Files (x86)\...', which has spaces. Passing a
# quoted path from PowerShell produces doubled quotes and oscdimg answers
#
#   ERROR: Could not open boot sector file ""C:\Program Files (x86)\...\etfsboot.com""
#   Error 123: The filename, directory name, or volume label syntax is incorrect.
#
# The verified fix is to stage the boot bits into a space-free directory first
# and build the argument with unquoted paths. So this function REFUSES a boot bit
# path containing a space rather than building an argument that is known not to
# work: the refusal is the only thing that keeps the staging from being quietly
# skipped by a future caller.
#
# It is pure, and it is private, so every assertion runs inside InModuleScope and
# every one of the six firmware/no-prompt combinations is asserted as an EXACT
# string rather than by pattern.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:bits = 'C:\HDTBootBits'
}

Describe 'Get-HDTBootIsoArgument' {

    Context 'the six combinations' {

        # The table in 05-04's <engine_semantics>, one row each. The two forms
        # that worked in SPIKES S2 are rows 1 and 5.
        $script:HDTBootDataCase = @(
            @{ Firmware = 'UEFI'; NoPrompt = $true; Expected = '-bootdata:1#pEF,e,bC:\HDTBootBits\efisys_noprompt.bin' }
            @{ Firmware = 'UEFI'; NoPrompt = $false; Expected = '-bootdata:1#pEF,e,bC:\HDTBootBits\efisys.bin' }
            @{ Firmware = 'BIOS'; NoPrompt = $true; Expected = '-bootdata:1#p0,e,bC:\HDTBootBits\etfsboot.com' }
            @{ Firmware = 'BIOS'; NoPrompt = $false; Expected = '-bootdata:1#p0,e,bC:\HDTBootBits\etfsboot.com' }
            @{ Firmware = 'Both'; NoPrompt = $true; Expected = '-bootdata:2#p0,e,bC:\HDTBootBits\etfsboot.com#pEF,e,bC:\HDTBootBits\efisys_noprompt.bin' }
            @{ Firmware = 'Both'; NoPrompt = $false; Expected = '-bootdata:2#p0,e,bC:\HDTBootBits\etfsboot.com#pEF,e,bC:\HDTBootBits\efisys.bin' }
        )

        It 'builds <Expected> for <Firmware> with NoPromptForKey <NoPrompt>' -ForEach $script:HDTBootDataCase {
            $expected = $Expected
            $argument = InModuleScope Hephaestus -Parameters @{ Firmware = $Firmware; NoPrompt = $NoPrompt } {
                param($Firmware, $NoPrompt)
                Get-HDTBootIsoArgument -Firmware $Firmware -NoPromptForKey:$NoPrompt `
                    -BootBitPath 'C:\HDTBootBits' -WarningAction SilentlyContinue
            }

            @($argument) | Should -Contain $expected
        }

        It 'emits exactly one bootdata element for <Firmware> with NoPromptForKey <NoPrompt>' -ForEach $script:HDTBootDataCase {
            $argument = InModuleScope Hephaestus -Parameters @{ Firmware = $Firmware; NoPrompt = $NoPrompt } {
                param($Firmware, $NoPrompt)
                Get-HDTBootIsoArgument -Firmware $Firmware -NoPromptForKey:$NoPrompt `
                    -BootBitPath 'C:\HDTBootBits' -WarningAction SilentlyContinue
            }

            @($argument | Where-Object { $_ -like '-bootdata:*' }).Count | Should -Be 1
        }
    }

    Context 'the fixed head' {

        BeforeEach {
            $script:argument = @(InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -NoPromptForKey -BootBitPath 'C:\HDTBootBits'
                })
        }

        It 'always passes -m -o -u2 -udfver102' {
            # The four SPIKES S2 verified at 100% completion, in that order.
            @($script:argument[0..3]) | Should -Be @('-m', '-o', '-u2', '-udfver102')
        }

        It 'returns a string array' {
            $script:argument -is [System.Array] | Should -BeTrue
            $script:argument[0] | Should -BeOfType ([string])
        }

        It 'quotes nothing inside -bootdata' {
            # SPIKES S2. A single quote character anywhere in this element is the
            # defect that produced 'Could not open boot sector file ""C:\Program
            # Files (x86)\...""' and Error 123.
            $bootdata = @($script:argument | Where-Object { $_ -like '-bootdata:*' })[0]

            $bootdata | Should -Not -BeLike '*"*'
            $bootdata | Should -Not -BeLike "*'*"
        }

        It 'quotes nothing in any element' {
            foreach ($item in $script:argument) {
                $item | Should -Not -BeLike '*"*'
            }
        }

        It 'puts bootdata last' {
            $script:argument[-1] | Should -BeLike '-bootdata:*'
        }
    }

    Context 'the label' {

        It 'adds -l with the label, uppercased' {
            $argument = @(InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\HDTBootBits' -Label 'HDTPE_x64'
                })

            $argument | Should -Contain '-lHDTPE_X64'
        }

        It 'defaults the label to HDTPE_X64' {
            $argument = @(InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\HDTBootBits'
                })

            $argument | Should -Contain '-lHDTPE_X64'
        }

        It 'refuses a label with a space' {
            # An ISO volume label with a space is its own class of trouble, and
            # oscdimg takes the label as one unquoted token.
            $record = $null
            try {
                InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\HDTBootBits' -Label 'HDT PE'
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*label*'
        }

        It 'omits -l for an empty label' {
            $argument = @(InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\HDTBootBits' -Label ''
                })

            @($argument | Where-Object { $_ -like '-l*' }).Count | Should -Be 0
        }
    }

    Context 'the SPIKES S2 refusal' {

        It 'refuses a boot bit path containing a space' {
            $record = $null
            try {
                InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -NoPromptForKey `
                        -BootBitPath 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg'
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'explains the cause in the refusal' {
            # The message has to say WHY, or the next person "fixes" it by adding
            # quotes, which is precisely what does not work. It names the oscdimg
            # argument rather than the lab note (SPIKES S2) that found it: the
            # administrator reading this has oscdimg, not our SPIKES.md.
            $record = $null
            try {
                InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\Program Files\bits'
                }
            } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*-bootdata*'
            $record.Exception.Message | Should -BeLike '*boot sector file*'
        }

        It 'accepts a space-free path' {
            { InModuleScope Hephaestus {
                    Get-HDTBootIsoArgument -Firmware UEFI -BootBitPath 'C:\HDTLab\scratch\bootimage\work\bootbits'
                } } | Should -Not -Throw
        }
    }

    Context 'the warning DESIGN 5.2 requires' {

        It 'warns for BIOS with -NoPromptForKey' {
            $warning = @()
            InModuleScope Hephaestus {
                Get-HDTBootIsoArgument -Firmware BIOS -NoPromptForKey -BootBitPath 'C:\HDTBootBits'
            } -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            @($warning).Count | Should -Be 1
            [string] $warning[0] | Should -BeLike '*etfsboot.com carries*'
            [string] $warning[0] | Should -BeLike '*no no-prompt variant*'
            [string] $warning[0] | Should -BeLike '*will prompt when booted on BIOS firmware*'
        }

        It 'warns for Both with -NoPromptForKey, naming the BIOS leg only' {
            $warning = @()
            InModuleScope Hephaestus {
                Get-HDTBootIsoArgument -Firmware Both -NoPromptForKey -BootBitPath 'C:\HDTBootBits'
            } -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            @($warning).Count | Should -Be 1
            [string] $warning[0] | Should -BeLike '*BIOS leg only*'
            [string] $warning[0] | Should -BeLike '*UEFI leg will not prompt*'
        }

        It 'does not warn for UEFI with -NoPromptForKey' {
            $warning = @()
            InModuleScope Hephaestus {
                Get-HDTBootIsoArgument -Firmware UEFI -NoPromptForKey -BootBitPath 'C:\HDTBootBits'
            } -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            @($warning).Count | Should -Be 0
        }

        It 'does not warn for BIOS without -NoPromptForKey' {
            $warning = @()
            InModuleScope Hephaestus {
                Get-HDTBootIsoArgument -Firmware BIOS -BootBitPath 'C:\HDTBootBits'
            } -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            @($warning).Count | Should -Be 0
        }

        It 'does not warn for Both without -NoPromptForKey' {
            $warning = @()
            InModuleScope Hephaestus {
                Get-HDTBootIsoArgument -Firmware Both -BootBitPath 'C:\HDTBootBits'
            } -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            @($warning).Count | Should -Be 0
        }
    }

    It 'is private to the module' {
        # Both halves: "not exported" alone would pass for a function that does
        # not exist at all (README section 12).
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTBootIsoArgument' -ErrorAction SilentlyContinue
        } | Should -Not -BeNullOrEmpty

        Get-Command -Name 'Get-HDTBootIsoArgument' -Module Hephaestus -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}
