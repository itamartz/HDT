# The destructive step (DESIGN 9.1, PROJECT constraint 5, SPIKES S6).
#
# "Wiping the wrong disk is the single most destructive failure mode in this
# class of tool." So this file is mostly about what the step does NOT do:
#
#   * it never selects a disk itself - Select-HDTTargetDisk does, and the step
#     always hands it the drive letters of the workspace and the log, so HDT
#     cannot wipe the disk it is reading its own instructions from;
#   * it writes NOTHING when it refuses, and nothing under -WhatIf;
#   * it creates NO Microsoft Reserved partition. SPIKES S6: Initialize-Disk
#     -PartitionStyle GPT creates one itself, and PSD's PSDPartition.ps1 creates
#     a second by hand, which is how the spike ended up with a duplicate 16 MB
#     partition. The fake models that behaviour, so a step that "helpfully"
#     created one produces a duplicate these tests can see.
#
# The verified order - Clear-Disk -RemoveData -RemoveOEM, then Initialize-Disk,
# then the partitions - is asserted from the fake's operation journal rather than
# read out of the source.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $script:reservedType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    $script:basicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $script:recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 2; Name = 'Format and Partition'; Type = 'DiskPartition'
            TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }

    # A disk that has been initialised before but carries no data - the redeploy
    # case, and the one where there IS something to clear. It is GPT rather than
    # RAW ON PURPOSE: 04-04 found that Clear-Disk throws "The disk has not been
    # initialized" on a RAW disk, so a RAW fixture here would be asserting a
    # ClearDisk that cannot happen on a real machine. The factory-fresh RAW case
    # has its own Context below.
    $script:targetDisk = @{
        Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
        BusType = 'SAS'; PartitionStyle = 'GPT'
    }

    $script:secondDisk = @{
        Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
        BusType = 'SAS'; PartitionStyle = 'GPT'
    }

    # The disk a bare-metal machine actually has on its first deployment.
    $script:virginDisk = @{
        Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
        BusType = 'SAS'; PartitionStyle = 'RAW'
    }
}

