# The hand-written IDiskService double (PROJECT constraint 4, DESIGN 12.2.1,
# DESIGN 12.2.3).
#
# Nine methods, three of them read-only. The three listings are FLAT - no
# filters and no joins - exactly as ICimProvider refused a -Filter: a partition
# row carries its DiskNumber and a volume row carries its DriveLetter, so the
# pure logic in 04-02 does the joining and the real adapter stays a projection
# of three cmdlets with no branch in it.
#
# TWO BEHAVIOURS THIS FAKE MODELS RATHER THAN DOCUMENTS, both from SPIKES.md S6:
#
#   * Initialize-Disk -PartitionStyle GPT SILENTLY CREATES A 16 MB MSR. PSD's
#     PSDPartition.ps1 then creates a second one by hand, which is how the spike
#     ended up with a duplicate. Because the fake creates it too, a step that
#     "helpfully" creates an MSR produces a duplicate the tests can see, and the
#     first partition an author creates on a GPT disk is number 2, not 1.
#   * A partition cannot be created on a disk that is still RAW. A fake that
#     allowed it would let a step that forgot InitializeDisk pass here and fail
#     on metal.

$script:HDTHasStorage = $null -ne (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:diskFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/disk'

    # A single RAW 64 GB disk, the shape SPIKES.md S6 saw inside a Gen2 VM.
    $script:NewRawDisk = {
        return [pscustomobject] @{
            Number            = 0
            FriendlyName      = 'Msft Virtual Disk'
            SerialNumber      = 'FIXTURE-SERIAL-0001'
            SizeBytes         = [long] 68719476736
            BusType           = 'SAS'
            PartitionStyle    = 'RAW'
            IsBoot            = $false
            IsSystem          = $false
            IsReadOnly        = $false
            IsOffline         = $false
            OperationalStatus = 'Online'
        }
    }
}

