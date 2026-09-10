#requires -Version 5.1

# Assert-HDTBootLoaderServicingLevel - the guard that stops the Secure Boot
# bootloader swap producing media that does not boot.
#
# WHY IT EXISTS, MEASURED ON HARDWARE AND NOT INFERRED (SPIKES S20.2). Three
# Generation 2 Hyper-V runs on 2026-09-07:
#
#   swapped media (boot manager SVN 9.0), Secure Boot ON   FAIL  0xc0430001
#   swapped media (the same ISO),         Secure Boot OFF  PASS  WinPE reached
#   unswapped ADK media (SVN 3.0),        Secure Boot ON   PASS  WinPE reached
#
# 0xc0430001 is STATUS_SECUREBOOT_ROLLBACK_DETECTED, and the screen is Windows
# Boot Manager's recovery screen rather than the firmware's Security Violation.
# The firmware ACCEPTED the swapped boot manager. The boot manager then refused
# the next stage: the built boot.wim's winload.efi is 10.0.26100.1 while the
# swapped boot manager is 10.0.28000.342. winload.efi carries no
# BOOTMGRSECURITYVERSIONNUMBER resource at all, so this is not the SVN floor the
# swap exists to clear - it is the boot manager's own rollback check on the OS
# loader, gated on Secure Boot, which is exactly why the same media booted with
# Secure Boot off.
#
# So the swap as first shipped turned WORKING Secure Boot media into
# non-booting media, silently. This function is the refusal that makes that
# impossible, and it is pure so the whole decision is provable with nothing
# mounted (CLAUDE.md rule 5).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The measured pair. The boot manager is this laptop's own
    # C:\Windows\Boot\EFI copy; the OS loader is what the ADK's WinPE image
    # carries and what the failing run actually held.
    $script:patchedBootManager = '10.0.28000.342'
    $script:adkOsLoader = '10.0.26100.1'

    $script:osLoaderPath = 'C:\HDTLab\scratch\bootimage\mount\Windows\System32\Boot\winload.efi'

    function New-HDTBootLoaderTestRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test row; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [string] $Version = '10.0.28000.342'
        )

        # The shape Get-HDTBootLoaderSource returns, both rows, because the
        # refusal is written against the SET and a swap replaces two files.
        return @(
            [pscustomobject] @{ Name = 'bootmgr.efi'; Source = 'C:\Windows\Boot\EFI\bootmgr.efi'
                Destination = 'bootmgr.efi'; Version = $Version
            }
            [pscustomobject] @{ Name = 'bootmgfw.efi'; Source = 'C:\Windows\Boot\EFI\bootmgfw.efi'
                Destination = 'EFI\Boot\bootx64.efi'; Version = $Version
            }
        )
    }

    function Get-HDTBootLoaderTestRefusal {
        [CmdletBinding()]
        param(
            [Parameter()]
            [object[]] $Row,

            [Parameter()]
            [string] $OsLoaderVersion
        )

        return (InModuleScope Hephaestus -Parameters @{
                Row             = $Row
                OsLoaderVersion = $OsLoaderVersion
                OsLoaderPath    = $script:osLoaderPath
            } {
                param($Row, $OsLoaderVersion, $OsLoaderPath)

                try {
                    Assert-HDTBootLoaderServicingLevel -BootLoaderRow $Row `
                        -OsLoaderVersion $OsLoaderVersion -OsLoaderPath $OsLoaderPath
                    return ''
                } catch {
                    return [string] $_.Exception.Message
                }
            })
    }
}

Describe 'Assert-HDTBootLoaderServicingLevel' {

    Context 'the pair that was measured failing on hardware' {

        BeforeAll {
            $script:refusal = Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion $script:adkOsLoader
        }

        It 'refuses a 28000-series boot manager over a 26100-series OS loader' {
            # THE WHOLE POINT. This exact pair produced 0xc0430001 on a Gen 2 VM
            # with Secure Boot on, and produced it AFTER the media looked built,
            # burned and green.
            $script:refusal | Should -Not -BeNullOrEmpty
        }

        It 'names both versions, so the reader can see which two levels disagree' {
            $script:refusal | Should -Match ([regex]::Escape($script:patchedBootManager))
            $script:refusal | Should -Match ([regex]::Escape($script:adkOsLoader))
        }

        It 'names the cause - a rollback check on the OS loader - and not the symptom' {
            # THE SYMPTOM IS A RECOVERY SCREEN. The cause is that a boot manager
            # will not hand control to an OS loader from an older servicing
            # level while Secure Boot is on. A message naming only "the media
            # does not boot" sends the reader back to the SVN floor, which is a
            # different mechanism and is not what refused this.
            $script:refusal | Should -Match 'rollback'
            $script:refusal | Should -Match 'winload\.efi'
        }

        It 'carries the status code the screen does not show' {
            # 0xc0430001 is in the recovery screen's small print and nowhere
            # else. An administrator who has it can search for it; one who has
            # "your PC needs to be repaired" cannot.
            $script:refusal | Should -Match '0xc0430001'
        }

        It 'says this is NOT the SVN floor, which is the wrong trail to follow' {
            # The firmware ACCEPTED the swapped loader. Everything else this
            # repository has written about Secure Boot is about the SVN floor,
            # so the one message that is about something else has to say so.
            $script:refusal | Should -Match 'SVN'
        }

        It 'names the remedy: service the image, or build without the swap' {
            $script:refusal | Should -Match 'BootLoaderPath'
        }
    }

    Context 'pairs that are not a rollback' {

        It 'accepts an OS loader from the same servicing level' {
            # The real fix, when it lands: a serviced WinPE whose winload.efi
            # comes up to the boot manager's build. This function must not stand
            # in its way.
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow -Version '10.0.28000.342') `
                -OsLoaderVersion '10.0.28000.342' | Should -BeNullOrEmpty
        }

        It 'accepts an OS loader newer than the boot manager' {
            # Not a rollback. The check the boot manager performs is on an OS
            # loader BELOW its own level; refusing above it would be this
            # function inventing a rule nobody measured.
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow -Version '10.0.28000.342') `
                -OsLoaderVersion '10.0.28100.9' | Should -BeNullOrEmpty
        }

        It 'ignores the revision, which was never the discriminator' {
            # 28000.342 against 28000.100 is one servicing level, and nothing
            # measured says a revision gap refuses. Claiming to check something
            # that was not measured is the trap Get-HDTBootLoaderSource already
            # names about the SVN.
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow -Version '10.0.28000.342') `
                -OsLoaderVersion '10.0.28000.100' | Should -BeNullOrEmpty
        }

        It 'does nothing when no swap was asked for' {
            # OPT-IN, END TO END. No rows means no replacement boot manager,
            # which means the ADK's own matched pair - the control run, which
            # PASSED with Secure Boot on.
            Get-HDTBootLoaderTestRefusal -Row @() -OsLoaderVersion $script:adkOsLoader |
                Should -BeNullOrEmpty
        }
    }

    Context 'a comparison that cannot be made' {

        It 'refuses an OS loader version it could not read' {
            # SILENCE IS THE FAILURE MODE THIS WHOLE FUNCTION EXISTS TO STOP. A
            # version of 0.0.0.0 is IFileSystem.GetVersion saying the file
            # carries no version resource, and a real winload.efi always does -
            # so it means the probe found the wrong file, not that the pair is
            # safe.
            $refusal = Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion '0.0.0.0'

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match ([regex]::Escape($script:osLoaderPath))
        }

        It 'refuses a boot manager version it could not read' {
            $refusal = Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow -Version '0.0.0.0') `
                -OsLoaderVersion $script:adkOsLoader

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match 'bootmgr\.efi'
        }

        It 'refuses a version that is not four numbers' {
            $refusal = Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion 'not a version'

            $refusal | Should -Not -BeNullOrEmpty
        }
    }

    Context 'every loader in the swap, not just the first' {

        It 'refuses when only the second loader is from another level' {
            # BOTH FILES OR NEITHER is already Get-HDTBootLoaderSource's rule for
            # what gets replaced. The same has to hold for what gets CHECKED, or
            # a mixed source folder passes on its first file.
            $row = @(
                [pscustomobject] @{ Name = 'bootmgr.efi'; Source = 'C:\Windows\Boot\EFI\bootmgr.efi'
                    Destination = 'bootmgr.efi'; Version = '10.0.26100.1'
                }
                [pscustomobject] @{ Name = 'bootmgfw.efi'; Source = 'C:\Windows\Boot\EFI\bootmgfw.efi'
                    Destination = 'EFI\Boot\bootx64.efi'; Version = '10.0.28000.342'
                }
            )

            $refusal = Get-HDTBootLoaderTestRefusal -Row $row -OsLoaderVersion '10.0.26100.1'

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match 'bootmgfw\.efi'
        }
    }
}
