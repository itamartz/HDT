# THE DESTRUCTIVE HALF OF IDiskService, THE FIRST TIME IT RUNS FOR REAL.
#
# Everything in tests/unit is asserted against New-HDTFakeDiskService. The fake
# MODELS SPIKES S6 rather than documenting it: it creates its own MSR on
# InitializeDisk, so the first partition an author creates on a GPT disk is
# number 2, and it refuses NewPartition on a RAW disk. This file is where those
# claims are checked against the Storage module.
#
# NO TEST HERE WRITES TO A DISK IT DID NOT CREATE. The scratch VHDX is made by
# New-HDTLabScratchDisk, whose Assert-HDTLabScratchDisk guard refuses any row
# that is IsBoot or IsSystem, and it is destroyed in an AfterAll that runs even
# when the tests fail.
#
# THE ONE TEST THAT TOUCHES THIS MACHINE'S OWN DISKS IS A REFUSAL, which is why
# it is safe: Select-HDTTargetDisk is asked for a target on a host whose only
# disk is the one it booted from, and the assertion is that nothing happens.

BeforeDiscovery {
    # Discovery-time, so -Skip can be decided per file rather than per test.
    $script:driveLetterInUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    $script:skipForDriveLetter = $script:driveLetterInUse.Count -gt 0
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # uefi-standard names S, W and R and Invoke-HDTDiskPartitionStep uses the
    # layout as written - there is no "pick a free letter" logic anywhere, by
    # design. On this host those letters may be taken, and the honest answer is
    # to skip the file naming the letter rather than to fail inside
    # SetPartitionDriveLetter or, worse, to format something.
    $script:inUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    if ($script:inUse.Count -gt 0) {
        Write-Warning ("DiskService.Integration.Tests.ps1 skipped: the uefi-standard layout needs S:, W: and R: free on this host and {0}: is in use." -f ($script:inUse -join ':, '))
    }

    $script:scratchRoot = 'C:\HDTLab\scratch\integration'
    $script:scratchPath = Join-Path -Path $script:scratchRoot -ChildPath 'diskservice.vhdx'
    $script:scratchSizeByte = 42949672960   # 40 GB, dynamic

    $script:disk = New-HDTDiskService

    $script:scratchNumber = -1
    if ($script:inUse.Count -eq 0) {
        $scratch = New-HDTLabScratchDisk -Path $script:scratchPath -SizeByte $script:scratchSizeByte -Dynamic -Confirm:$false
        $script:scratchNumber = [int] $scratch.DiskNumber

        Write-Information ("scratch VHDX mounted as disk {0}" -f $script:scratchNumber) -InformationAction Continue
    }

    # Every assertion in this file reads through these, and every one of them
    # filters to the scratch disk number and no other.
    $script:onScratch = {
        param([string] $Kind)

        if ($Kind -eq 'Partition') {
            return @($script:disk.GetPartition() | Where-Object { $_.DiskNumber -eq $script:scratchNumber })
        }

        return @($script:disk.GetDisk() | Where-Object { $_.Number -eq $script:scratchNumber })[0]
    }

    $script:espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $script:msrType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    $script:recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
}

AfterAll {
    # Runs even when the tests failed. A leftover mounted VHDX is 40 GB and a
    # disk number that the next run would be handed.
    if (Get-Command -Name 'Remove-HDTLabScratchDisk' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchDisk -Path $script:scratchPath -Confirm:$false
    }
}

