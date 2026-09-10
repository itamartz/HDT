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
# the next stage: the built boot.wim's winload.efi was 10.0.26100.1 while the
# swapped boot manager was 10.0.28000.342.
#
# AND THE FIRST RULE WRITTEN FOR THAT WAS WRONG (SPIKES S20.3, 2026-09-10). It
# compared the BUILD of the boot manager against the BUILD of the OS loader and
# refused when the loader's was lower - which is a comparison across two
# different servicing tracks. Read off this build host on 2026-09-10:
#
#   C:\Windows\Boot\EFI\bootmgfw.efi        10.0.28000.342   SVN 9.0
#   C:\Windows\System32\Boot\winload.efi    10.0.26100.8655
#   Confirm-SecureBootUEFI                  True
#
# This machine boots that pair every day with Secure Boot on, so a boot manager
# plainly does NOT require an OS loader at its own build number. 28000 is the
# boot manager's track and 26100 is the OS's. The failing pair was 28000.342
# over 26100.1; the working pair is 28000.342 over 26100.8655. What separates
# them is the OS loader's own servicing level, not its distance from the boot
# manager's.
#
# SO THE RULE IS A SAME-TRACK COMPARISON: the winload.efi inside the image must
# be at or above the winload.efi of the serviced Windows the replacement boot
# managers came from. After Update-HDTBootImage's injection they are equal and
# this passes; if the replacement did not reach the image, this is what says so.
# Two versions from different tracks cannot be ordered at all, and being handed
# a pair like that is a defect in the caller.
#
# It is pure, so the whole decision is provable with nothing mounted
# (CLAUDE.md rule 5).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The measured versions. The boot manager and the serviced OS loader are
    # this build host's own C:\Windows copies, read on 2026-09-10; the ADK one
    # is what an unserviced WinPE carries and what the failing run held.
    $script:patchedBootManager = '10.0.28000.342'
    $script:servicedOsLoader = '10.0.26100.8655'
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
            [string] $OsLoaderVersion,

            # THE SERVICED WINDOWS'S OWN winload.efi - the one the boot managers
            # came off, and the only version the image's can be ordered against.
            [Parameter()]
            [string] $ReplacementOsLoaderVersion = '10.0.26100.8655'
        )

        return (InModuleScope Hephaestus -Parameters @{
                Row                        = $Row
                OsLoaderVersion            = $OsLoaderVersion
                ReplacementOsLoaderVersion = $ReplacementOsLoaderVersion
                OsLoaderPath               = $script:osLoaderPath
            } {
                param($Row, $OsLoaderVersion, $ReplacementOsLoaderVersion, $OsLoaderPath)

                try {
                    Assert-HDTBootLoaderServicingLevel -BootLoaderRow $Row `
                        -OsLoaderVersion $OsLoaderVersion -OsLoaderPath $OsLoaderPath `
                        -ReplacementOsLoaderVersion $ReplacementOsLoaderVersion
                    return ''
                } catch {
                    return [string] $_.Exception.Message
                }
            })
    }
}

