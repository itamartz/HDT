function New-HDTDiskService {
    <#
        .SYNOPSIS
            Creates the real IDiskService adapter over the Storage module.

        .DESCRIPTION
            The one place in HDT that names Get-Disk, Clear-Disk,
            Initialize-Disk, New-Partition, Set-Partition, Format-Volume or
            Remove-PartitionAccessPath. PROJECT constraint 4 forbids a step from
            touching hardware directly, so DiskPartition and everything after it
            receives this object and can be swapped for New-HDTFakeDiskService
            in a test with no disk attached - which matters more here than
            anywhere else in HDT, because the developer machine is the disk most
            likely to be in front of this code.

            The Storage module is present in WinPE (proven by
            SPIKES.md S1's WinPE-StorageWMI image).

            NINE METHODS, THREE OF THEM READ-ONLY:

              GetDisk()      -> object[]   every disk on the machine
              GetPartition() -> object[]   every partition on every disk
              GetVolume()    -> object[]   every volume with a drive letter

              ClearDisk(diskNumber)
              InitializeDisk(diskNumber, partitionStyle)
              NewPartition(diskNumber, sizeByte, useMaximumSize, gptType, isActive)
              SetPartitionDriveLetter(diskNumber, partitionNumber, driveLetter)
              SetPartitionType(diskNumber, partitionNumber, gptType)
              FormatVolume(driveLetter, fileSystem, label)

            THE THREE LISTINGS ARE FLAT - NO FILTERS AND NO JOINS - the same
            decision ICimProvider made when it refused a -Filter. A partition row
            carries its DiskNumber and a volume row carries its DriveLetter, so
            the pure logic that selects a disk does the joining and this file
            stays a projection of three cmdlets. An adapter that filtered would
            be an adapter with a branch in it.

            THIS FILE MUST NEVER CREATE A MICROSOFT RESERVED PARTITION.
            Initialize-Disk -PartitionStyle GPT silently creates a 16 MB MSR of
            its own. PSD's Scripts/PSDPartition.ps1 initialises GPT on line 97
            and then creates an MSR by hand on line 116, which is exactly the
            duplicate 16 MB partition SPIKES.md S6 recorded. The working recipe
            the spike proved is Clear-Disk -RemoveData -RemoveOEM, then
            Initialize-Disk, and then ESP / Windows / Recovery - with no MSR
            created by us. Mine PSD for its GUIDs, not for its sequence.

            THIS IS AN UNTESTED ADAPTER, and deliberately so:
            there is no way to unit test the destructive half that does not
            write to a physical disk. Its contract row is opt-in - elevated AND
            $env:HDT_ALLOW_DISK_TEST -eq '1' - and even then read-only; the
            destructive half is proven in tests/integration against a mounted
            scratch VHDX. The price of not testing it is that it must stay dumb.
            THE ONLY BRANCHES BELOW ARE EXISTENCE GUARDS AND ARGUMENT
            CONSTRUCTION, each commented as such. Every decision about WHICH
            disk to wipe lives in the DiskPartition step, which is tested against
            the fake. Do not add logic here.

            The existence guards are not decoration. They give the two
            implementations of IDiskService the same failure for the same
            mistake - ArgumentOutOfRangeException for a disk or partition number
            that is not there - and they mean a call naming a disk that does not
            exist never reaches Clear-Disk at all.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the nine
            IDiskService ScriptMethods. Note that Get-Member -MemberType Method
            does NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $disk = New-HDTDiskService
            @($disk.GetDisk() | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })

            Every disk that is not the one this machine booted from. HDT
            requires exactly one candidate before anything is wiped.

        .EXAMPLE
            $disk = New-HDTDiskService
            $disk.GetPartition() | Format-Table DiskNumber, PartitionNumber, Type, GptType

            The partition table, flat, with each row naming its own disk.

        .NOTES
            The GPT partition type GUIDs this service is called with come from
            PSD's Scripts/PSDPartition.ps1 (MIT, see NOTICE.md), cross-checked
            against this machine's own captured tests/fixtures/disk/host-partition.json:

              {c12a7328-f81f-11d2-ba4b-00a0c93ec93b}  EFI System
              {e3c9e316-0b5c-4db8-817d-f92df00215ae}  Microsoft Reserved
              {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}  Basic data
              {de94bba4-06d1-4d40-a16a-bfd50179d6ac}  Windows Recovery
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The destructive methods it exposes are called by DiskPartition, which carries SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'DiskService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    # Get-Partition and Get-Volume report an absent drive letter as [char] 0,
    # which is not an empty string and not whitespace. This is the null guard
    # that turns it into one.
    $service | Add-Member -MemberType ScriptMethod -Name ToLetter -Value {
        param([object] $Value)

        if ($Value) {
            return [string] $Value
        }

        return ''
    }

    $service | Add-Member -MemberType ScriptMethod -Name ToDiskRow -Value {
        param([object] $Disk)

        return [pscustomobject] @{
            Number            = [int] $Disk.Number
            FriendlyName      = [string] $Disk.FriendlyName
            SerialNumber      = [string] $Disk.SerialNumber
            SizeBytes         = [long] $Disk.Size
            BusType           = [string] $Disk.BusType
            PartitionStyle    = [string] $Disk.PartitionStyle
            IsBoot            = [bool] $Disk.IsBoot
            IsSystem          = [bool] $Disk.IsSystem
            IsReadOnly        = [bool] $Disk.IsReadOnly
            IsOffline         = [bool] $Disk.IsOffline
            OperationalStatus = [string] $Disk.OperationalStatus
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name ToPartitionRow -Value {
        param([object] $Partition)

        return [pscustomobject] @{
            DiskNumber      = [int] $Partition.DiskNumber
            PartitionNumber = [int] $Partition.PartitionNumber
            DriveLetter     = [string] $this.ToLetter($Partition.DriveLetter)
            SizeBytes       = [long] $Partition.Size
            OffsetBytes     = [long] $Partition.Offset
            Type            = [string] $Partition.Type
            GptType         = [string] $Partition.GptType
            IsActive        = [bool] $Partition.IsActive
            IsHidden        = [bool] $Partition.IsHidden
            IsBoot          = [bool] $Partition.IsBoot
            IsSystem        = [bool] $Partition.IsSystem
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name ToVolumeRow -Value {
        param([object] $Volume)

        return [pscustomobject] @{
            DriveLetter        = [string] $this.ToLetter($Volume.DriveLetter)
            FileSystem         = [string] $Volume.FileSystem
            FileSystemLabel    = [string] $Volume.FileSystemLabel
            SizeBytes          = [long] $Volume.Size
            SizeRemainingBytes = [long] $Volume.SizeRemaining
        }
    }

    # Existence guard, not logic. It gives this adapter and the fake the same
    # failure for the same mistake, and it means a call naming a disk that is
    # not there never reaches Clear-Disk.
    $service | Add-Member -MemberType ScriptMethod -Name AssertDisk -Value {
        param([int] $DiskNumber)

        # Filtered client-side rather than with -Number, which is a [uint32]:
        # Get-Disk -Number -1 throws System.OverflowException before it queries
        # anything, and the contract requires the same ArgumentOutOfRangeException
        # from both implementations for the same mistake.
        $found = @(Get-Disk | Where-Object { $_.Number -eq $DiskNumber })
        if ($found.Count -eq 0) {
            throw [System.ArgumentOutOfRangeException]::new(
                'DiskNumber', $DiskNumber, "No disk numbered $DiskNumber exists on this machine.")
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name AssertPartition -Value {
        param([int] $DiskNumber, [int] $PartitionNumber)

        # Filtered client-side for the same reason AssertDisk is: -DiskNumber and
        # -PartitionNumber are both [uint32].
        $found = @(Get-Partition | Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber })
        if ($found.Count -eq 0) {
            throw [System.ArgumentOutOfRangeException]::new(
                'PartitionNumber', $PartitionNumber,
                "No partition $PartitionNumber on disk $DiskNumber exists on this machine.")
        }

        return $found[0]
    }

    # -- the read-only three -----------------------------------------------
    #
    # They record too: query order is evidence about what the code under test
    # tried, and DESIGN 9.1's refusal to guess is judged on what it looked at.
    # The unary comma is mandatory - without it a ScriptMethod collapses a
    # one-element array to a scalar, and a single-disk machine is the common
    # case (tests/helpers/README.md F3).

    $service | Add-Member -MemberType ScriptMethod -Name GetDisk -Value {
        $this.Record('GetDisk', @())

        return , ([object[]] @(Get-Disk | ForEach-Object { $this.ToDiskRow($_) }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetPartition -Value {
        $this.Record('GetPartition', @())

        return , ([object[]] @(Get-Partition | ForEach-Object { $this.ToPartitionRow($_) }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetVolume -Value {
        $this.Record('GetVolume', @())

        # A volume with no access path is not one IDiskService reports, and
        # Get-Volume returns [char] 0 for it. This is the interface's own
        # definition of the listing rather than a decision taken here.
        return , ([object[]] @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $this.ToVolumeRow($_) }))
    }

    # -- the six that change something --------------------------------------

    $service | Add-Member -MemberType ScriptMethod -Name ClearDisk -Value {
        param([int] $DiskNumber)

        $this.Record('ClearDisk', @($DiskNumber))
        $this.AssertDisk($DiskNumber)

        # SPIKES.md S6: -RemoveData -RemoveOEM is the form that leaves a disk
        # Initialize-Disk will accept.
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }

    $service | Add-Member -MemberType ScriptMethod -Name InitializeDisk -Value {
        param([int] $DiskNumber, [string] $PartitionStyle)

        $this.Record('InitializeDisk', @($DiskNumber, $PartitionStyle))
        $this.AssertDisk($DiskNumber)

        # This creates a 16 MB MSR of its own. Do not create a second one.
        Initialize-Disk -Number $DiskNumber -PartitionStyle $PartitionStyle -ErrorAction Stop
    }

    $service | Add-Member -MemberType ScriptMethod -Name NewPartition -Value {
        param([int] $DiskNumber, [long] $SizeByte, [bool] $UseMaximumSize, [string] $GptType, [bool] $IsActive)

        $this.Record('NewPartition', @($DiskNumber, $SizeByte, $UseMaximumSize, $GptType, $IsActive))
        $this.AssertDisk($DiskNumber)

        # Argument construction, not logic: -Size and -UseMaximumSize are
        # mutually exclusive on New-Partition, an empty GptType means "do not
        # pass -GptType", and -IsActive is a switch that must be absent rather
        # than false on a GPT disk, which rejects it outright.
        # ErrorAction travels in the splat because there is nowhere else to put
        # it: this is the one destructive call here that is splatted. Same rule
        # as its six siblings - a disk operation must not depend on the caller's
        # preference to report that it failed (05-06).
        $argument = @{ DiskNumber = $DiskNumber; ErrorAction = 'Stop' }
        if ($UseMaximumSize) {
            $argument['UseMaximumSize'] = $true
        } else {
            $argument['Size'] = $SizeByte
        }
        if (-not [string]::IsNullOrEmpty($GptType)) {
            $argument['GptType'] = $GptType
        }
        if ($IsActive) {
            $argument['IsActive'] = $true
        }

        return $this.ToPartitionRow((New-Partition @argument))
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetPartitionDriveLetter -Value {
        param([int] $DiskNumber, [int] $PartitionNumber, [string] $DriveLetter)

        $this.Record('SetPartitionDriveLetter', @($DiskNumber, $PartitionNumber, $DriveLetter))
        $existing = $this.AssertPartition($DiskNumber, $PartitionNumber)

        # Argument construction, not logic: an empty letter means "remove the
        # access path", which Set-Partition cannot express - there is no
        # -NewDriveLetter value that clears one.
        if ([string]::IsNullOrEmpty($DriveLetter)) {
            Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber `
                -AccessPath ('{0}:\' -f $this.ToLetter($existing.DriveLetter)) -ErrorAction Stop
            return
        }

        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -NewDriveLetter $DriveLetter -ErrorAction Stop
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetPartitionType -Value {
        param([int] $DiskNumber, [int] $PartitionNumber, [string] $GptType)

        $this.Record('SetPartitionType', @($DiskNumber, $PartitionNumber, $GptType))
        [void] $this.AssertPartition($DiskNumber, $PartitionNumber)

        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -GptType $GptType -ErrorAction Stop
    }

    $service | Add-Member -MemberType ScriptMethod -Name FormatVolume -Value {
        param([string] $DriveLetter, [string] $FileSystem, [string] $Label)

        $this.Record('FormatVolume', @($DriveLetter, $FileSystem, $Label))

        Format-Volume -DriveLetter $DriveLetter -FileSystem $FileSystem `
            -NewFileSystemLabel $Label -Force -Confirm:$false -ErrorAction Stop | Out-Null
    }

    return $service
}
