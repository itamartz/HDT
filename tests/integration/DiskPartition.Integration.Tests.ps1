# Invoke-HDTDiskPartitionStep end to end, with the REAL disk service, against a
# scratch VHDX.
#
# tests/unit/Invoke-HDTDiskPartitionStep.Tests.ps1 proves the step against the
# fake, where the assertion that matters is "writes nothing when it refuses".
# This file proves the same step against the Storage module, where the
# assertions that matter are that -WhatIf really writes nothing and that the
# published volumes are the ones that exist.
#
# THE REFUSAL IS ASSERTED AGAINST THIS HOST, without a diskNumber, because the
# only disk that is not the scratch VHDX is the one this machine booted from.
# That is DESIGN 9.1's subject, on the developer's own machine, and it is safe
# precisely because the answer is no.

BeforeDiscovery {
    $script:driveLetterInUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    $script:skipForDriveLetter = $script:driveLetterInUse.Count -gt 0
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:inUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    if ($script:inUse.Count -gt 0) {
        Write-Warning ("DiskPartition.Integration.Tests.ps1 skipped: the uefi-standard layout needs S:, W: and R: free on this host and {0}: is in use." -f ($script:inUse -join ':, '))
    }

    $script:scratchRoot = 'C:\HDTLab\scratch\integration'
    $script:scratchPath = Join-Path -Path $script:scratchRoot -ChildPath 'diskpartition.vhdx'
    $script:logRoot = Join-Path -Path $script:scratchRoot -ChildPath 'logs'
    $script:scratchSizeByte = 68719476736   # 64 GB, dynamic - so minDiskGB 60 is met

    $script:scratchNumber = -1
    if ($script:inUse.Count -eq 0) {
        $scratch = New-HDTLabScratchDisk -Path $script:scratchPath -SizeByte $script:scratchSizeByte -Dynamic -Confirm:$false
        $script:scratchNumber = [int] $scratch.DiskNumber
    }

    # A real context: real filesystem, real clock, real disk service. The log
    # goes to the scratch area, never to the repository.
    $script:newContext = {
        $fileSystem = New-HDTFileSystem
        $clock = New-HDTClock
        $disk = New-HDTDiskService

        $fileSystem.CreateDirectory($script:logRoot)

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Disk $disk

        $log = New-HDTLogContext -RunId 'run-integration' -Phase 'WinPE' -LogPath $script:logRoot `
            -FileSystem $fileSystem -Clock $clock

        $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $variable['HDTIsUEFI'] = $true

        $context = New-HDTExecutionContext -RunId 'run-integration' -Phase 'WinPE' `
            -WorkspaceRoot 'C:\HDTLab\scratch\integration' -Variable $variable -Service $catalog -Log $log

        return [pscustomobject] @{ Context = $context; Disk = $disk; Variable = $variable }
    }

    $script:newStep = {
        param([object] $DiskNumber)

        $step = [ordered] @{
            name  = 'Format and Partition'
            type  = 'DiskPartition'
            index = 1
            wipe  = $true
        }

        if ($null -ne $DiskNumber) { $step['diskNumber'] = $DiskNumber }

        return [pscustomobject] $step
    }

    $script:partitionOn = {
        $service = New-HDTDiskService
        return @($service.GetPartition() | Where-Object { $_.DiskNumber -eq $script:scratchNumber })
    }
}

