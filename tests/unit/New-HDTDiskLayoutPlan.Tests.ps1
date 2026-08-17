# The partition arithmetic, in exact bytes.
#
# It is asserted in bytes rather than in megabytes on purpose. "About 64 GB" is
# what a plan with an off-by-one-partition error also looks like, and the whole
# value of this function is that the numbers are exact before anything
# destructive runs against them.
#
# The 16 MB the MSR takes is SUBTRACTED and never PLANNED (SPIKES S6):
# Initialize-Disk -PartitionStyle GPT creates the Microsoft Reserved partition
# itself, so a layout that also creates one produces a duplicate - the exact bug
# the spike hit against PSDPartition.ps1.
#
#   uefi-standard  windows = disk - 260MB(ESP) - 16MB(MSR) - 1GB(recovery) - 1MB(align)
#                  the recovery row carries UseMaximumSize, so the slack lands there
#   bios-standard  windows = UseMaximumSize after a 500MB system partition

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # 64 GiB, the size of the lab VM disk in SPIKES S6.
    $script:disk64GiB = 68719476736
    $script:disk128GiB = 137438953472
    # A deliberately awkward non-power-of-two, as a real vendor disk reports.
    $script:disk32GB = 32000000000

    $script:espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $script:recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
}

Describe 'New-HDTDiskLayoutPlan' {

    Context 'uefi-standard on a 64GiB disk' {

        BeforeEach {
            $script:plan = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte $script:disk64GiB)
        }

        It 'plans exactly three partitions' {
            $script:plan.Count | Should -Be 3
        }

        It 'plans the ESP first, at 272629760 bytes' {
            $script:plan[0].Role | Should -BeExactly 'System'
            $script:plan[0].Order | Should -Be 1
            $script:plan[0].SizeByte | Should -Be 272629760
        }

        It 'plans no MSR' {
            @($script:plan | ForEach-Object { $_.Role }) | Should -Not -Contain 'Reserved'
        }

        It 'sizes Windows as the disk minus the ESP, the MSR, the recovery and the alignment slack' {
            # 68719476736 - 272629760 - 16777216 - 1073741824 - 1048576
            $script:plan[1].Role | Should -BeExactly 'Windows'
            $script:plan[1].SizeByte | Should -Be 67355279360
        }

        It 'plans the recovery partition with UseMaximumSize' {
            $script:plan[2].Role | Should -BeExactly 'Recovery'
            $script:plan[2].UseMaximumSize | Should -BeTrue
        }

        It 'does not use maximum size for the ESP or Windows' {
            $script:plan[0].UseMaximumSize | Should -BeFalse
            $script:plan[1].UseMaximumSize | Should -BeFalse
        }

        It 'orders the rows ESP, Windows, Recovery' {
            @($script:plan | ForEach-Object { $_.Role }) | Should -Be @('System', 'Windows', 'Recovery')
            @($script:plan | ForEach-Object { $_.Order }) | Should -Be @(1, 2, 3)
        }

        It 'carries the drive letters S, W and R' {
            @($script:plan | ForEach-Object { $_.DriveLetter }) | Should -Be @('S', 'W', 'R')
        }

        It 'carries FAT32 for the ESP and NTFS for the others' {
            @($script:plan | ForEach-Object { $_.FileSystem }) | Should -Be @('FAT32', 'NTFS', 'NTFS')
        }

        It 'carries the recovery GPT type on the recovery row' {
            $script:plan[2].GptType | Should -BeExactly $script:recoveryType
        }

        It 'carries a create-as type only on the ESP row' {
            $script:plan[0].CreateGptType | Should -Not -BeNullOrEmpty
            $script:plan[0].GptType | Should -BeExactly $script:espType
            $script:plan[1].CreateGptType | Should -BeExactly ''
            $script:plan[2].CreateGptType | Should -BeExactly ''
        }

        It 'marks nothing active on a GPT layout' {
            foreach ($row in $script:plan) { $row.IsActive | Should -BeFalse }
        }

        It 'plans the same three roles on a 128GiB disk, with Windows larger' {
            $bigger = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte $script:disk128GiB)

            $bigger.Count | Should -Be 3
            $bigger[1].SizeByte | Should -Be 136074756096
        }

        It 'plans an awkward non-power-of-two disk exactly' {
            # 32000000000 - 272629760 - 16777216 - 1073741824 - 1048576
            $awkward = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte $script:disk32GB)

            $awkward[1].SizeByte | Should -Be 30635802624
        }
    }

    Context 'bios-standard on a 64GiB disk' {

        BeforeEach {
            $script:plan = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'bios-standard') -DiskSizeByte $script:disk64GiB)
        }

        It 'plans exactly two partitions' {
            $script:plan.Count | Should -Be 2
        }

        It 'plans a 524288000 byte active system partition' {
            $script:plan[0].Role | Should -BeExactly 'System'
            $script:plan[0].SizeByte | Should -Be 524288000
        }

        It 'marks the system partition active' {
            $script:plan[0].IsActive | Should -BeTrue
        }

        It 'gives Windows UseMaximumSize' {
            $script:plan[1].Role | Should -BeExactly 'Windows'
            $script:plan[1].UseMaximumSize | Should -BeTrue
        }

        It 'sets no GPT type on either row' {
            foreach ($row in $script:plan) {
                $row.GptType | Should -BeExactly ''
                $row.CreateGptType | Should -BeExactly ''
            }
        }

        It 'subtracts no MSR allowance, because MBR initialisation creates none' {
            # 68719476736 - 524288000 - 1048576
            $script:plan[1].SizeByte | Should -Be 68194140160
        }
    }

    Context 'a disk that is too small' {

        It 'refuses a disk smaller than the layout needs' {
            $record = $null
            try { New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte 8589934592 } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'names the disk size and the shortfall' {
            $record = $null
            try { New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte 8589934592 } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*8589934592*'
            # 21474836480 - 7225737216
            $record.Exception.Message | Should -BeLike '*14249099264*'
        }

        It 'refuses when Windows would fall under the minimum' {
            # The default minimum is 20 GB. A 21 GB disk leaves Windows short.
            $record = $null
            try { New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte 22548578304 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'honours -MinimumWindowsSizeByte' {
            $plan = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') `
                    -DiskSizeByte 8589934592 -MinimumWindowsSizeByte 4294967296)

            $plan.Count | Should -Be 3
            $plan[1].SizeByte | Should -Be 7225737216
        }

        It 'never plans a partition with a negative size' {
            # The assertion that would have caught the arithmetic bug directly.
            # The planned count is asserted too: a version of this that threw for
            # every size would satisfy the loop while proving nothing.
            $planned = 0

            foreach ($size in @(0, 1048576, 268435456, 1073741824, 2147483648, 8589934592, 21474836480)) {
                $plan = $null
                try {
                    $plan = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') `
                            -DiskSizeByte $size -MinimumWindowsSizeByte 1)
                } catch {
                    $plan = $null
                }

                foreach ($row in @($plan)) {
                    if ($null -eq $row) { continue }
                    $planned++
                    $row.SizeByte | Should -BeGreaterOrEqual 0
                }
            }

            # 2 GB, 8 GB and 20 GB all leave a positive Windows partition.
            $planned | Should -Be 9
        }

        It 'refuses a disk of zero bytes' {
            $record = $null
            try { New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte 0 -MinimumWindowsSizeByte 1 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'determinism' {

        It 'plans the same rows for the same disk twice' {
            $first = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte $script:disk64GiB)
            $second = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name 'uefi-standard') -DiskSizeByte $script:disk64GiB)

            @($first | ForEach-Object { '{0}:{1}:{2}' -f $_.Order, $_.Role, $_.SizeByte }) |
                Should -Be @($second | ForEach-Object { '{0}:{1}:{2}' -f $_.Order, $_.Role, $_.SizeByte })
        }

        It 'performs no I/O' {
            $command = Get-Command -Name New-HDTDiskLayoutPlan -ErrorAction Stop

            $command.Name | Should -BeExactly 'New-HDTDiskLayoutPlan'
            $command.Parameters.Keys | Should -Not -Contain 'DiskService'
            $command.Parameters.Keys | Should -Not -Contain 'FileSystem'
        }

        It 'does not mutate the layout it was given' {
            $layout = Get-HDTDiskLayout -Name 'uefi-standard'
            $before = @($layout.Partition | ForEach-Object { $_.SizeByte })

            $null = New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte $script:disk64GiB

            @($layout.Partition | ForEach-Object { $_.SizeByte }) | Should -Be $before
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name New-HDTDiskLayoutPlan -ErrorAction Stop

            $help.Name | Should -BeExactly 'New-HDTDiskLayoutPlan'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}

# =============================================================================
# AN AUTHORED LAYOUT, WHICH THE NAMED ONES CANNOT EXPRESS
# =============================================================================
#
# ConvertTo-HDTDiskLayout turns a partition table somebody wrote into the shape
# this planner reads. Two things in it are new, and both are arithmetic, so they
# are settled here rather than in the converter:
#
#   PercentOfRemainder   60% of what depends on the disk in front of us
#   TakesRemainder       which row gets what nothing else claimed - the named
#                        layouts mean Role 'Windows' by that, and an authored
#                        one names it outright
#
# The first version of this planner gave a 60% Windows the WHOLE disk and the
# remainder row nothing, because it only knew Role -eq 'Windows'. That was
# measured on a converted layout, not imagined.

Describe 'New-HDTDiskLayoutPlan against an authored layout' {

    BeforeAll {
        $script:disk = 137438953472   # 128 GB

        $script:layout = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
            @{ name = 'System'; type = 'EFI'; size = '260MB' }
            @{ name = 'Windows'; type = 'Primary'; size = '60%' }
            @{ name = 'Data'; type = 'Primary'; size = 'remainder' }
            @{ name = 'Recovery'; type = 'Recovery'; size = '1GB' })

        $script:plan = @(New-HDTDiskLayoutPlan -Layout $script:layout -DiskSizeByte $script:disk)
    }

    It 'gives every partition a size' {
        @($script:plan | Where-Object { [long] $_.SizeByte -le 0 }) | Should -BeNullOrEmpty
    }

    It 'keeps the fixed sizes exactly as authored' {
        @($script:plan | Where-Object { $_.Role -eq 'System' })[0].SizeByte | Should -Be 272629760
        @($script:plan | Where-Object { $_.Role -eq 'Recovery' })[0].SizeByte | Should -Be 1073741824
    }

    It 'reads a percentage as a share of what is left, not of the whole disk' {
        # MDT's own wording is "a percentage of remaining free space". 60% of the
        # disk and 60% of the remainder differ by more than a gigabyte here, and
        # the difference is silent - the disk still partitions.
        $fixed = 272629760 + 1073741824
        $available = $script:disk - $fixed - $script:layout.ReservedSizeByte - $script:layout.AlignmentSizeByte

        @($script:plan | Where-Object { $_.Role -eq 'Windows' })[0].SizeByte |
            Should -Be ([long] [math]::Floor($available * 0.6))
    }

    It 'gives the remainder row everything nothing else claimed' {
        $total = [long] 0
        foreach ($current in $script:plan) { $total += [long] $current.SizeByte }

        $total | Should -Be ($script:disk - $script:layout.ReservedSizeByte - $script:layout.AlignmentSizeByte)
    }

    It 'still plans a named layout exactly as it always did' {
        # THE REGRESSION THAT MATTERS. uefi-standard carries no
        # PercentOfRemainder and no TakesRemainder on any row - it means Windows
        # by Role - and every assertion above this block rests on that.
        $named = @(New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name uefi-standard) `
                -DiskSizeByte $script:disk)

        $windows = @($named | Where-Object { $_.Role -eq 'Windows' })[0]
        $overhead = 272629760 + 1073741824 + 16777216 + 1048576

        $windows.SizeByte | Should -Be ($script:disk - $overhead)
    }

    It 'refuses a layout whose percentages leave the remainder row nothing' {
        $greedy = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
            @{ name = 'Windows'; type = 'Primary'; size = '100%' }
            @{ name = 'Data'; type = 'Primary'; size = 'remainder' })

        { New-HDTDiskLayoutPlan -Layout $greedy -DiskSizeByte $script:disk } |
            Should -Throw -ExpectedMessage '*Data*'
    }
}
