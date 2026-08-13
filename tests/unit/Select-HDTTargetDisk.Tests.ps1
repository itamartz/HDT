# Select-HDTTargetDisk is DESIGN 9.1's refusal to guess, and ROADMAP M3 says it
# gets the most tests in the phase: "wiping the wrong disk is the single most
# destructive failure mode in this class of tool".
#
# It is pure logic over the three flat listings IDiskService returns, so every
# test here runs with no disk attached and nothing mounted. The rows are built by
# a local helper seeded from tests/fixtures/disk/ wherever a real shape matters -
# in particular host-nvme-disk.json, which is THIS machine's real row, IsBoot and
# IsSystem both true. If a change ever lets that row be selected, the suite goes
# red before the developer's workstation does.
#
# Seven exclusion rules, in two classes:
#
#   1 IsSystem / IsBoot          absolute - not overridable by -DiskNumber
#   2 a protected drive letter   absolute
#   3 IsReadOnly                 absolute
#   4 IsOffline                  absolute
#   5 existing data              absolute unless -AllowExistingData
#   6 BusType USB                overridable by -DiskNumber, with a warning
#   7 under the minimum size     overridable by -DiskNumber, with a warning
#
# SPIKES S6: a Gen2 VM's system disk reports BusType = SAS, not SCSI or Virtual.
# No rule may filter on bus type expecting a VM-specific value; USB is the only
# bus type that excludes anything.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:diskFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/disk'

    function Get-HDTTestDiskFixture {
        <#
            .SYNOPSIS
                Reads one tests/fixtures/disk row set and returns it as an array.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string] $Name
        )

        # F12 (tests/helpers/README.md): assign first, wrap second. Under Windows
        # PowerShell 5.1 ConvertFrom-Json writes a top-level array to the pipeline
        # WITHOUT enumerating it, so @(ConvertFrom-Json ...) is one element.
        $text = Get-Content -LiteralPath (Join-Path -Path $script:diskFixtureRoot -ChildPath $Name) -Raw
        $content = ConvertFrom-Json -InputObject $text
        return , ([object[]] @($content))
    }

    function New-HDTTestDiskRow {
        <#
            .SYNOPSIS
                Builds one IDiskService GetDisk() row, in the shape 04-01 fixed.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory row for a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [int] $Number,

            [Parameter()]
            [string] $FriendlyName = 'Msft Virtual Disk',

            [Parameter()]
            [long] $SizeBytes = 68719476736,

            # SPIKES S6: a Gen2 VM's own system disk reports SAS. The default is
            # deliberately the value that would break a bus-type filter.
            [Parameter()]
            [string] $BusType = 'SAS',

            [Parameter()]
            [string] $PartitionStyle = 'RAW',

            [Parameter()]
            [bool] $IsBoot = $false,

            [Parameter()]
            [bool] $IsSystem = $false,

            [Parameter()]
            [bool] $IsReadOnly = $false,

            [Parameter()]
            [bool] $IsOffline = $false
        )

        return [pscustomobject] @{
            Number            = $Number
            FriendlyName      = $FriendlyName
            SerialNumber      = 'FIXTURE-SERIAL-0001'
            SizeBytes         = $SizeBytes
            BusType           = $BusType
            PartitionStyle    = $PartitionStyle
            IsBoot            = $IsBoot
            IsSystem          = $IsSystem
            IsReadOnly        = $IsReadOnly
            IsOffline         = $IsOffline
            OperationalStatus = 'Online'
        }
    }

    function New-HDTTestPartitionRow {
        <#
            .SYNOPSIS
                Builds one IDiskService GetPartition() row.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory row for a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [int] $DiskNumber,

            [Parameter(Mandatory = $true, Position = 1)]
            [int] $PartitionNumber,

            [Parameter()]
            [string] $DriveLetter = '',

            [Parameter()]
            [long] $SizeBytes = 68719476736,

            [Parameter()]
            [string] $Type = 'Basic'
        )

        return [pscustomobject] @{
            DiskNumber      = $DiskNumber
            PartitionNumber = $PartitionNumber
            DriveLetter     = $DriveLetter
            SizeBytes       = $SizeBytes
            OffsetBytes     = 1048576
            Type            = $Type
            GptType         = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
            IsActive        = $false
            IsHidden        = $false
            IsBoot          = $false
            IsSystem        = $false
        }
    }

    function New-HDTTestVolumeRow {
        <#
            .SYNOPSIS
                Builds one IDiskService GetVolume() row.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory row for a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string] $DriveLetter,

            [Parameter()]
            [string] $FileSystem = 'NTFS',

            [Parameter()]
            [string] $FileSystemLabel = 'Data'
        )

        return [pscustomobject] @{
            DriveLetter        = $DriveLetter
            FileSystem         = $FileSystem
            FileSystemLabel    = $FileSystemLabel
            SizeBytes          = 68719476736
            SizeRemainingBytes = 34359738368
        }
    }
}

