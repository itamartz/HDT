# THE PATHS AND THE IDENTIFIERS BEHIND THE FullOS -> WinPE REBOOT, AS ONE PURE
# FUNCTION.
#
# Get-HDTLocalWinPePlan composes every string Invoke-HDTBootToWinPEStep hands to
# the adapter: where the boot image is read from, where it is staged, what the
# BCD ramdisk device looks like, which loader the entry names, and which store
# bcdedit writes to. It touches nothing - no disk, no bcdedit, no share - so the
# whole transport is provable here in milliseconds, and the adapter stays the
# branch-free thing CLAUDE.md rule 1 requires it to be.
#
# EVERY DECISION IN THE TRANSPORT LIVES HERE, WHICH IS THE POINT. winload.efi
# versus winload.exe, \EFI\Microsoft\Boot\BCD versus \Boot\BCD, boot.sdi out of
# the DVD\EFI tree versus DVD\PCAT - each of those is a branch, and a branch in
# an untested adapter is a branch nobody has ever executed.
#
# It is private, so every call runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A scriptblock rather than a function: every .ps1 under tests/ is covered by
    # the naming contract, and a helper here would have to be a Verb-HDTNoun
    # command for no gain.
    $script:plan = {
        param([hashtable] $Argument)

        return InModuleScope Hephaestus -Parameters @{ Argument = $Argument } {
            param($Argument)
            Get-HDTLocalWinPePlan @Argument
        }
    }

    $script:uefiArgument = @{
        Volume       = 'C'
        DeployRoot   = '\\LAP\HDTShare'
        SystemRoot   = 'C:\Windows'
        Firmware     = 'UEFI'
        SystemVolume = 'S'
    }
}

