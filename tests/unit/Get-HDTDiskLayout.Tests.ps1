# The two named layouts of DESIGN 9.1, as DATA rather than as code.
#
#   uefi-standard  GPT: EFI System 260 MB FAT32, Windows, WinRE recovery 1 GB
#   bios-standard  MBR: System Reserved 500 MB active NTFS, Windows remainder
#
# THE MOST IMPORTANT ASSERTION IN THIS FILE IS THAT NEITHER DECLARES AN MSR.
# SPIKES S6: Initialize-Disk -PartitionStyle GPT creates its own 16 MB Microsoft
# Reserved partition. PSD's PSDPartition.ps1 initialises GPT on line 97 and then
# creates an MSR by hand on line 116, which is exactly how the spike ended up
# with a duplicate 16 MB partition. HDT subtracts the 16 MB as an allowance and
# never plans a partition for it.
#
# DESIGN 9.1 says layouts live in workspace.yaml. THAT DOCUMENT DOES NOT EXIST
# YET - M4 introduces it for the boot image - so the built-ins live in this
# function and -Definition is the hook that will carry a workspace.yaml
# diskLayouts: block when there is one. Nothing has to be rewritten then.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:basicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $script:espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $script:recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
}

Describe 'Get-HDTDiskLayout' {

    Context 'the built-in layouts' {

        It 'returns both built-in layouts when no name is given' {
            $layout = @(Get-HDTDiskLayout)

            @($layout | ForEach-Object { $_.Name }) | Should -Be @('uefi-standard', 'bios-standard')
        }

        It 'returns uefi-standard by name' {
            (Get-HDTDiskLayout -Name 'uefi-standard').Name | Should -BeExactly 'uefi-standard'
        }

        It 'returns bios-standard by name' {
            (Get-HDTDiskLayout -Name 'bios-standard').Name | Should -BeExactly 'bios-standard'
        }

        It 'matches a layout name case-insensitively' {
            (Get-HDTDiskLayout -Name 'UEFI-Standard').Name | Should -BeExactly 'uefi-standard'
        }

        It 'throws HDTConfigurationError for an unknown layout' {
            $record = $null
            try { Get-HDTDiskLayout -Name 'uefi-contoso' } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'lists the known layout names in that error' {
            $record = $null
            try { Get-HDTDiskLayout -Name 'uefi-contoso' } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*uefi-standard*'
            $record.Exception.Message | Should -BeLike '*bios-standard*'
        }
    }

    Context 'uefi-standard' {

        BeforeEach {
            $script:layout = Get-HDTDiskLayout -Name 'uefi-standard'
        }

        It 'uses the GPT partition style' {
            $script:layout.PartitionStyle | Should -BeExactly 'GPT'
        }

        It 'declares three partitions' {
            @($script:layout.Partition).Count | Should -Be 3
        }

        It 'declares no reserved partition' {
            # SPIKES S6. Initialize-Disk makes the MSR; a layout that declares one
            # produces a duplicate 16 MB partition, which is the bug the spike hit.
            @($script:layout.Partition | ForEach-Object { $_.Role }) | Should -Not -Contain 'Reserved'
        }

        It 'reserves 16MB for the MSR Initialize-Disk creates' {
            # The allowance is present as arithmetic even though the partition is
            # not, or Windows would be planned 16 MB too large.
            $script:layout.ReservedSizeByte | Should -Be 16777216
        }

        It 'declares a 260MB FAT32 system partition' {
            $system = @($script:layout.Partition | Where-Object { $_.Role -eq 'System' })

            $system.Count | Should -Be 1
            $system[0].SizeByte | Should -Be 272629760
            $system[0].FileSystem | Should -BeExactly 'FAT32'
            $system[0].DriveLetter | Should -BeExactly 'S'
        }

        It 'creates the ESP as basic data and sets the ESP type afterwards' {
            # The field recipe: a partition created directly as an ESP cannot
            # readily be given a drive letter to format through. UNVERIFIED BY
            # CODE - 04-04's integration task is where this first runs.
            $system = @($script:layout.Partition | Where-Object { $_.Role -eq 'System' })[0]

            $system.CreateGptType | Should -BeExactly $script:basicDataType
            $system.GptType | Should -BeExactly $script:espType
        }

        It 'declares a 1GB recovery partition with the recovery GPT type' {
            $recovery = @($script:layout.Partition | Where-Object { $_.Role -eq 'Recovery' })

            $recovery.Count | Should -Be 1
            $recovery[0].SizeByte | Should -Be 1073741824
            $recovery[0].GptType | Should -BeExactly $script:recoveryType
            $recovery[0].UseMaximumSize | Should -BeTrue
        }

        It 'puts the recovery partition last' {
            @($script:layout.Partition)[-1].Role | Should -BeExactly 'Recovery'
        }

        It 'gives the Windows partition the letter W' {
            # Every later step in the phase names it.
            $windows = @($script:layout.Partition | Where-Object { $_.Role -eq 'Windows' })[0]

            $windows.DriveLetter | Should -BeExactly 'W'
            $windows.FileSystem | Should -BeExactly 'NTFS'
            $windows.Label | Should -BeExactly 'Windows'
        }

        It 'labels the recovery partition the way WinRE expects' {
            $recovery = @($script:layout.Partition | Where-Object { $_.Role -eq 'Recovery' })[0]

            $recovery.Label | Should -BeExactly 'Windows RE tools'
            $recovery.DriveLetter | Should -BeExactly 'R'
        }
    }

    Context 'bios-standard' {

        BeforeEach {
            $script:layout = Get-HDTDiskLayout -Name 'bios-standard'
        }

        It 'uses the MBR partition style' {
            $script:layout.PartitionStyle | Should -BeExactly 'MBR'
        }

        It 'declares two partitions' {
            @($script:layout.Partition).Count | Should -Be 2
        }

        It 'declares a 500MB active system reserved partition' {
            $system = @($script:layout.Partition | Where-Object { $_.Role -eq 'System' })[0]

            $system.SizeByte | Should -Be 524288000
            $system.IsActive | Should -BeTrue
            $system.FileSystem | Should -BeExactly 'NTFS'
            $system.Label | Should -BeExactly 'System Reserved'
        }

        It 'gives the Windows partition the rest of the disk' {
            $windows = @($script:layout.Partition | Where-Object { $_.Role -eq 'Windows' })[0]

            $windows.UseMaximumSize | Should -BeTrue
        }

        It 'declares no recovery partition' {
            # DESIGN 9.1's BIOS layout has none, and a test says so rather than
            # leaving it to be inferred from a count.
            @($script:layout.Partition | ForEach-Object { $_.Role }) | Should -Not -Contain 'Recovery'
        }

        It 'declares no GPT type on an MBR layout' {
            foreach ($row in @($script:layout.Partition)) {
                $row.GptType | Should -BeExactly ''
                $row.CreateGptType | Should -BeExactly ''
            }
        }

        It 'reserves nothing, because MBR initialisation creates nothing' {
            $script:layout.ReservedSizeByte | Should -Be 0
        }
    }

    Context 'overrides' {

        BeforeEach {
            $script:definition = @{
                'contoso-single' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }
        }

        It 'returns a layout supplied through -Definition' {
            $layout = Get-HDTDiskLayout -Name 'contoso-single' -Definition $script:definition

            $layout.Name | Should -BeExactly 'contoso-single'
            @($layout.Partition).Count | Should -Be 1
        }

        It 'lets a supplied definition replace a built-in of the same name' {
            $definition = @{
                'uefi-standard' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }

            @((Get-HDTDiskLayout -Name 'uefi-standard' -Definition $definition).Partition).Count | Should -Be 1
        }

        It 'keeps the built-ins a supplied definition does not name' {
            @(Get-HDTDiskLayout -Definition $script:definition | ForEach-Object { $_.Name }) |
                Should -Be @('uefi-standard', 'bios-standard', 'contoso-single')
        }

        It 'rejects a definition with an unknown role' {
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Reserved'; SizeByte = 16777216; FileSystem = 'NTFS'; Label = 'MSR'; DriveLetter = '' },
                        @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*contoso-bad*'
            $record.Exception.Message | Should -BeLike '*Reserved*'
        }

        It 'rejects a definition with no file system' {
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Windows'; UseMaximumSize = $true; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*contoso-bad*'
        }

        It 'rejects a definition with no drive letter' {
            # THE SAME DEFECT THE AUTHORED PATH HAD, by the other door. A blank
            # letter is not a default: Format-Volume takes a drive letter and
            # nothing else, and the disk service reads an empty one as "remove
            # this partition's access path". A custom layout that omitted it
            # failed on the disk with "The access path is not valid", naming
            # neither the layout nor the row that was missing a letter.
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*contoso-bad*'
            $record.Exception.Message | Should -BeLike '*Windows*'
        }

        It 'rejects a definition with a negative size' {
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'Windows'; SizeByte = -1; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*contoso-bad*'
        }

        It 'rejects a definition with no Windows role' {
            # A layout that does not say where Windows goes is not a layout.
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'GPT'
                    Partition      = @(
                        @{ Role = 'System'; SizeByte = 272629760; FileSystem = 'FAT32'; Label = 'System'; DriveLetter = 'S' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Windows*'
        }

        It 'rejects a definition with an unknown partition style' {
            $definition = @{
                'contoso-bad' = @{
                    PartitionStyle = 'RAW'
                    Partition      = @(
                        @{ Role = 'Windows'; UseMaximumSize = $true; FileSystem = 'NTFS'; Label = 'Windows'; DriveLetter = 'W' }
                    )
                }
            }

            $record = $null
            try { Get-HDTDiskLayout -Definition $definition } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Get-HDTDiskLayout -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTDiskLayout'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