Describe 'Invoke-HDTDiskPartitionStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 17, [System.DateTimeKind]::Utc))

        $script:newContextFor = {
            param([object] $DiskService, [System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Disk $DiskService

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTIsUEFI'] = $true
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:disk = New-HDTFakeDiskService -Disk @($script:targetDisk)
        $script:context = & $script:newContextFor $script:disk $null
        $script:wipeStep = & $script:newStep ([ordered] @{ layout = 'uefi-standard'; wipe = $true })
    }

    Context 'target selection' {

        It 'partitions the only candidate disk' {
            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'ClearDisk' })[0].Arguments[0] | Should -Be 0
        }

        It 'never selects a disk itself' {
            # The whole file's premise: the step reads the three listings and
            # hands them to Select-HDTTargetDisk. If it filtered them itself,
            # the seven exclusion rules would exist in two places.
            $text = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Steps/Invoke-HDTDiskPartitionStep.ps1') -Raw

            $text | Should -BeLike '*Select-HDTTargetDisk*'
        }

        It 'passes the workspace drive letter as protected' {
            # Asserted through behaviour, not through the argument list: the
            # workspace disk qualifies on every other rule, so if the guard were
            # dropped this would refuse as ambiguous instead of passing.
            $shared = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk) -Partition @(
                @{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'Z'; SizeBytes = 68719476736 })

            $context = & $script:newContextFor $shared $null

            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($shared.Operations | Where-Object { $_.Operation -eq 'ClearDisk' })[0].Arguments[0] | Should -Be 0
        }

        It 'passes the log drive letter as protected' {
            # The log lives on X: in WinPE. A disk carrying X: is the RAM disk
            # or the boot medium, and wiping it mid-run destroys the log that
            # would have said what happened.
            $shared = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk) -Partition @(
                @{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'X'; SizeBytes = 68719476736 })

            $context = & $script:newContextFor $shared $null

            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($shared.Operations | Where-Object { $_.Operation -eq 'ClearDisk' })[0].Arguments[0] | Should -Be 0
        }

        It 'refuses when two disks qualify' {
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk)
            $context = & $script:newContextFor $twin $null

            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTAmbiguousTargetError'
            $result.Message | Should -BeLike '*disk 0*'
            $result.Message | Should -BeLike '*disk 1*'
        }

        It 'writes nothing when it refuses' {
            # THE ASSERTION THAT MATTERS MOST IN THIS FILE.
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk)
            $context = & $script:newContextFor $twin $null

            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context | Out-Null

            foreach ($operation in @($twin.GetOperationName())) {
                $operation | Should -BeLike 'Get*' -Because 'a step that refused must have written nothing at all'
            }
        }

        It 'honours an explicit diskNumber' {
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk)
            $context = & $script:newContextFor $twin $null
            $step = & $script:newStep ([ordered] @{ layout = 'uefi-standard'; wipe = $true; diskNumber = 1 })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($twin.Operations | Where-Object { $_.Operation -eq 'ClearDisk' })[0].Arguments[0] | Should -Be 1
        }

        It 'refuses an explicit diskNumber naming the boot disk' {
            # DESIGN 9.1 rule 1 is absolute: one wrong number in a YAML file must
            # not destroy the machine running the sequence.
            $host0 = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Host disk'; SizeBytes = 512110190592; BusType = 'NVMe'
                    PartitionStyle = 'GPT'; IsBoot = $true; IsSystem = $true
                })

            $context = & $script:newContextFor $host0 $null
            $step = & $script:newStep ([ordered] @{ layout = 'uefi-standard'; wipe = $true; diskNumber = 0 })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTUnsafeTargetError'
            @($host0.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) | Should -BeNullOrEmpty
        }

        It 'refuses a disk with data when wipe is not declared' {
            $used = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'GPT' }
            ) -Partition @(
                @{ DiskNumber = 0; PartitionNumber = 1; DriveLetter = 'D'; SizeBytes = 68719476736 }
            ) -Volume @(
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Data' })

            $context = & $script:newContextFor $used $null
            $step = & $script:newStep ([ordered] @{ layout = 'uefi-standard' })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @($used.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) | Should -BeNullOrEmpty
        }

        It 'proceeds on a disk with data when wipe is true' {
            $used = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'GPT' }
            ) -Partition @(
                @{ DiskNumber = 0; PartitionNumber = 1; DriveLetter = 'D'; SizeBytes = 68719476736 }
            ) -Volume @(
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Data' })

            $context = & $script:newContextFor $used $null

            (Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context).Status | Should -BeExactly 'Completed'
        }
    }

    Context 'a factory-fresh disk' {

        # FOUND BY RUNNING IT AGAINST A REAL DISK (04-04, deviation Rule 1).
        #
        # Clear-Disk throws "The disk has not been initialized." on a RAW disk.
        # A brand-new VHDX is RAW, and so is the disk in a machine that has
        # never been deployed - which is EVERY machine this step exists for. The
        # step used to call ClearDisk unconditionally, so it passed every unit
        # test against a fake that shrugged, and would have failed on the first
        # real bare-metal disk it met.
        #
        # There is nothing to clear on a RAW disk. The step skips it and says so
        # in the log.

        BeforeEach {
            $script:virgin = New-HDTFakeDiskService -Disk @($script:virginDisk)
            $script:virginContext = & $script:newContextFor $script:virgin $null
        }

        It 'partitions a RAW disk' {
            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:virginContext

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'does not try to clear it' {
            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:virginContext | Out-Null

            @($script:virgin.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) |
                Should -BeNullOrEmpty -Because 'Clear-Disk throws "The disk has not been initialized" on a RAW disk'
        }

        It 'initialises it and creates the layout anyway' {
            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:virginContext | Out-Null

            @($script:virgin.GetOperationName()) | Should -Be @(
                'GetDisk'
                'GetPartition'
                'GetVolume'
                'InitializeDisk'            # no ClearDisk: there was nothing to clear
                'NewPartition'
                'SetPartitionDriveLetter'
                'FormatVolume'
                'SetPartitionType'
                'NewPartition'
                'SetPartitionDriveLetter'
                'FormatVolume'
                'NewPartition'
                'SetPartitionDriveLetter'
                'FormatVolume'
                'SetPartitionType'
            )
        }

        It 'still leaves exactly one reserved partition' {
            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:virginContext | Out-Null

            @($script:virgin.Partition | Where-Object { $_.Type -eq 'Reserved' }).Count | Should -Be 1
        }

        It 'records in its data that there was nothing to clear' {
            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:virginContext

            # Contains first: Should -BeFalse is happy with $null, so without it
            # this passes for a key that was never written (helpers README 12).
            $result.Data.Contains('cleared') | Should -BeTrue
            $result.Data['cleared'] | Should -BeFalse
        }

        It 'records in its data that an initialised disk WAS cleared' {
            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context

            $result.Data['cleared'] | Should -BeTrue
        }
    }

    Context 'the layout' {

        It 'uses the layout the step pinned' {
            $step = & $script:newStep ([ordered] @{ layout = 'bios-standard'; wipe = $true })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'InitializeDisk' })[0].Arguments[1] |
                Should -BeExactly 'MBR'
        }

        It 'expands a %Var% in the layout name' {
            $context = & $script:newContextFor $script:disk ([ordered] @{ HDTDiskLayout = 'bios-standard' })
            $step = & $script:newStep ([ordered] @{ layout = '%HDTDiskLayout%'; wipe = $true })

            Invoke-HDTDiskPartitionStep -Step $step -Context $context | Out-Null

            @($script:disk.Operations | Where-Object { $_.Operation -eq 'InitializeDisk' })[0].Arguments[1] |
                Should -BeExactly 'MBR'
        }

        It 'uses HDTDiskLayout when the step pins none' {
            $context = & $script:newContextFor $script:disk ([ordered] @{ HDTDiskLayout = 'bios-standard' })
            $step = & $script:newStep ([ordered] @{ wipe = $true })

            Invoke-HDTDiskPartitionStep -Step $step -Context $context | Out-Null

            @($script:disk.Operations | Where-Object { $_.Operation -eq 'InitializeDisk' })[0].Arguments[1] |
                Should -BeExactly 'MBR'
        }

        It 'falls back to firmware when neither is set' {
            $step = & $script:newStep ([ordered] @{ wipe = $true })

            Invoke-HDTDiskPartitionStep -Step $step -Context $script:context | Out-Null

            @($script:disk.Operations | Where-Object { $_.Operation -eq 'InitializeDisk' })[0].Arguments[1] |
                Should -BeExactly 'GPT'
        }

        It 'fails naming the layout when the name is unknown' {
            $step = & $script:newStep ([ordered] @{ layout = 'uefi-exotic'; wipe = $true })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*uefi-exotic*'
            @($script:disk.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) | Should -BeNullOrEmpty
        }

        It 'fails when the disk is too small for the layout' {
            $tiny = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 8589934592; BusType = 'SAS'; PartitionStyle = 'RAW' })

            $context = & $script:newContextFor $tiny $null
            $step = & $script:newStep ([ordered] @{ layout = 'uefi-standard'; wipe = $true; minDiskGB = 4 })

            $result = Invoke-HDTDiskPartitionStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTConfigurationError'
            @($tiny.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the verified order' {

        BeforeEach {
            $script:result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context
            $script:operation = @($script:disk.GetOperationName())
        }

        It 'clears the disk before initialising it' {
            # SPIKES S6's working recipe: Clear-Disk -RemoveData -RemoveOEM, then
            # Initialize-Disk.
            $script:operation.IndexOf('ClearDisk') | Should -BeLessThan $script:operation.IndexOf('InitializeDisk')
        }

        It 'initialises with the layout partition style' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'InitializeDisk' })[0].Arguments[1] |
                Should -BeExactly 'GPT'
        }

        It 'creates no MSR partition' {
            # SPIKES S6. Initialize-Disk makes the Microsoft Reserved partition;
            # PSDPartition.ps1 makes a second one by hand, which is the duplicate
            # this assertion exists to prevent ever arriving in HDT.
            $created = @($script:disk.Operations | Where-Object { $_.Operation -eq 'NewPartition' })

            @($created | Where-Object { [string] $_.Arguments[3] -eq $script:reservedType }) | Should -BeNullOrEmpty
            @($script:disk.Partition | Where-Object { $_.Type -eq 'Reserved' }).Count | Should -Be 1
        }

        It 'creates the partitions in plan order' {
            @($script:disk.Partition | Where-Object { $_.PartitionNumber -ne 1 } |
                    ForEach-Object { [string] $_.DriveLetter }) | Should -Be @('S', 'W', 'R')
        }

        It 'performs the whole ceremony in this order' {
            $script:operation | Should -Be @(
                'GetDisk'                   # the three flat listings, for the selection
                'GetPartition'
                'GetVolume'
                'ClearDisk'                 # SPIKES S6: -RemoveData -RemoveOEM, before Initialize
                'InitializeDisk'            # GPT; THIS is what creates the MSR
                'NewPartition'              # ESP, created as basic data so it can take a letter
                'SetPartitionDriveLetter'   # S:
                'FormatVolume'              # FAT32
                'SetPartitionType'          # now it becomes the ESP
                'NewPartition'              # Windows
                'SetPartitionDriveLetter'   # W:
                'FormatVolume'              # NTFS
                'NewPartition'              # Recovery, UseMaximumSize
                'SetPartitionDriveLetter'   # R:
                'FormatVolume'              # NTFS
                'SetPartitionType'          # the recovery type
            )
        }

        It 'creates the ESP as basic data and sets the ESP type after formatting' {
            $created = @($script:disk.Operations | Where-Object { $_.Operation -eq 'NewPartition' })[0]
            $retyped = @($script:disk.Operations | Where-Object { $_.Operation -eq 'SetPartitionType' })[0]

            [string] $created.Arguments[3] | Should -BeExactly $script:basicType
            [string] $retyped.Arguments[2] | Should -BeExactly $script:espType

            # And in that order: a partition created directly as an ESP cannot
            # readily be given a letter to format through.
            $created.Sequence | Should -BeLessThan $retyped.Sequence
        }

        It 'assigns the drive letters the layout names' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'SetPartitionDriveLetter' } |
                    ForEach-Object { [string] $_.Arguments[2] }) | Should -Be @('S', 'W', 'R')
        }

        It 'formats the ESP as FAT32 and the others as NTFS' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'FormatVolume' } |
                    ForEach-Object { [string] $_.Arguments[1] }) | Should -Be @('FAT32', 'NTFS', 'NTFS')
        }

        It 'labels the volumes as the layout names them' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'FormatVolume' } |
                    ForEach-Object { [string] $_.Arguments[2] }) | Should -Be @('System', 'Windows', 'Windows RE tools')
        }

        It 'sets the recovery GPT type on the recovery partition' {
            $retyped = @($script:disk.Operations | Where-Object { $_.Operation -eq 'SetPartitionType' })

            [string] $retyped[-1].Arguments[2] | Should -BeExactly $script:recoveryType
            @($script:disk.Partition | Where-Object { $_.DriveLetter -eq 'R' })[0].Type | Should -BeExactly 'Recovery'
        }

        It 'creates three partitions for uefi-standard' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'NewPartition' }).Count | Should -Be 3
        }

        It 'leaves the target disk with four partitions, one of them Reserved' {
            @($script:disk.Partition).Count | Should -Be 4
            @($script:disk.Partition | Where-Object { $_.Type -eq 'Reserved' }).Count | Should -Be 1
        }

        It 'sizes the Windows partition by the plan' {
            # 64 GiB less the ESP, the MSR allowance, the recovery partition and
            # the alignment - asserted to the byte, because a plan that is 16 MB
            # out does not fail until a real disk is in front of you.
            $windows = @($script:disk.Partition | Where-Object { $_.DriveLetter -eq 'W' })[0]

            $windows.SizeBytes | Should -Be (68719476736 - 272629760 - 16777216 - 1073741824 - 1048576)
        }
    }

    Context 'an MBR layout' {

        BeforeEach {
            $step = & $script:newStep ([ordered] @{ layout = 'bios-standard'; wipe = $true })
            $script:mbrResult = Invoke-HDTDiskPartitionStep -Step $step -Context $script:context
        }

        It 'creates two partitions for bios-standard' {
            @($script:disk.Operations | Where-Object { $_.Operation -eq 'NewPartition' }).Count | Should -Be 2
        }

        It 'marks the system partition active on an MBR layout' {
            $created = @($script:disk.Operations | Where-Object { $_.Operation -eq 'NewPartition' })

            [bool] $created[0].Arguments[4] | Should -BeTrue
            [bool] $created[1].Arguments[4] | Should -BeFalse
        }

        It 'sets no partition type on MBR' {
            @($script:disk.GetOperationName() | Where-Object { $_ -eq 'SetPartitionType' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the results it publishes' {

        BeforeEach {
            $script:published = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context
        }

        It 'sets HDTTargetDisk to the disk number' {
            $script:context.Variable['HDTTargetDisk'] | Should -Be 0
        }

        It 'sets HDTSystemVolume to S' {
            $script:context.Variable['HDTSystemVolume'] | Should -BeExactly 'S'
        }

        It 'sets HDTOSVolume to W' {
            $script:context.Variable['HDTOSVolume'] | Should -BeExactly 'W'
        }

        It 'sets HDTRecoveryVolume to R' {
            $script:context.Variable['HDTRecoveryVolume'] | Should -BeExactly 'R'
        }

        It 'leaves HDTRecoveryVolume empty for a layout with no recovery partition' {
            $context = & $script:newContextFor (New-HDTFakeDiskService -Disk @($script:targetDisk)) $null
            $step = & $script:newStep ([ordered] @{ layout = 'bios-standard'; wipe = $true })

            Invoke-HDTDiskPartitionStep -Step $step -Context $context | Out-Null

            [string] $context.Variable['HDTRecoveryVolume'] | Should -BeExactly ''
        }

        It 'returns the plan in the result data' {
            @($script:published.Data['plan'] | ForEach-Object { [string] $_.Role }) |
                Should -Be @('System', 'Windows', 'Recovery')
        }

        It 'returns the disk number in the result data' {
            $script:published.Data['diskNumber'] | Should -Be 0
        }
    }

    Context 'ShouldProcess' {

        It 'writes nothing under -WhatIf' {
            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context -WhatIf | Out-Null

            foreach ($operation in @($script:disk.GetOperationName())) {
                $operation | Should -BeLike 'Get*' -Because 'a dry run destroys nothing'
            }
        }

        It 'still returns Completed under -WhatIf' {
            (Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context -WhatIf).Status |
                Should -BeExactly 'Completed'
        }

        It 'logs the plan under -WhatIf' {
            # A dry run that says nothing is useless.
            Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $script:context -WhatIf | Out-Null

            $log = $script:fileSystem.ReadAllText('X:\HDT\Logs\HDT.log')

            $log | Should -BeLike '*uefi-standard*'
            $log | Should -BeLike '*Windows*'
        }
    }

    Context 'failure' {

        It 'returns Failed when the disk service throws' {
            # The Storage cmdlet that fails, modelled: the real adapter throws
            # when Initialize-Disk does, and this is the shape it arrives in.
            $broken = New-HDTFakeDiskService -Disk @($script:targetDisk) `
                -Failure @{ InitializeDisk = 'The device is not ready for use.' }

            $context = & $script:newContextFor $broken $null

            (Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context).Status | Should -BeExactly 'Failed'
        }

        It 'names the operation that failed' {
            $broken = New-HDTFakeDiskService -Disk @($script:targetDisk) `
                -Failure @{ InitializeDisk = 'The device is not ready for use.' }

            $context = & $script:newContextFor $broken $null
            $result = Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context

            $result.Message | Should -BeLike '*initialis*'
            $result.Message | Should -BeLike '*not ready*'
        }

        It 'names the partition it was creating when the create failed' {
            $broken = New-HDTFakeDiskService -Disk @($script:targetDisk) `
                -Failure @{ FormatVolume = 'The volume is not formattable.' }

            $context = & $script:newContextFor $broken $null

            (Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context).Message |
                Should -BeLike '*System*'
        }

        It 'does not rethrow' {
            $broken = New-HDTFakeDiskService -Disk @($script:targetDisk) `
                -Failure @{ ClearDisk = 'The device is not ready for use.' }

            $context = & $script:newContextFor $broken $null

            { Invoke-HDTDiskPartitionStep -Step $script:wipeStep -Context $context } | Should -Not -Throw
        }

        It 'returns Failed rather than throwing for a step with no properties' {
            $empty = New-HDTFakeDiskService
            $context = & $script:newContextFor $empty $null

            $result = Invoke-HDTDiskPartitionStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the loop never retries a refusal' {

        It 'does not retry a step that refused for a configuration reason' {
            # 04-02's property, end to end: the refusal reaches
            # Get-HDTFailureClass through the RESULT rather than through an
            # exception, and a Configuration failure is not retried - even when
            # the step declares retry: 2.
            $yaml = @'
schemaVersion: 1
id: REFUSE
name: A step that refuses to guess
steps:
  - name: Format and Partition
    type: DiskPartition
    layout: uefi-standard
    wipe: true
    retry:
      count: 2
      delaySeconds: 5
'@

            $harness = New-HDTSequenceTestHarness -Yaml $yaml -Variable @{ HDTIsUEFI = $true }
            $harness.Catalog.Disk = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk)

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $started = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Event 'step.start')

            $started.Count | Should -Be 1
            $result.Status | Should -BeExactly 'Failed'
            @($result.Result | Where-Object { $_.Index -eq 1 })[0].FailureClass | Should -BeExactly 'Configuration'
        }

        It 'waited on nothing while not retrying' {
            $yaml = @'
schemaVersion: 1
id: REFUSE
name: A step that refuses to guess
steps:
  - name: Format and Partition
    type: DiskPartition
    layout: uefi-standard
    wipe: true
    retry:
      count: 2
      delaySeconds: 5
'@

            $harness = New-HDTSequenceTestHarness -Yaml $yaml -Variable @{ HDTIsUEFI = $true }
            $harness.Catalog.Disk = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:secondDisk)

            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            $harness.Clock.TotalSleepMillisecond | Should -Be 0
        }
    }
}

Describe 'Get-HDTDiskPartitionStepDescription' {

    It 'names the layout it will apply' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['layout'] = 'uefi-standard'

        $step = [pscustomobject] @{ Index = 2; Name = 'Format and Partition'; Type = 'DiskPartition'; Property = $bag }

        Get-HDTDiskPartitionStepDescription -Step $step | Should -BeLike '*uefi-standard*'
    }

    It 'describes a step that pins nothing' {
        $step = [pscustomobject] @{ Index = 2; Name = 'Format and Partition'; Type = 'DiskPartition'
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTDiskPartitionStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