Describe 'Get-HDTLocalWinPePlan' {

    Context 'where the WinPE comes from' {

        It 'reads the boot image out of the share Boot folder' {
            (& $script:plan $script:uefiArgument).SourceWimPath |
                Should -BeExactly '\\LAP\HDTShare\Boot\HDTPE_x64.wim'
        }

        It 'names the boot image the workspace convention names' {
            $plan = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                Firmware = 'UEFI'; SystemVolume = 'S'; BootImageName = 'HDTPE_wiz_x64'
            }

            $plan.SourceWimPath | Should -BeExactly 'Z:\Share\Boot\HDTPE_wiz_x64.wim'
        }

        # boot.sdi comes from THE RUNNING WINDOWS, not the ADK and not the share.
        # Every Windows installation carries one, it is version-matched to the
        # boot manager that will read it, and taking it from the OS means the
        # transport needs no extra file on the share and no ADK on the client.
        It 'takes boot.sdi from the running Windows EFI tree under UEFI' {
            (& $script:plan $script:uefiArgument).SourceSdiPath |
                Should -BeExactly 'C:\Windows\Boot\DVD\EFI\boot.sdi'
        }

        It 'takes boot.sdi from the PCAT tree under BIOS' {
            $plan = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                Firmware = 'BIOS'; SystemVolume = 'S'
            }

            $plan.SourceSdiPath | Should -BeExactly 'C:\Windows\Boot\DVD\PCAT\boot.sdi'
        }
    }

    Context 'where it is staged' {

        # UNDER \HDT, AND THAT IS THE ENTIRE REASON THE CAPTURE STAYS CLEAN.
        # Templates\Capture\wimscript.ini already excludes \HDT as a tree, so a
        # WinPE staged there cannot travel inside a captured image. Staging
        # anywhere else would need a second entry in that file, and the two
        # would eventually disagree.
        It 'stages the boot image inside the HDT tree the capture already excludes' {
            (& $script:plan $script:uefiArgument).WimPath | Should -BeExactly 'C:\HDT\Boot\boot.wim'
        }

        It 'stages boot.sdi beside it' {
            (& $script:plan $script:uefiArgument).SdiPath | Should -BeExactly 'C:\HDT\Boot\boot.sdi'
        }

        It 'names the directory both files go in' {
            (& $script:plan $script:uefiArgument).StageDirectory | Should -BeExactly 'C:\HDT\Boot'
        }

        It 'accepts a volume written as a letter, a letter and colon, or a root' {
            foreach ($written in @('C', 'C:', 'C:\')) {
                $plan = & $script:plan @{
                    Volume = $written; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                    Firmware = 'UEFI'; SystemVolume = 'S'
                }

                $plan.WimPath | Should -BeExactly 'C:\HDT\Boot\boot.wim'
            }
        }
    }

    Context 'the BCD entry' {

        # A FIXED GUID, AS MDT USES ONE. Teardown has to be able to name the
        # entry without having kept a note across a reboot, and re-arming has to
        # replace the previous entry rather than accumulate a new one per run.
        It 'uses one fixed entry id' {
            (& $script:plan $script:uefiArgument).EntryId |
                Should -Match '^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$'
        }

        It 'gives the same id every time, so teardown can name it' {
            $first = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\A'; SystemRoot = 'C:\Windows'; Firmware = 'UEFI'; SystemVolume = 'S'
            }
            $second = & $script:plan @{
                Volume = 'D'; DeployRoot = 'Y:\B'; SystemRoot = 'D:\Windows'; Firmware = 'BIOS'; SystemVolume = 'T'
            }

            $first.EntryId | Should -BeExactly $second.EntryId
        }

        # NOT MDT'S GUID. HDT carries no MDT dependency (CLAUDE.md rule 4), and
        # sharing MDT's {d22e7e91-...} would mean an HDT teardown deleting an
        # MDT entry, or the reverse, on a machine that had met both.
        It 'does not reuse the MDT ramdisk entry id' {
            (& $script:plan $script:uefiArgument).EntryId |
                Should -Not -BeExactly '{d22e7e91-9ee7-46eb-89d7-c5859e4302f0}'
        }

        It 'points the ramdisk device at the staged wim, relative to the volume' {
            $plan = & $script:plan $script:uefiArgument

            $plan.RamdiskVolume | Should -BeExactly 'C:'
            $plan.WimDevicePath | Should -BeExactly '\HDT\Boot\boot.wim'
            $plan.SdiDevicePath | Should -BeExactly '\HDT\Boot\boot.sdi'
        }

        It 'names winload.efi under UEFI' {
            (& $script:plan $script:uefiArgument).LoaderPath |
                Should -BeExactly '\windows\system32\boot\winload.efi'
        }

        It 'names winload.exe under BIOS' {
            $bios = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                Firmware = 'BIOS'; SystemVolume = 'S'
            }

            $bios.LoaderPath | Should -BeExactly '\windows\system32\boot\winload.exe'
        }

        It 'describes the entry in words a technician reading a boot menu would recognise' {
            (& $script:plan $script:uefiArgument).Description | Should -BeExactly 'HDT Windows PE'
        }
    }

    Context 'which BCD store' {

        # THE STORE IS EMPTY IN THE FULL OS, AND THAT IS DELIBERATE. A machine
        # running Windows booted through the store bcdboot wrote, so bare
        # bcdedit already targets it; naming a path would mean finding the EFI
        # System Partition's drive letter, which it does not have.
        It 'uses the system store when no system volume is known' {
            $plan = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'; Firmware = 'UEFI'
            }

            $plan.StorePath | Should -BeExactly ''
        }

        # IN WinPE THERE IS NO SYSTEM STORE TO EDIT - the RAM disk's own store is
        # not the one the machine boots from - so the teardown leg names the
        # store the partition step lettered.
        It 'names the EFI store on the system volume under UEFI' {
            (& $script:plan $script:uefiArgument).StorePath |
                Should -BeExactly 'S:\EFI\Microsoft\Boot\BCD'
        }

        It 'names the BIOS store on the system volume under BIOS' {
            $plan = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                Firmware = 'BIOS'; SystemVolume = 'S'
            }

            $plan.StorePath | Should -BeExactly 'S:\Boot\BCD'
        }
    }

    Context 'the firmware argument' {

        It 'reads firmware case-insensitively' {
            $plan = & $script:plan @{
                Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'
                Firmware = 'uefi'; SystemVolume = 'S'
            }

            $plan.LoaderPath | Should -BeExactly '\windows\system32\boot\winload.efi'
        }

        It 'refuses a firmware it does not know' {
            {
                & $script:plan @{
                    Volume = 'C'; DeployRoot = 'Z:\Share'; SystemRoot = 'C:\Windows'; Firmware = 'OpenFirmware'
                }
            } | Should -Throw
        }
    }
}