Describe 'New-HDTFakeDiskService' {

    Context 'reading' {

        It 'returns the disks it was seeded with' {
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)

            @($service.GetDisk()).Count | Should -Be 1
            $service.GetDisk()[0].Number | Should -Be 0
            $service.GetDisk()[0].BusType | Should -BeExactly 'SAS'
        }

        It 'returns an array even for a single disk' {
            # tests/helpers/README.md F3. This machine has exactly one disk, so
            # a collapse to a scalar would break every .Count in 04-02.
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)

            $service.GetDisk() -is [System.Array] | Should -BeTrue
        }

        It 'returns an empty array when no disk was seeded' {
            $service = New-HDTFakeDiskService

            $service.GetDisk() -is [System.Array] | Should -BeTrue
            @($service.GetDisk()).Count | Should -Be 0
        }

        It 'reads a seeded fixture file' {
            $service = New-HDTFakeDiskService -FixturePath $script:diskFixture

            $nvme = @($service.GetDisk() | Where-Object { $_.BusType -eq 'NVMe' })
            $nvme.Count | Should -Be 1
            $nvme[0].FriendlyName | Should -BeExactly 'SAMSUNG MZVL21T0HCLR-00BL2'
            $nvme[0].IsBoot | Should -BeTrue
            $nvme[0].IsSystem | Should -BeTrue
        }

        It 'reads a single fixture file' {
            $service = New-HDTFakeDiskService -FixturePath (Join-Path -Path $script:diskFixture -ChildPath 'gen2-vm-raw-disk.json')

            @($service.GetDisk()).Count | Should -Be 1
            $service.GetDisk()[0].PartitionStyle | Should -BeExactly 'RAW'
        }

        It 'returns the partitions it was seeded with' {
            $service = New-HDTFakeDiskService -FixturePath $script:diskFixture

            $esp = @($service.GetPartition() | Where-Object { $_.Type -eq 'System' })
            $esp.Count | Should -Be 1
            $esp[0].DiskNumber | Should -Be 0
            $esp[0].GptType | Should -BeExactly '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        }

        It 'returns the volumes it was seeded with' {
            $service = New-HDTFakeDiskService -FixturePath $script:diskFixture

            $volume = @($service.GetVolume())
            $volume.Count | Should -BeGreaterThan 0
            $volume[0].FileSystem | Should -BeExactly 'NTFS'
        }

        It 'returns an array from GetPartition and GetVolume' {
            $service = New-HDTFakeDiskService

            $service.GetPartition() -is [System.Array] | Should -BeTrue
            $service.GetVolume() -is [System.Array] | Should -BeTrue
        }

        It 'records GetDisk, GetPartition and GetVolume' {
            # Read-only methods record too: query order is evidence about what
            # the code under test tried.
            $service = New-HDTFakeDiskService

            $service.GetDisk() | Out-Null
            $service.GetPartition() | Out-Null
            $service.GetVolume() | Out-Null

            $service.GetOperationName() | Should -Be @('GetDisk', 'GetPartition', 'GetVolume')
        }
    }

    Context 'clearing and initialising' {

        BeforeEach {
            $script:service = New-HDTFakeDiskService -FixturePath (Join-Path -Path $script:diskFixture -ChildPath 'host-nvme-disk.json')
            foreach ($row in @(ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path -Path $script:diskFixture -ChildPath 'host-partition.json'))))) {
                $script:service.SeedPartition($row)
            }
        }

        It 'removes every partition on the disk it cleared' {
            @($script:service.GetPartition()).Count | Should -Be 4

            $script:service.ClearDisk(0)

            @($script:service.GetPartition() | Where-Object { $_.DiskNumber -eq 0 }).Count | Should -Be 0
        }

        It 'leaves other disks alone' {
            $second = & $script:NewRawDisk
            $second.Number = 1
            $script:service.SeedDisk($second)
            $script:service.SeedPartition([pscustomobject] @{ DiskNumber = 1; PartitionNumber = 1; SizeBytes = [long] 1024; OffsetBytes = [long] 1048576; Type = 'Basic' })

            $script:service.ClearDisk(0)

            @($script:service.GetPartition() | Where-Object { $_.DiskNumber -eq 1 }).Count | Should -Be 1
        }

        It 'sets the partition style to RAW after a clear' {
            $script:service.ClearDisk(0)

            $script:service.GetDisk()[0].PartitionStyle | Should -BeExactly 'RAW'
        }

        It 'throws for a disk number that does not exist' {
            { $script:service.ClearDisk(9) } | Should -Throw -ExceptionType ([System.ArgumentOutOfRangeException])
        }

        It 'sets the partition style Initialize-Disk was given' {
            $script:service.ClearDisk(0)
            $script:service.InitializeDisk(0, 'MBR')

            $script:service.GetDisk()[0].PartitionStyle | Should -BeExactly 'MBR'
        }

        It 'creates a 16MB reserved partition when it initialises GPT' {
            # SPIKES.md S6. Initialize-Disk -PartitionStyle GPT creates its own
            # MSR; HDT must never create a second one, and this is how a test
            # sees the duplicate if it does.
            $script:service.ClearDisk(0)
            $script:service.InitializeDisk(0, 'GPT')

            $reserved = @($script:service.GetPartition() | Where-Object { $_.Type -eq 'Reserved' })
            $reserved.Count | Should -Be 1
            $reserved[0].SizeBytes | Should -Be 16777216
            $reserved[0].GptType | Should -BeExactly '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
            $reserved[0].IsHidden | Should -BeTrue
        }

        It 'creates no reserved partition when it initialises MBR' {
            $script:service.ClearDisk(0)
            $script:service.InitializeDisk(0, 'MBR')

            @($script:service.GetPartition()).Count | Should -Be 0
        }

        It 'refuses to initialise a disk that is not RAW' {
            # Parity with the real cmdlet, which reports "The disk has already
            # been initialized".
            { $script:service.InitializeDisk(0, 'GPT') } | Should -Throw -ExpectedMessage '*already*'
        }

        It 'records ClearDisk and InitializeDisk with their arguments' {
            $script:service.ClearDisk(0)
            $script:service.InitializeDisk(0, 'GPT')

            $script:service.GetOperationName() | Should -Be @('ClearDisk', 'InitializeDisk')
            @($script:service.Operations[1].Arguments) | Should -Be @(0, 'GPT')
        }
    }

    Context 'partitioning' {

        BeforeEach {
            $script:service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)
            $script:service.InitializeDisk(0, 'GPT')
        }

        It 'returns the partition it created' {
            $created = $script:service.NewPartition(0, 272629760, $false, '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}', $false)

            $created | Should -Not -BeNullOrEmpty
            $created.SizeBytes | Should -Be 272629760
            $created.DiskNumber | Should -Be 0
        }

        It 'numbers partitions from one' {
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)
            $service.InitializeDisk(0, 'MBR')

            $created = $service.NewPartition(0, 524288000, $false, '', $true)

            $created.PartitionNumber | Should -Be 1
        }

        It 'numbers a partition after the reserved one Initialize-Disk made' {
            # The first partition an author creates on a GPT disk is number TWO.
            # A test that assumed 1 would pass against a naive fake and fail on
            # metal (SPIKES.md S6).
            $created = $script:service.NewPartition(0, 272629760, $false, '', $false)

            $created.PartitionNumber | Should -Be 2
        }

        It 'places a partition after the previous one' {
            $first = $script:service.NewPartition(0, 272629760, $false, '', $false)
            $second = $script:service.NewPartition(0, 1073741824, $false, '', $false)

            $second.OffsetBytes | Should -BeGreaterThan $first.OffsetBytes
            $second.OffsetBytes | Should -BeGreaterOrEqual ($first.OffsetBytes + $first.SizeBytes)
        }

        It 'gives a UseMaximumSize partition the rest of the disk' {
            $first = $script:service.NewPartition(0, 272629760, $false, '', $false)
            $rest = $script:service.NewPartition(0, 0, $true, '', $false)

            $rest.SizeBytes | Should -Be (68719476736 - $rest.OffsetBytes)
            ($rest.OffsetBytes + $rest.SizeBytes) | Should -Be 68719476736
            $first.SizeBytes | Should -Be 272629760
        }

        It 'records the GPT type it was given' {
            $created = $script:service.NewPartition(0, 272629760, $false, '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}', $false)

            $created.GptType | Should -BeExactly '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            $created.Type | Should -BeExactly 'System'
        }

        It 'records IsActive' {
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)
            $service.InitializeDisk(0, 'MBR')

            $created = $service.NewPartition(0, 524288000, $false, '', $true)

            $created.IsActive | Should -BeTrue
        }

        It 'refuses to create a partition on a disk that is still RAW' {
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk)

            { $service.NewPartition(0, 1024, $false, '', $false) } | Should -Throw -ExpectedMessage '*RAW*'
        }

        It 'throws for a disk number that does not exist' {
            { $script:service.NewPartition(3, 1024, $false, '', $false) } |
                Should -Throw -ExceptionType ([System.ArgumentOutOfRangeException])
        }

        It 'assigns a drive letter' {
            $created = $script:service.NewPartition(0, 272629760, $false, '', $false)
            $script:service.SetPartitionDriveLetter(0, $created.PartitionNumber, 'S')

            $row = @($script:service.GetPartition() | Where-Object { $_.PartitionNumber -eq $created.PartitionNumber })
            $row[0].DriveLetter | Should -BeExactly 'S'
        }

        It 'removes a drive letter when it is given an empty string' {
            $created = $script:service.NewPartition(0, 272629760, $false, '', $false)
            $script:service.SetPartitionDriveLetter(0, $created.PartitionNumber, 'S')
            $script:service.SetPartitionDriveLetter(0, $created.PartitionNumber, '')

            $row = @($script:service.GetPartition() | Where-Object { $_.PartitionNumber -eq $created.PartitionNumber })
            $row[0].DriveLetter | Should -BeExactly ''
        }

        It 'throws for a partition number that does not exist' {
            { $script:service.SetPartitionDriveLetter(0, 99, 'S') } |
                Should -Throw -ExceptionType ([System.ArgumentOutOfRangeException])
        }

        It 'changes a partition type' {
            $created = $script:service.NewPartition(0, 272629760, $false, '', $false)
            $script:service.SetPartitionType(0, $created.PartitionNumber, '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')

            $row = @($script:service.GetPartition() | Where-Object { $_.PartitionNumber -eq $created.PartitionNumber })
            $row[0].GptType | Should -BeExactly '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
            $row[0].Type | Should -BeExactly 'Recovery'
        }

        It 'formats a volume and records the file system and label' {
            $created = $script:service.NewPartition(0, 0, $true, '', $false)
            $script:service.SetPartitionDriveLetter(0, $created.PartitionNumber, 'W')
            $script:service.FormatVolume('W', 'NTFS', 'Windows')

            @($script:service.GetOperationName())[-1] | Should -BeExactly 'FormatVolume'
            @($script:service.Operations[-1].Arguments) | Should -Be @('W', 'NTFS', 'Windows')
        }

        It 'makes a formatted volume visible to GetVolume' {
            $created = $script:service.NewPartition(0, 0, $true, '', $false)
            $script:service.SetPartitionDriveLetter(0, $created.PartitionNumber, 'W')
            $script:service.FormatVolume('W', 'NTFS', 'Windows')

            $volume = @($script:service.GetVolume() | Where-Object { $_.DriveLetter -eq 'W' })
            $volume.Count | Should -Be 1
            $volume[0].FileSystem | Should -BeExactly 'NTFS'
            $volume[0].FileSystemLabel | Should -BeExactly 'Windows'
            $volume[0].SizeBytes | Should -Be $created.SizeBytes
        }

        It 'throws when it is asked to format a drive letter that no partition holds' {
            { $script:service.FormatVolume('Q', 'NTFS', 'Nothing') } |
                Should -Throw -ExceptionType ([System.ArgumentException])
        }

        It 'records FormatVolume before it throws' {
            try { $script:service.FormatVolume('Q', 'NTFS', 'Nothing') } catch { $null = $_ }

            @($script:service.GetOperationName())[-1] | Should -BeExactly 'FormatVolume'
        }
    }

    Context 'it never touches a real disk' {

        It 'does not enumerate the real machine' {
            $service = New-HDTFakeDiskService -Disk @([pscustomobject] @{
                    Number       = 7
                    FriendlyName = 'HDT Fictional Disk'
                    SizeBytes    = [long] 1024
                })

            @($service.GetDisk()).Count | Should -Be 1
            @($service.GetDisk() | Where-Object { $_.FriendlyName -like 'SAMSUNG*' }).Count | Should -Be 0
        }

        It 'leaves the host disk untouched' -Skip:(-not $script:HDTHasStorage) {
            # THIS IS THE TEST THE FAKE EXISTS FOR. Clearing disk 0 on a fake
            # seeded from this machine's own captured row must leave this
            # machine's own disk 0 exactly as it was - partitions and all.
            $before = @(Get-Disk -Number 0)

            $service = New-HDTFakeDiskService -FixturePath (Join-Path -Path $script:diskFixture -ChildPath 'host-nvme-disk.json')
            $service.ClearDisk(0)

            $after = @(Get-Disk -Number 0)
            $after[0].PartitionStyle | Should -BeExactly $before[0].PartitionStyle
            $after[0].PartitionStyle | Should -BeExactly 'GPT'
            $after[0].IsBoot | Should -BeTrue
            @(Get-Partition -DiskNumber 0).Count | Should -BeGreaterThan 0
        }
    }

    Context 'journal' {

        It 'records into a shared journal as DiskService' {
            $journal = [System.Collections.ArrayList]::new()
            $service = New-HDTFakeDiskService -Disk @(& $script:NewRawDisk) -Journal $journal

            $service.GetDisk() | Out-Null
            $service.InitializeDisk(0, 'GPT')

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('DiskService.GetDisk', 'DiskService.InitializeDisk')
        }

        It 'does not record seeding' {
            $journal = [System.Collections.ArrayList]::new()
            $service = New-HDTFakeDiskService -FixturePath $script:diskFixture -Journal $journal
            $service.SeedDisk((& $script:NewRawDisk))

            @($journal).Count | Should -Be 0
            @($service.Operations).Count | Should -Be 0
        }
    }

    Context 'ambiguity' {

        It 'refuses to act when two seeded disks carry the same number' {
            # tests/fixtures/disk/ is a CATALOGUE of rows, not a snapshot of one
            # machine: the host disk and the derived Gen2 VM disk are both
            # number 0. A fake that silently picked one would be lying about
            # which disk a step wiped, and DESIGN 9.1 is the rule that HDT
            # refuses ambiguous targets rather than guessing.
            $service = New-HDTFakeDiskService -FixturePath $script:diskFixture

            { $service.ClearDisk(0) } | Should -Throw -ExpectedMessage '*ambiguous*'
        }
    }
}