Describe 'Assert-HDTBootLoaderServicingLevel' {

    Context 'the pair this build host boots every day' {

        It 'does not refuse a 28000-series boot manager over a 26100-series OS loader' {
            # THE FALSE REFUSAL, IN ONE TEST. The first rule compared BUILDS and
            # would have refused exactly this - and this is the pair the machine
            # running the test is booted from, Secure Boot on, right now
            # (10.0.28000.342 boot manager, 10.0.26100.8655 winload.efi,
            # Confirm-SecureBootUEFI True). A guard that refuses a configuration
            # Windows itself ships is a guard that stops the cure landing.
            Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion $script:servicedOsLoader `
                -ReplacementOsLoaderVersion $script:servicedOsLoader | Should -BeNullOrEmpty
        }
    }

    Context 'an image still carrying an OS loader older than its replacement' {

        BeforeAll {
            $script:refusal = Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion $script:adkOsLoader `
                -ReplacementOsLoaderVersion $script:servicedOsLoader
        }

        It 'refuses 10.0.26100.1 under a serviced 10.0.26100.8655' {
            # THE REAL DEFECT. 26100.1 is the ADK RTM loader the built image
            # carried on the run that failed on hardware; 26100.8655 is what the
            # serviced Windows the boot managers came from carries. Same track,
            # and the image is behind - so the injection did not reach it.
            $script:refusal | Should -Not -BeNullOrEmpty
        }

        It 'names both versions, so the reader can see which two levels disagree' {
            $script:refusal | Should -Match ([regex]::Escape($script:adkOsLoader))
            $script:refusal | Should -Match ([regex]::Escape($script:servicedOsLoader))
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

        It 'names the remedy as the injection, not as switching Secure Boot off' {
            # THE REMEDY MOVED. The swap now takes the OS loader off the SAME
            # serviced Windows as the boot managers and copies it into the
            # mounted image, so this refusal means that copy did not reach the
            # file. Telling an administrator to disable Secure Boot instead
            # would be telling them to give up the thing the swap exists for.
            $script:refusal | Should -Match ([regex]::Escape('System32\Boot'))
            $script:refusal | Should -Not -Match 'Secure Boot off'
        }
    }

    Context 'pairs that are not a rollback' {

        It 'accepts an OS loader at exactly the replacement level' {
            # WHAT THE INJECTION PRODUCES. Update-HDTBootImage copies the
            # serviced winload.efi in and re-reads it, so the normal outcome of
            # a successful swap is two identical versions here.
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow) `
                -OsLoaderVersion $script:servicedOsLoader `
                -ReplacementOsLoaderVersion $script:servicedOsLoader | Should -BeNullOrEmpty
        }

        It 'accepts an OS loader newer than the replacement' {
            # Not a rollback. The check the boot manager performs is on an OS
            # loader BELOW the level it expects; refusing one above it would be
            # this function inventing a rule nobody measured.
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow) `
                -OsLoaderVersion '10.0.26100.9999' `
                -ReplacementOsLoaderVersion $script:servicedOsLoader | Should -BeNullOrEmpty
        }

        It 'does nothing when no swap was asked for' {
            # OPT-IN, END TO END. No rows means no replacement boot manager,
            # which means the ADK's own matched pair - the control run, which
            # PASSED with Secure Boot on.
            Get-HDTBootLoaderTestRefusal -Row @() -OsLoaderVersion $script:adkOsLoader |
                Should -BeNullOrEmpty
        }
    }

    Context 'two versions that cannot be ordered at all' {

        BeforeAll {
            # The boot manager's own version handed in where the replacement OS
            # loader's belongs - which is what the first rule effectively did on
            # every call.
            $script:crossTrack = Get-HDTBootLoaderTestRefusal `
                -Row (New-HDTBootLoaderTestRow -Version $script:patchedBootManager) `
                -OsLoaderVersion $script:servicedOsLoader `
                -ReplacementOsLoaderVersion $script:patchedBootManager
        }

        It 'refuses to compare a 26100-series loader against a 28000-series one' {
            $script:crossTrack | Should -Not -BeNullOrEmpty
        }

        It 'says they are different servicing tracks' {
            $script:crossTrack | Should -Match 'servicing track'
        }

        It 'names it as a caller defect rather than something an administrator did' {
            # AN ADMINISTRATOR CANNOT FIX THIS ONE. Both versions reaching this
            # check come off ONE serviced Windows, so a pair from two tracks
            # means the code that assembled them is wrong.
            $script:crossTrack | Should -Match 'caller'
        }
    }

    Context 'a comparison that cannot be made' {

        It 'refuses an OS loader version it could not read' {
            # SILENCE IS THE FAILURE MODE THIS WHOLE FUNCTION EXISTS TO STOP. A
            # version of 0.0.0.0 is IFileSystem.GetVersion saying the file
            # carries no version resource, and a real winload.efi always does -
            # so it means the probe found the wrong file, not that the pair is
            # safe.
            $refusal = Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow) `
                -OsLoaderVersion '0.0.0.0'

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match ([regex]::Escape($script:osLoaderPath))
        }

        It 'refuses a replacement OS loader version it could not read' {
            # The serviced Windows's own winload.efi is the yardstick. Without a
            # readable one there is no comparison to make, and a swap that goes
            # ahead unchecked is the original defect.
            $refusal = Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow) `
                -OsLoaderVersion $script:servicedOsLoader -ReplacementOsLoaderVersion '0.0.0.0'

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match 'winload\.efi'
        }

        It 'refuses a boot manager version it could not read' {
            $refusal = Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow -Version '0.0.0.0') `
                -OsLoaderVersion $script:servicedOsLoader

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match 'bootmgr\.efi'
        }

        It 'refuses a version that is not four numbers' {
            Get-HDTBootLoaderTestRefusal -Row (New-HDTBootLoaderTestRow) `
                -OsLoaderVersion 'not a version' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'every loader in the swap, not just the first' {

        It 'refuses when only the second loader has an unreadable version' {
            # BOTH FILES OR NEITHER is already Get-HDTBootLoaderSource's rule for
            # what gets replaced. The same has to hold for what gets CHECKED, or
            # a mixed source folder passes on its first file.
            $row = @(
                [pscustomobject] @{ Name = 'bootmgr.efi'; Source = 'C:\Windows\Boot\EFI\bootmgr.efi'
                    Destination = 'bootmgr.efi'; Version = '10.0.28000.342'
                }
                [pscustomobject] @{ Name = 'bootmgfw.efi'; Source = 'C:\Windows\Boot\EFI\bootmgfw.efi'
                    Destination = 'EFI\Boot\bootx64.efi'; Version = '0.0.0.0'
                }
            )

            $refusal = Get-HDTBootLoaderTestRefusal -Row $row -OsLoaderVersion $script:servicedOsLoader

            $refusal | Should -Not -BeNullOrEmpty
            $refusal | Should -Match 'bootmgfw\.efi'
        }
    }
}
