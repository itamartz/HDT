# The IDiskService contract (PROJECT constraint 4, DESIGN 9.1, DESIGN 12.2.1).
#
# Nine methods:
#
#   GetDisk()      -> object[]   every disk on the machine
#   GetPartition() -> object[]   every partition on every disk
#   GetVolume()    -> object[]   every volume with a drive letter
#
#   ClearDisk(diskNumber)
#   InitializeDisk(diskNumber, partitionStyle)
#   NewPartition(diskNumber, sizeByte, useMaximumSize, gptType, isActive) -> the row
#   SetPartitionDriveLetter(diskNumber, partitionNumber, driveLetter)
#   SetPartitionType(diskNumber, partitionNumber, gptType)
#   FormatVolume(driveLetter, fileSystem, label)
#
# The three listings are FLAT - no filters and no joins - so the joining is done
# by pure logic that can be tested rather than by an adapter that cannot.
#
# THE REAL ROW IS OPT-IN AND READ-ONLY, AND THE SUITE NEVER WRITES TO A DISK.
#
# This host has ONE physical disk - a 1 TB NVMe with IsBoot and IsSystem both
# true - so the developer machine is the disk most likely to be in front of this
# code. The real row therefore runs only when BOTH conditions hold:
#
#   * the session is elevated, and
#   * $env:HDT_ALLOW_DISK_TEST -eq '1'
#
# and even then it calls only GetDisk, GetPartition and GetVolume, plus
# ClearDisk(-1). THAT LAST ONE IS SAFE FOR TWO INDEPENDENT REASONS: -1 cannot
# name a disk on any machine, and New-HDTDiskService resolves the disk first and
# throws ArgumentOutOfRangeException from its guard, so Clear-Disk is never
# invoked at all. It is how "records before it can throw" is proven against both
# implementations.
#
# THE DESTRUCTIVE HALF IS PROVEN IN tests/integration (04-04), AGAINST A MOUNTED
# SCRATCH VHDX, AND MUST NEVER BE PROVEN AGAINST WHATEVER DISK THE DEVELOPER
# HAPPENS TO HAVE.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9). $IsWindows does not exist under Windows
# PowerShell 5.1, hence [System.Environment]::OSVersion.Platform.

$script:HDTElevated = $false
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    $script:HDTElevated = ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:HDTAllowRealDisk = ($script:HDTElevated -and $env:HDT_ALLOW_DISK_TEST -eq '1')

if (-not $script:HDTAllowRealDisk) {
    Write-Warning ("IDiskService: the real adapter row is skipped. It runs only when the session is elevated (currently {0}) AND `$env:HDT_ALLOW_DISK_TEST is '1' (currently '{1}'). Even then it only enumerates - the suite never clears, initialises, partitions or formats a physical disk." -f $script:HDTElevated, $env:HDT_ALLOW_DISK_TEST)
}