AfterAll {
    if (Get-Command -Name 'Remove-HDTLabScratchDisk' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchDisk -Path $script:scratchPath -Confirm:$false
    }

    if (Test-Path -LiteralPath $script:logRoot -PathType Container) {
        Remove-Item -LiteralPath $script:logRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-HDTDiskPartitionStep against this host' {

    It 'refuses without an explicit disk number on this host' {
        # Every disk that is not the scratch VHDX is the one this machine booted
        # from, and rules 1 and 2 exclude it - IsBoot/IsSystem, and C: is the
        # protected workspace letter. The scratch disk is excluded because it
        # carries the letters of a previous run's volumes only after it has been
        # partitioned; before that it is RAW and would qualify, so this
        # assertion runs FIRST, before anything is created on it.
        $harness = & $script:newContext
        $step = & $script:newStep $null

        $result = Invoke-HDTDiskPartitionStep -Step $step -Context $harness.Context -Confirm:$false

        $result.Status | Should -BeExactly 'Failed'
        [string] $result.Data['errorId'] | Should -BeLike 'HDT*TargetError'
    }

    It 'wrote nothing when it refused' {
        $harness = & $script:newContext
        $step = & $script:newStep $null

        [void] (Invoke-HDTDiskPartitionStep -Step $step -Context $harness.Context -Confirm:$false)

        @($harness.Disk.GetOperationName() | Where-Object { $_ -notlike 'Get*' }) | Should -BeNullOrEmpty
    }

    It 'classifies the refusal as Configuration, so it is never retried' {
        $harness = & $script:newContext
        $step = & $script:newStep $null

        $result = Invoke-HDTDiskPartitionStep -Step $step -Context $harness.Context -Confirm:$false

        Get-HDTFailureClass -ResultData $result.Data | Should -BeExactly 'Configuration'
    }

    It 'refuses an explicit disk number naming this machine disk 0' {
        $harness = & $script:newContext
        $step = & $script:newStep 0

        $result = Invoke-HDTDiskPartitionStep -Step $step -Context $harness.Context -Confirm:$false

        $result.Status | Should -BeExactly 'Failed'
        [string] $result.Data['errorId'] | Should -BeExactly 'HDTUnsafeTargetError'
    }
}

Describe 'Invoke-HDTDiskPartitionStep against a scratch VHDX' -Skip:$skipForDriveLetter {

    Context 'under -WhatIf' {

        BeforeAll {
            # A freshly initialised disk, so "unchanged" is a shape that can be
            # asserted rather than an absence.
            $service = New-HDTDiskService
            $service.ClearDisk($script:scratchNumber)
            $service.InitializeDisk($script:scratchNumber, 'GPT')

            $script:beforeWhatIf = @(& $script:partitionOn)

            $script:whatIfHarness = & $script:newContext
            $script:whatIfResult = Invoke-HDTDiskPartitionStep -Step (& $script:newStep $script:scratchNumber) `
                -Context $script:whatIfHarness.Context -WhatIf

            $script:afterWhatIf = @(& $script:partitionOn)
        }

        It 'reports Completed' {
            # It planned, logged the plan, and returned - so a -WhatIf run of a
            # whole sequence stays coherent for the steps after it.
            $script:whatIfResult.Status | Should -BeExactly 'Completed'
        }

        It 'writes nothing under -WhatIf' {
            @($script:afterWhatIf | ForEach-Object { $_.PartitionNumber }) |
                Should -Be @($script:beforeWhatIf | ForEach-Object { $_.PartitionNumber })
        }

        It 'leaves only the MSR that Initialize-Disk made' {
            $script:afterWhatIf.Count | Should -Be 1
        }

        It 'called no write method on the disk service' {
            @($script:whatIfHarness.Disk.GetOperationName() | Where-Object { $_ -notlike 'Get*' }) |
                Should -BeNullOrEmpty
        }

        It 'still published the volumes the steps after it plan against' {
            $script:whatIfHarness.Variable['HDTOSVolume'] | Should -BeExactly 'W'
            $script:whatIfHarness.Variable['HDTSystemVolume'] | Should -BeExactly 'S'
            $script:whatIfHarness.Variable['HDTRecoveryVolume'] | Should -BeExactly 'R'
        }
    }

    Context 'for real' {

        BeforeAll {
            $script:realHarness = & $script:newContext
            $script:realResult = Invoke-HDTDiskPartitionStep -Step (& $script:newStep $script:scratchNumber) `
                -Context $script:realHarness.Context -Confirm:$false

            $script:realPartition = @(& $script:partitionOn | Sort-Object PartitionNumber)
        }

        It 'partitions the scratch disk when it is named explicitly' {
            $script:realResult.Status | Should -BeExactly 'Completed'
            [int] $script:realResult.Data['diskNumber'] | Should -Be $script:scratchNumber
        }

        It 'leaves four partitions' {
            $script:realPartition.Count | Should -Be 4
        }

        It 'leaves exactly one reserved partition' {
            # SPIKES S6's duplicate-MSR trap, on a real disk, through the step.
            @($script:realPartition | Where-Object { $_.GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' }).Count |
                Should -Be 1
        }

        It 'publishes the drive letters it assigned' {
            $script:realHarness.Variable['HDTTargetDisk'] | Should -Be $script:scratchNumber
            $script:realHarness.Variable['HDTSystemVolume'] | Should -BeExactly 'S'
            $script:realHarness.Variable['HDTOSVolume'] | Should -BeExactly 'W'
            $script:realHarness.Variable['HDTRecoveryVolume'] | Should -BeExactly 'R'
        }

        It 'published letters that actually exist' {
            # The published variable and the machine agree - which is the whole
            # difference between this file and the unit tests.
            foreach ($letter in @('S', 'W', 'R')) {
                Test-Path -LiteralPath ('{0}:\' -f $letter) | Should -BeTrue
            }
        }

        It 'chose uefi-standard from HDTIsUEFI' {
            [string] $script:realResult.Data['layout'] | Should -BeExactly 'uefi-standard'
            [string] $script:realResult.Data['partitionStyle'] | Should -BeExactly 'GPT'
        }

        It 'wrote to no disk but the scratch one' {
            $written = @($script:realHarness.Disk.Operations |
                    Where-Object { $_.Operation -in @('ClearDisk', 'InitializeDisk', 'NewPartition', 'SetPartitionDriveLetter', 'SetPartitionType') } |
                    ForEach-Object { [int] $_.Arguments[0] })

            $written.Count | Should -BeGreaterThan 0
            @($written | Where-Object { $_ -ne $script:scratchNumber }) | Should -BeNullOrEmpty
        }

        It 'logged the disk it chose and the plan' {
            $record = @(Get-HDTLogRecord -FileSystem (New-HDTFileSystem) `
                    -Path (Join-Path -Path $script:logRoot -ChildPath 'HDT.jsonl'))
            $chosen = @($record | Where-Object { $_.component -eq 'DiskPartition' -and $_.message -like '*repartition*' })

            $chosen.Count | Should -BeGreaterThan 0
        }
    }
}