Describe 'IDiskService against this machine' {

    # SAFE BECAUSE IT REFUSES. This host has one physical disk and it is the one
    # it booted from, so the only correct answer is no.

    It 'refuses to select the disk this machine booted from' {
        $row = @($script:disk.GetDisk())
        $partition = @($script:disk.GetPartition())
        $volume = @($script:disk.GetVolume())

        # The scratch VHDX is excluded by size: 40 GB against a 60 GB minimum.
        # What is left is disk 0, which is IsBoot and IsSystem.
        $record = $null
        try {
            Select-HDTTargetDisk -Disk $row -Partition $partition -Volume $volume `
                -MinimumSizeByte 64424509440 -ProtectDriveLetter @('C:\')
        } catch {
            $record = $_
        }

        $record | Should -Not -BeNullOrEmpty -Because 'this host has no disk HDT may wipe'
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
    }

    It 'names the boot disk rule in the refusal' {
        $row = @($script:disk.GetDisk())
        $partition = @($script:disk.GetPartition())
        $volume = @($script:disk.GetVolume())

        $record = $null
        try {
            Select-HDTTargetDisk -Disk $row -Partition $partition -Volume $volume `
                -MinimumSizeByte 64424509440 -ProtectDriveLetter @('C:\')
        } catch {
            $record = $_
        }

        # The refusal prints the whole table, so the operator can see which rule
        # excluded which disk rather than being told only that it failed.
        [string] $record.Exception.Message | Should -BeLike '*disk 0*'
        [string] $record.Exception.Message | Should -BeLike '*boot*'
    }

    It 'refuses an explicit diskNumber naming the system disk' {
        # Rules 1-5 can NEVER be overridden by an explicit diskNumber (04-02).
        # Naming the disk is not a licence to wipe the machine you are on.
        $row = @($script:disk.GetDisk())
        $partition = @($script:disk.GetPartition())
        $volume = @($script:disk.GetVolume())

        $record = $null
        try {
            Select-HDTTargetDisk -Disk $row -Partition $partition -Volume $volume `
                -DiskNumber 0 -MinimumSizeByte 1073741824 -AllowExistingData
        } catch {
            $record = $_
        }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
    }

    It 'reports this host disk 0 as the boot and system disk' {
        # The evidence for the three assertions above, recorded rather than
        # assumed - and the row every later run is compared against.
        $host0 = @($script:disk.GetDisk() | Where-Object { $_.Number -eq 0 })[0]

        $host0.IsBoot | Should -BeTrue
        $host0.IsSystem | Should -BeTrue
        $host0.PartitionStyle | Should -BeExactly 'GPT'
    }
}

Describe 'IDiskService against a scratch VHDX' -Skip:$skipForDriveLetter {

    Context 'the disk it was handed' {

        It 'is not the disk this machine booted from' {
            $row = & $script:onScratch 'Disk'

            $row.IsBoot | Should -BeFalse
            $row.IsSystem | Should -BeFalse
        }

        It 'sees the scratch disk with a File Backed Virtual bus type' {
            # tests/fixtures/disk/host-vhdx-disk.json captured exactly this, and
            # it is NOT 'Virtual' - do not filter on a guessed bus type.
            $row = & $script:onScratch 'Disk'

            $row.BusType | Should -BeExactly 'File Backed Virtual'
        }

        It 'reports the size it was created with' {
            $row = & $script:onScratch 'Disk'

            $row.SizeBytes | Should -Be $script:scratchSizeByte
        }
    }

    Context 'clear and initialise' {

        It 'refuses to clear a disk that has never been initialised' {
            # FOUND HERE, AND IT WAS A REAL DEFECT (04-04). A brand-new VHDX is
            # RAW - and so is the disk of a machine that has never been deployed,
            # which is every machine DiskPartition exists for. Clear-Disk on it
            # reports "The disk has not been initialized." The step used to call
            # ClearDisk unconditionally.
            (& $script:onScratch 'Disk').PartitionStyle | Should -BeExactly 'RAW'

            { $script:disk.ClearDisk($script:scratchNumber) } | Should -Throw '*not been initialized*'
        }

        It 'initialises it as GPT' {
            $script:disk.InitializeDisk($script:scratchNumber, 'GPT')

            (& $script:onScratch 'Disk').PartitionStyle | Should -BeExactly 'GPT'
        }

        It 'observes Initialize-Disk creating a reserved partition nobody asked for' {
            # SPIKES S6, NOW PROVEN BY CODE RATHER THAN BY HAND. This is the
            # single most important assertion in the file: PSD's
            # PSDPartition.ps1 initialises GPT on line 97 and then creates an MSR
            # by hand on line 116, and the duplicate 16 MB partition that
            # produces is why HDT's layouts declare no Reserved role at all.
            $reserved = @(& $script:onScratch 'Partition' | Where-Object { $_.GptType -eq $script:msrType })

            $reserved.Count | Should -Be 1 -Because 'Initialize-Disk -PartitionStyle GPT creates its own MSR'

            # NOT 16 MB EXACTLY. It is 16759808 bytes at offset 17408, and the
            # two together are exactly the 16777216 the layout carries as
            # ReservedSizeByte - so that allowance is right to the byte, which is
            # worth knowing rather than being lucky about.
            $reserved[0].SizeBytes | Should -Be 16759808
            $reserved[0].OffsetBytes | Should -Be 17408
            ($reserved[0].SizeBytes + $reserved[0].OffsetBytes) |
                Should -Be ([long] (Get-HDTDiskLayout -Name 'uefi-standard').ReservedSizeByte)
        }

        It 'created nothing else' {
            @(& $script:onScratch 'Partition').Count | Should -Be 1
        }

        It 'clears an initialised disk, and leaves it RAW again' {
            # The other half of the finding: once there IS a partition table,
            # Clear-Disk -RemoveData -RemoveOEM works and leaves the disk RAW,
            # which is what SPIKES S6 recorded and what a redeploy relies on.
            $script:disk.ClearDisk($script:scratchNumber)

            (& $script:onScratch 'Disk').PartitionStyle | Should -BeExactly 'RAW'
            @(& $script:onScratch 'Partition') | Should -BeNullOrEmpty

            # And back to GPT for the layout context that follows.
            $script:disk.InitializeDisk($script:scratchNumber, 'GPT')
            (& $script:onScratch 'Disk').PartitionStyle | Should -BeExactly 'GPT'
        }
    }

    Context 'the uefi-standard plan, applied for real' {

        BeforeAll {
            $script:layout = Get-HDTDiskLayout -Name 'uefi-standard'
            $script:plan = @(New-HDTDiskLayoutPlan -Layout $script:layout -DiskSizeByte $script:scratchSizeByte)

            # The same order Invoke-HDTDiskPartitionStep uses, called directly so
            # a failure names the method rather than the step.
            foreach ($row in $script:plan) {
                $createType = [string] $row.CreateGptType

                $created = $script:disk.NewPartition($script:scratchNumber, [long] $row.SizeByte,
                    [bool] $row.UseMaximumSize, $createType, [bool] $row.IsActive)

                $number = [int] $created.PartitionNumber

                $script:disk.SetPartitionDriveLetter($script:scratchNumber, $number, [string] $row.DriveLetter)
                $script:disk.FormatVolume([string] $row.DriveLetter, [string] $row.FileSystem, [string] $row.Label)

                $finalType = [string] $row.GptType
                if (-not [string]::IsNullOrWhiteSpace($finalType) -and $finalType -ne $createType) {
                    $script:disk.SetPartitionType($script:scratchNumber, $number, $finalType)
                }
            }

            $script:after = @(& $script:onScratch 'Partition' | Sort-Object PartitionNumber)
            $script:volume = @($script:disk.GetVolume())
        }

        It 'ends with four partitions in the documented order' {
            # ESP, MSR, Windows, Recovery - the shape SPIKES S6 produced by hand,
            # with the MSR sitting where Initialize-Disk put it.
            $script:after.Count | Should -Be 4
        }

        It 'creates exactly one reserved partition when HDT partitions the disk' {
            @($script:after | Where-Object { $_.GptType -eq $script:msrType }).Count | Should -Be 1
        }

        It 'creates the ESP as basic data, formats it FAT32 and then sets the ESP type' {
            # THE RECIPE 04-02 RECORDED AS UNVERIFIED. A partition created
            # directly as an EFI System partition cannot readily be given a drive
            # letter to format through, so the layout carries CreateGptType
            # (basic data) as well as GptType (the ESP type). If Set-Partition
            # -GptType after Format-Volume did not work, this is where it is
            # discovered - and the finding goes into SPIKES.md and the layout
            # changes, not this test.
            $esp = @($script:after | Where-Object { $_.DriveLetter -eq 'S' })

            $esp.Count | Should -Be 1
            $esp[0].GptType | Should -BeExactly $script:espType
            $esp[0].SizeBytes | Should -Be 272629760

            $espVolume = @($script:volume | Where-Object { $_.DriveLetter -eq 'S' })
            $espVolume.Count | Should -Be 1
            $espVolume[0].FileSystem | Should -BeExactly 'FAT32'
        }

        It 'creates the Windows partition at the planned size' {
            $planned = @($script:plan | Where-Object { $_.Role -eq 'Windows' })[0]
            $windows = @($script:after | Where-Object { $_.DriveLetter -eq 'W' })

            $windows.Count | Should -Be 1

            # Within one alignment unit of New-HDTDiskLayoutPlan's number: the
            # Storage module rounds a partition up to the next alignment
            # boundary, which is what the layout's AlignmentSizeByte allows for.
            [math]::Abs($windows[0].SizeBytes - [long] $planned.SizeByte) |
                Should -BeLessOrEqual ([long] $script:layout.AlignmentSizeByte)
        }

        It 'creates the recovery partition with the recovery GPT type' {
            $recovery = @($script:after | Where-Object { $_.DriveLetter -eq 'R' })

            $recovery.Count | Should -Be 1
            $recovery[0].GptType | Should -BeExactly $script:recoveryType
            $recovery[0].SizeBytes | Should -BeGreaterOrEqual 1073741824
        }

        It 'formats the volumes with the planned file systems and labels' {
            foreach ($row in $script:plan) {
                $found = @($script:volume | Where-Object { $_.DriveLetter -eq [string] $row.DriveLetter })

                $found.Count | Should -Be 1 -Because ("{0}: should have a volume" -f $row.DriveLetter)
                $found[0].FileSystem | Should -BeExactly ([string] $row.FileSystem)

                # CASE-INSENSITIVELY, AND THAT IS A FINDING (04-04). See the
                # test below: FAT32 has no lower case in a volume label.
                ([string] $found[0].FileSystemLabel).ToUpperInvariant() |
                    Should -BeExactly ([string] $row.Label).ToUpperInvariant()
            }
        }

        It 'uppercases the FAT32 label and preserves the NTFS one' {
            # FAT32 HAS NO LOWER CASE IN A VOLUME LABEL (04-04). The layout asks
            # for 'System' on the ESP and the volume reports 'SYSTEM'; the NTFS
            # volumes keep the case they were given. Nothing downstream may
            # match a volume label case-sensitively, and this is where that is
            # written down rather than discovered again later.
            $esp = @($script:volume | Where-Object { $_.DriveLetter -eq 'S' })[0]
            $windows = @($script:volume | Where-Object { $_.DriveLetter -eq 'W' })[0]

            $esp.FileSystemLabel | Should -BeExactly 'SYSTEM'
            $windows.FileSystemLabel | Should -BeExactly 'Windows'
        }

        It 'assigns the planned drive letters' {
            # S, W and R come from the layout, not from a search for free
            # letters. The BeforeAll of this file asserts they were free on the
            # host before anything was created; see tests/integration/README.md.
            @($script:after | ForEach-Object { $_.DriveLetter } | Where-Object { $_ } | Sort-Object) |
                Should -Be @('R', 'S', 'W')
        }

        It 'leaves the whole disk allocated' {
            # The recovery row carries UseMaximumSize so the alignment slack
            # lands there rather than being left unallocated at the end.
            $total = [long] 0
            foreach ($row in $script:after) { $total += [long] $row.SizeBytes }

            # Under 32 MB of GPT metadata and alignment unaccounted for.
            ($script:scratchSizeByte - $total) | Should -BeLessThan 33554432
        }

        It 'never touched this machine disk 0' {
            $written = @($script:disk.Operations |
                    Where-Object { $_.Operation -in @('ClearDisk', 'InitializeDisk', 'NewPartition', 'SetPartitionDriveLetter', 'SetPartitionType') } |
                    ForEach-Object { [int] $_.Arguments[0] })

            $written.Count | Should -BeGreaterThan 0
            @($written | Where-Object { $_ -ne $script:scratchNumber }) | Should -BeNullOrEmpty
        }
    }

    Context 'the existence guards' {

        # A ScriptMethod wraps whatever it throws in a MethodInvocationException,
        # and $ErrorActionPreference = 'Stop' inside the adapter wraps it AGAIN
        # in a RuntimeException - so the chain is three deep and the identity of
        # the failure is at the bottom of it (04-04, found by running it).
        # GetBaseException() is what reaches it. Asserting the outer type would
        # pass for any failure at all, which is helpers README 12's "it threw is
        # not an assertion".

        It 'throws ArgumentOutOfRangeException for a disk that is not there' {
            # Both implementations of IDiskService must fail the same way for the
            # same mistake. Get-Disk -Number is a [uint32], so the adapter
            # filters client-side rather than passing -Number (04-01).
            $record = $null
            try { $script:disk.ClearDisk(9999) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.GetBaseException() | Should -BeOfType ([System.ArgumentOutOfRangeException])
        }

        It 'throws ArgumentOutOfRangeException for a partition that is not there' {
            $record = $null
            try { $script:disk.SetPartitionType($script:scratchNumber, 99, $script:espType) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.GetBaseException() | Should -BeOfType ([System.ArgumentOutOfRangeException])
        }
    }
}