$script:HDTImplementation = @(
    @{
        Name           = 'FakeDiskService'
        Factory        = { param($RepositoryRoot) New-HDTFakeDiskService -FixturePath (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/disk') }
        JournalFactory = { param($Journal) New-HDTFakeDiskService -Journal $Journal }
        Skip           = $false
    }
    @{
        Name           = 'DiskService'
        Factory        = { New-HDTDiskService }
        JournalFactory = { param($Journal) New-HDTDiskService -Journal $Journal }
        Skip           = -not $script:HDTAllowRealDisk
    }
)

Describe 'IDiskService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        $script:HDTDiskProperty = @('Number', 'FriendlyName', 'SerialNumber', 'SizeBytes', 'BusType',
            'PartitionStyle', 'IsBoot', 'IsSystem', 'IsReadOnly', 'IsOffline', 'OperationalStatus')
        $script:HDTPartitionProperty = @('DiskNumber', 'PartitionNumber', 'DriveLetter', 'SizeBytes',
            'OffsetBytes', 'Type', 'GptType', 'IsActive', 'IsHidden', 'IsBoot', 'IsSystem')
        $script:HDTVolumeProperty = @('DriveLetter', 'FileSystem', 'FileSystemLabel', 'SizeBytes',
            'SizeRemainingBytes')
    }

    Context 'read only' -Skip:$Skip {

        BeforeEach {
            $script:disk = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Get-Member -MemberType Method does NOT list a ScriptMethod, and the
            # real adapter is a pscustomobject carrying ScriptMethod members.
            $method = @($script:disk | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('GetDisk', 'GetPartition', 'GetVolume', 'ClearDisk', 'InitializeDisk',
                    'NewPartition', 'SetPartitionDriveLetter', 'SetPartitionType', 'FormatVolume')) {
                $method | Should -Contain $name -Because "IDiskService requires $name"
            }
        }

        It 'names itself DiskService' {
            $script:disk.ServiceName | Should -BeExactly 'DiskService'
        }

        It 'returns an array from GetDisk even for one disk' {
            # tests/helpers/README.md F3: without the unary comma a ScriptMethod
            # collapses a one-element array to a scalar, and this machine has
            # exactly one disk.
            $script:disk.GetDisk() -is [System.Array] | Should -BeTrue
        }

        It 'returns an array from GetPartition' {
            $script:disk.GetPartition() -is [System.Array] | Should -BeTrue
        }

        It 'returns an array from GetVolume' {
            $script:disk.GetVolume() -is [System.Array] | Should -BeTrue
        }

        It 'reports at least one disk' {
            @($script:disk.GetDisk()).Count | Should -BeGreaterThan 0
        }

        It 'gives every disk row the eleven documented properties' {
            foreach ($row in @($script:disk.GetDisk())) {
                $name = @($row.PSObject.Properties.Name)
                foreach ($expected in $script:HDTDiskProperty) {
                    $name | Should -Contain $expected -Because "a disk row carries $expected"
                }
            }
        }

        It 'gives every partition row its documented properties' {
            foreach ($row in @($script:disk.GetPartition())) {
                $name = @($row.PSObject.Properties.Name)
                foreach ($expected in $script:HDTPartitionProperty) {
                    $name | Should -Contain $expected -Because "a partition row carries $expected"
                }
            }
        }

        It 'gives every volume row its documented properties' {
            foreach ($row in @($script:disk.GetVolume())) {
                $name = @($row.PSObject.Properties.Name)
                foreach ($expected in $script:HDTVolumeProperty) {
                    $name | Should -Contain $expected -Because "a volume row carries $expected"
                }
            }
        }

        It 'types Number as an integer and SizeBytes as a long' {
            foreach ($row in @($script:disk.GetDisk())) {
                $row.Number | Should -BeOfType ([int])
                $row.SizeBytes | Should -BeOfType ([long])
            }
        }

        It 'types a partition offset as a long' {
            foreach ($row in @($script:disk.GetPartition())) {
                $row.DiskNumber | Should -BeOfType ([int])
                $row.PartitionNumber | Should -BeOfType ([int])
                $row.OffsetBytes | Should -BeOfType ([long])
            }
        }

        It 'reports a partition style from the closed set' {
            foreach ($row in @($script:disk.GetDisk())) {
                @('RAW', 'MBR', 'GPT') | Should -Contain $row.PartitionStyle
            }
        }

        It 'gives every volume it reports a drive letter' {
            foreach ($row in @($script:disk.GetVolume())) {
                $row.DriveLetter | Should -Not -BeNullOrEmpty
            }
        }

        It 'records GetDisk' {
            $script:disk.GetDisk() | Out-Null

            @($script:disk.GetOperationName()) | Should -Be @('GetDisk')
        }

        It 'records the three listings in the order they were called' {
            $script:disk.GetVolume() | Out-Null
            $script:disk.GetDisk() | Out-Null
            $script:disk.GetPartition() | Out-Null

            @($script:disk.GetOperationName()) | Should -Be @('GetVolume', 'GetDisk', 'GetPartition')
        }

        It 'throws ArgumentOutOfRangeException for a disk number that does not exist' {
            # The real row uses -1, which cannot name a disk on any machine, and
            # the adapter's existence guard throws before Clear-Disk is reached.
            $record = $null
            try { $script:disk.ClearDisk(-1) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            # Unwrapped to the innermost exception: a fake throws the type
            # directly, a ScriptMethod on a pscustomobject wraps it twice
            # (tests/helpers/README.md section 5).
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.ArgumentOutOfRangeException])
        }

        It 'records ClearDisk before it can throw' {
            try { $script:disk.ClearDisk(-1) } catch { $null = $_ }

            @($script:disk.GetOperationName()) | Should -Be @('ClearDisk')
            @($script:disk.Operations[0].Arguments)[0] | Should -Be -1
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $service = & $JournalFactory $journal
            $service.GetDisk() | Out-Null
            $service.GetVolume() | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('DiskService.GetDisk', 'DiskService.GetVolume')
        }
    }
}
