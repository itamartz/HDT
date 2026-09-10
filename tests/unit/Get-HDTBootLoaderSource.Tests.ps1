#requires -Version 5.1

# Get-HDTBootLoaderSource - WHICH bootloader files a Secure Boot swap replaces,
# and from where. Pure decision, no copy: the caller hands the rows to
# IFileSystem.CopyItem.
#
# WHY THE SWAP EXISTS AT ALL, measured rather than assumed (SPIKES S20, and the
# numbers re-read on 2026-09-07 by walking each PE's resource directory for the
# 4-byte RT_RCDATA resource named BOOTMGRSECURITYVERSIONNUMBER - the same value
# Rufus reads, high word major, low word minor):
#
#   ADK WinPE Media\bootmgr.efi              10.0.26100.1085   SVN 3.0
#   ADK WinPE Media\EFI\Boot\bootx64.efi     10.0.26100.1085   SVN 3.0
#   Win11-LTSC-2024 install media, both      10.0.26100.1041   SVN 3.0
#   WS2025-Std install media, both           10.0.26100.1041   SVN 3.0
#   C:\Windows\Boot\EFI\bootmgr.efi          10.0.28000.342    SVN 9.0
#   C:\Windows\Boot\EFI\bootmgfw.efi         10.0.28000.342    SVN 9.0
#
# The enforced floor is 7.0, so ONLY a fully patched Windows's own
# %SystemRoot%\Boot\EFI clears it - the install media does NOT, which is the
# first place anyone reaches for and the wrong one.
#
# TWO FILES IN, FOUR NAMES OUT. The source folder holds bootmgr.efi and
# bootmgfw.efi; every destination name in either target is one of those two
# under another name, so the required SET is two and the assertions below are
# written against the set rather than against one name.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:loaderRoot = 'C:\PatchedBoot\EFI'

    function New-HDTBootLoaderTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyCollection()]
            [string[]] $Leaf = @('bootmgr.efi', 'bootmgfw.efi')
        )

        $seed = @{}
        $version = @{}

        foreach ($name in @($Leaf)) {
            $seed[($script:loaderRoot + '\' + $name)] = 'MZ patched loader'
            $version[($script:loaderRoot + '\' + $name)] = '10.0.28000.342'
        }

        return (New-HDTFakeFileSystem -File $seed -Version $version)
    }
}

Describe 'Get-HDTBootLoaderSource' {

    Context 'the boot image media tree' {

        BeforeAll {
            $script:mediaRow = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem)
            } {
                param($LoaderRoot, $FileSystem)

                @(Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Media -FileSystem $FileSystem)
            }
        }

        It 'replaces exactly the two loaders a Secure Boot machine reads' {
            # THE SET, NOT ONE NAME (CLAUDE.md rule 8). Rufus flagged BOTH
            # /bootmgr.efi and /EFI/Boot/bootx64.efi; one replaced loader out of
            # two is still a machine that shows Security Violation.
            @($script:mediaRow).Count | Should -Be 2

            $destination = @($script:mediaRow | ForEach-Object { [string] $_.Destination })
            $destination | Should -Be @('bootmgr.efi', 'EFI\Boot\bootx64.efi')
        }

        It 'takes the media boot manager from the folder''s bootmgr.efi' {
            $row = @($script:mediaRow | Where-Object { [string] $_.Destination -eq 'bootmgr.efi' })

            [string] $row[0].Source | Should -BeExactly ($script:loaderRoot + '\bootmgr.efi')
        }

        It 'takes EFI\Boot\bootx64.efi from the folder''s bootmgfw.efi' {
            # NOT FROM bootmgr.efi, AND THE TWO ARE DIFFERENT BINARIES.
            # EFI\Boot\bootx64.efi is the FIRMWARE boot manager under the
            # removable-media name, which on a patched Windows is bootmgfw.efi;
            # bootmgr.efi is the one the BIOS bootmgr chains to. Their .text
            # sections differ by ~16 KB, so this is not a rename of one file.
            $row = @($script:mediaRow | Where-Object { [string] $_.Destination -eq 'EFI\Boot\bootx64.efi' })

            [string] $row[0].Source | Should -BeExactly ($script:loaderRoot + '\bootmgfw.efi')
        }

        It 'reports the version of what it is about to copy in' {
            # The log has to be able to say "10.0.28000.342 replaces
            # 10.0.26100.1085" - an administrator reading a firmware refusal a
            # week later cannot open the image to find out.
            foreach ($row in @($script:mediaRow)) {
                [string] $row.Version | Should -BeExactly '10.0.28000.342'
            }
        }
    }

    Context 'the PXE payload' {

        BeforeAll {
            $script:pxeRow = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem)
            } {
                param($LoaderRoot, $FileSystem)

                @(Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Pxe -FileSystem $FileSystem)
            }
        }

        It 'replaces both of the PXE tree''s UEFI loaders' {
            # BOTH PATHS OR NEITHER (ROADMAP M4). A corrected ISO with an
            # uncorrected TFTP root leaves WDS serving the refused loader, and
            # the two are the same product to the person whose machine will not
            # start.
            $destination = @($script:pxeRow | ForEach-Object { [string] $_.Destination })

            $destination | Should -Be @('Boot\x64\bootmgfw.efi', 'Boot\x64\wdsmgfw.efi')
        }

        It 'keeps Get-HDTPxePayloadRow''s source pairing' {
            # The payload table stages bootmgfw.efi FROM the ADK's bootmgr.efi
            # and wdsmgfw.efi FROM the ADK's EFI\Boot\bootx64.efi. The swap
            # substitutes the SOURCE of each row, so the pairing has to match or
            # the two files quietly change places.
            $source = @($script:pxeRow | ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Source) })

            $source | Should -Be @('bootmgr.efi', 'bootmgfw.efi')
        }

        It 'uses the arm64 folder when the architecture says so' {
            $row = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem)
            } {
                param($LoaderRoot, $FileSystem)

                @(Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Pxe -Architecture arm64 -FileSystem $FileSystem)
            }

            @($row | ForEach-Object { [string] $_.Destination }) |
                Should -Be @('Boot\arm64\bootmgfw.efi', 'Boot\arm64\wdsmgfw.efi')
        }
    }

    Context 'a folder that cannot do the job' {

        It 'refuses when a loader is missing, and names the file and the folder' {
            # AN INCOMPLETE SWAP IS WORSE THAN NONE, so one missing file refuses
            # the whole thing rather than replacing what it can.
            $refusal = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem -Leaf @('bootmgr.efi'))
            } {
                param($LoaderRoot, $FileSystem)

                try {
                    $null = Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Media -FileSystem $FileSystem
                    return ''
                } catch {
                    return [string] $_.Exception.Message
                }
            }

            $refusal | Should -Match 'bootmgfw\.efi'
            $refusal | Should -Match ([regex]::Escape($script:loaderRoot))
        }

        It 'names the cause and not the symptom' {
            # "Could not find file" is the symptom. The cause is the Secure Boot
            # SVN floor, and the message has to carry it plus the one folder on
            # a patched Windows that satisfies it - otherwise the reader goes
            # to the install media, which is 44 builds BEHIND the ADK.
            $refusal = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem -Leaf @())
            } {
                param($LoaderRoot, $FileSystem)

                try {
                    $null = Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Media -FileSystem $FileSystem
                    return ''
                } catch {
                    return [string] $_.Exception.Message
                }
            }

            $refusal | Should -Match 'Secure Boot'
            $refusal | Should -Match 'Boot\\EFI'
            $refusal | Should -Not -Match 'Could not find file'
        }

        It 'lists every missing loader, not just the first' {
            $refusal = InModuleScope Hephaestus -Parameters @{
                LoaderRoot = $script:loaderRoot
                FileSystem = (New-HDTBootLoaderTestFileSystem -Leaf @())
            } {
                param($LoaderRoot, $FileSystem)

                try {
                    $null = Get-HDTBootLoaderSource -BootLoaderPath $LoaderRoot -Target Pxe -FileSystem $FileSystem
                    return ''
                } catch {
                    return [string] $_.Exception.Message
                }
            }

            $refusal | Should -Match 'bootmgr\.efi'
            $refusal | Should -Match 'bootmgfw\.efi'
        }
    }
}