Describe 'Select-HDTTargetDisk' {

    Context 'the happy path' {

        It 'returns the only disk when there is exactly one candidate' {
            $disk = @(New-HDTTestDiskRow -Number 0)

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 0
        }

        It 'returns a disk whose bus type is SAS' {
            # SPIKES S6. Every Gen2 VM HDT is developed against reports SAS, so a
            # rule expecting Virtual or SCSI would reject the whole lab.
            $disk = Get-HDTTestDiskFixture -Name 'gen2-vm-raw-disk.json'

            $selected = Select-HDTTargetDisk -Disk $disk

            $selected.BusType | Should -BeExactly 'SAS'
            $selected.Number | Should -Be 0
        }

        It 'returns a RAW disk' {
            $disk = @(New-HDTTestDiskRow -Number 0 -PartitionStyle 'RAW')

            (Select-HDTTargetDisk -Disk $disk).PartitionStyle | Should -BeExactly 'RAW'
        }

        It 'returns a disk with a GPT style and no volumes' {
            $disk = @(New-HDTTestDiskRow -Number 0 -PartitionStyle 'GPT')

            (Select-HDTTargetDisk -Disk $disk -Partition @() -Volume @()).Number | Should -Be 0
        }

        It 'returns the disk row, not its number' {
            $disk = @(New-HDTTestDiskRow -Number 0 -FriendlyName 'Contoso NVMe')

            $selected = Select-HDTTargetDisk -Disk $disk

            $selected | Should -Not -BeOfType ([int])
            $selected.FriendlyName | Should -BeExactly 'Contoso NVMe'
        }

        It 'returns exactly one row' {
            $disk = @(New-HDTTestDiskRow -Number 0)

            @(Select-HDTTargetDisk -Disk $disk).Count | Should -Be 1
        }
    }

    Context 'a disk this machine is running from' {

        It 'never selects a disk marked IsSystem' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0 -IsSystem $true),
                (New-HDTTestDiskRow -Number 1)
            )

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 1
        }

        It 'never selects a disk marked IsBoot' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0 -IsBoot $true),
                (New-HDTTestDiskRow -Number 1)
            )

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 1
        }

        It 'never selects this machine, whose real row is the fixture' {
            # tests/fixtures/disk/host-nvme-disk.json is this host, captured:
            # IsBoot true, IsSystem true. The developer's workstation.
            $disk = Get-HDTTestDiskFixture -Name 'host-nvme-disk.json'

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            # "It threw" is not an assertion - a missing command throws too.
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
            $record.Exception.Message | Should -BeLike '*booted from*'
        }

        It 'refuses an explicit diskNumber naming the boot disk' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 0 } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
        }

        It 'says the disk is the one the machine booted from' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsSystem $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 0 } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*disk 0 is the disk this machine booted from*'
        }

        It 'refuses the boot disk even when it is the only disk' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true -IsSystem $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
        }
    }

    Context 'the disk the deployment is reading from' {

        It 'excludes a disk holding a protected drive letter' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            )
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'Z')

            (Select-HDTTargetDisk -Disk $disk -Partition $partition -ProtectDriveLetter 'Z').Number | Should -Be 0
        }

        It 'matches a protected drive letter case-insensitively' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            )
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'z')

            (Select-HDTTargetDisk -Disk $disk -Partition $partition -ProtectDriveLetter 'Z:').Number | Should -Be 0
        }

        It 'refuses an explicit diskNumber naming a protected disk' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'Z')

            $record = $null
            try {
                Select-HDTTargetDisk -Disk $disk -Partition $partition -ProtectDriveLetter 'Z' -DiskNumber 1 -AllowExistingData
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
        }

        It 'names the protected letter in the refusal' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'Z')

            $record = $null
            try {
                Select-HDTTargetDisk -Disk $disk -Partition $partition -ProtectDriveLetter 'Z' -DiskNumber 1 -AllowExistingData
            } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*Z*'
            $record.Exception.Message | Should -BeLike '*disk 1*'
        }
    }

    Context 'multiple candidates' {

        It 'refuses when two disks qualify' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTAmbiguousTargetError*'
        }

        It 'lists every candidate number in the refusal' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*disk 1*'
            $record.Exception.Message | Should -BeLike '*disk 2*'
        }

        It 'tells the author to set diskNumber' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*diskNumber*'
        }

        It 'proceeds when an explicit diskNumber picks one of them' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2)
            )

            (Select-HDTTargetDisk -Disk $disk -DiskNumber 2).Number | Should -Be 2
        }

        It 'refuses when three disks qualify' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2),
                (New-HDTTestDiskRow -Number 3)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTAmbiguousTargetError*'
            $record.Exception.Message | Should -BeLike '*disk 3*'
        }
    }

    Context 'existing data' {

        It 'excludes a disk carrying a formatted volume' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            )
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'D')
            $volume = @(New-HDTTestVolumeRow -DriveLetter 'D')

            (Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume).Number | Should -Be 0
        }

        It 'includes that disk when AllowExistingData is set' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'D')
            $volume = @(New-HDTTestVolumeRow -DriveLetter 'D')

            (Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume -AllowExistingData).Number |
                Should -Be 1
        }

        It 'treats a RAW disk with no volume as empty' {
            $disk = @(New-HDTTestDiskRow -Number 0 -PartitionStyle 'RAW')

            (Select-HDTTargetDisk -Disk $disk -Partition @() -Volume @()).Number | Should -Be 0
        }

        It 'names the volumes it found in the refusal' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'D')
            $volume = @(New-HDTTestVolumeRow -DriveLetter 'D' -FileSystem 'NTFS')

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*D*'
            $record.Exception.Message | Should -BeLike '*NTFS*'
        }

        It 'refuses an explicit diskNumber on a disk with data when wipe was not declared' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 1 -PartitionNumber 1 -DriveLetter 'D')
            $volume = @(New-HDTTestVolumeRow -DriveLetter 'D')

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume -DiskNumber 1 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
        }

        It 'ignores a partition on another disk when judging existing data' {
            $disk = @(New-HDTTestDiskRow -Number 1 -PartitionStyle 'GPT')
            $partition = @(New-HDTTestPartitionRow -DiskNumber 7 -PartitionNumber 1 -DriveLetter 'D')
            $volume = @(New-HDTTestVolumeRow -DriveLetter 'D')

            (Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume).Number | Should -Be 1
        }
    }

    Context 'USB and size' {

        It 'excludes a USB disk' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -BusType 'USB')
            )

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 0
        }

        It 'excludes a disk under the minimum size' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -SizeBytes 8589934592)
            )

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 0
        }

        It 'defaults the minimum size to 60GB' {
            $justUnder = @(New-HDTTestDiskRow -Number 0 -SizeBytes 64424509439)
            $exactly = @(New-HDTTestDiskRow -Number 0 -SizeBytes 64424509440)

            $record = $null
            try { Select-HDTTargetDisk -Disk $justUnder } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
            (Select-HDTTargetDisk -Disk $exactly).Number | Should -Be 0
        }

        It 'honours an explicit MinimumSizeByte' {
            $disk = @(New-HDTTestDiskRow -Number 0 -SizeBytes 8589934592)

            (Select-HDTTargetDisk -Disk $disk -MinimumSizeByte 4294967296).Number | Should -Be 0
        }

        It 'selects a USB disk when it is named explicitly' {
            $disk = @(New-HDTTestDiskRow -Number 1 -BusType 'USB')

            $selected = Select-HDTTargetDisk -Disk $disk -DiskNumber 1 -WarningAction SilentlyContinue

            $selected.Number | Should -Be 1
        }

        It 'warns when an explicit disk is a USB disk' {
            $disk = @(New-HDTTestDiskRow -Number 1 -BusType 'USB')

            $warning = @()
            $null = Select-HDTTargetDisk -Disk $disk -DiskNumber 1 -WarningVariable warning -WarningAction SilentlyContinue

            @($warning).Count | Should -BeGreaterThan 0
            [string] $warning | Should -BeLike '*USB*'
        }

        It 'warns when an explicit disk is under the minimum size' {
            $disk = @(New-HDTTestDiskRow -Number 1 -SizeBytes 8589934592)

            $warning = @()
            $selected = Select-HDTTargetDisk -Disk $disk -DiskNumber 1 -WarningVariable warning -WarningAction SilentlyContinue

            $selected.Number | Should -Be 1
            @($warning).Count | Should -BeGreaterThan 0
        }

        It 'excludes an offline disk' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0),
                (New-HDTTestDiskRow -Number 1 -IsOffline $true)
            )

            (Select-HDTTargetDisk -Disk $disk).Number | Should -Be 0
        }

        It 'excludes a read-only disk' {
            # tests/fixtures/disk/host-vhdx-disk.json is a real read-only mount.
            $disk = @(New-HDTTestDiskRow -Number 0) + (Get-HDTTestDiskFixture -Name 'host-vhdx-disk.json')

            (Select-HDTTargetDisk -Disk $disk -AllowExistingData).Number | Should -Be 0
        }

        It 'refuses an explicit diskNumber naming an offline disk' {
            # HDT cannot online a disk - IDiskService has no method for it - and
            # pretending otherwise fails later and less clearly.
            $disk = @(New-HDTTestDiskRow -Number 1 -IsOffline $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 1 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
            $record.Exception.Message | Should -BeLike '*offline*'
        }

        It 'refuses an explicit diskNumber naming a read-only disk' {
            $disk = @(New-HDTTestDiskRow -Number 1 -IsReadOnly $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 1 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTUnsafeTargetError*'
            $record.Exception.Message | Should -BeLike '*read-only*'
        }
    }

    Context 'nothing to select' {

        It 'refuses when the machine has no disk at all' {
            $record = $null
            try { Select-HDTTargetDisk -Disk @() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
        }

        It 'lists every disk and its reason when nothing qualifies' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0 -IsBoot $true),
                (New-HDTTestDiskRow -Number 1 -BusType 'USB'),
                (New-HDTTestDiskRow -Number 2 -SizeBytes 8589934592)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*disk 0*'
            $record.Exception.Message | Should -BeLike '*disk 1*'
            $record.Exception.Message | Should -BeLike '*disk 2*'
            $record.Exception.Message | Should -BeLike '*booted from*'
            $record.Exception.Message | Should -BeLike '*USB*'
        }

        It 'throws HDTNoTargetDiskError' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTNoTargetDiskError*'
        }
    }

    Context 'an unknown disk number' {

        It 'throws HDTConfigurationError for a number no disk has' {
            $disk = @(New-HDTTestDiskRow -Number 0)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 5 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'lists the numbers that do exist' {
            $disk = @(
                (New-HDTTestDiskRow -Number 0 -IsBoot $true),
                (New-HDTTestDiskRow -Number 3)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 5 } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*0*'
            $record.Exception.Message | Should -BeLike '*3*'
        }
    }

    Context 'error identity' {

        It 'throws HDTAmbiguousTargetError with that error id' {
            $disk = @(
                (New-HDTTestDiskRow -Number 1),
                (New-HDTTestDiskRow -Number 2)
            )

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeExactly 'HDTAmbiguousTargetError,Select-HDTTargetDisk'
        }

        It 'throws HDTUnsafeTargetError with that error id' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 0 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeExactly 'HDTUnsafeTargetError,Select-HDTTargetDisk'
        }

        It 'throws HDTNoTargetDiskError with that error id' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeExactly 'HDTNoTargetDiskError,Select-HDTTargetDisk'
        }

        It 'carries the disk number as the TargetObject' {
            $disk = @(New-HDTTestDiskRow -Number 0 -IsBoot $true)

            $record = $null
            try { Select-HDTTargetDisk -Disk $disk -DiskNumber 0 } catch { $record = $_ }

            $record.TargetObject | Should -Be 0
        }
    }

    Context 'purity' {

        It 'performs no I/O' {
            # It is handed rows. Reading them from a fake proves the point twice:
            # the fake records nothing after the listings, and no real Storage
            # cmdlet is anywhere in the call.
            $fake = New-HDTFakeDiskService -Disk @(New-HDTTestDiskRow -Number 0)
            $row = $fake.GetDisk()
            $before = @($fake.GetOperationName()).Count

            $null = Select-HDTTargetDisk -Disk $row

            @($fake.GetOperationName()).Count | Should -Be $before
        }

        It 'takes no disk service parameter' {
            $command = Get-Command -Name Select-HDTTargetDisk -ErrorAction Stop

            # Assert the command resolved first: Get-Command writes a
            # non-terminating error by default, and $null.Parameters.Keys would
            # satisfy the -Not -Contain below for a command that does not exist.
            $command.Name | Should -BeExactly 'Select-HDTTargetDisk'
            $command.Parameters.Keys | Should -Not -Contain 'DiskService'
        }

        It 'does not mutate the rows it was given' {
            $disk = @(New-HDTTestDiskRow -Number 0 -PartitionStyle 'RAW')
            $before = @($disk[0].PSObject.Properties.Name)

            $null = Select-HDTTargetDisk -Disk $disk

            $disk[0].PartitionStyle | Should -BeExactly 'RAW'
            $disk[0].Number | Should -Be 0
            @($disk[0].PSObject.Properties.Name) | Should -Be $before
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            # tests/helpers/README.md section 12: assert the NAME first. Get-Help
            # falls back to a fuzzy search and will happily return a sibling
            # command's help for a command that does not exist.
            $help = Get-Help -Name Select-HDTTargetDisk -ErrorAction Stop

            $help.Name | Should -BeExactly 'Select-HDTTargetDisk'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
