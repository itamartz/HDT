# The pre-flight (DESIGN 9.1, PSD's PSDValidate.ps1 for which checks matter in
# the field).
#
# THE POINT OF THIS STEP IS THAT IT RUNS FIRST. Every check it makes is a check
# DiskPartition or ApplyImage would have made anyway - and would have made after
# the disk was already wiped. Running Select-HDTTargetDisk here, with the same
# arguments DiskPartition will use, means a deployment that is going to refuse
# refuses while the machine is still intact.
#
# IT REPORTS EVERY FAILED CHECK, NOT THE FIRST. A technician standing at a
# machine wants the whole list: 'not enough RAM' followed twenty minutes later by
# 'no disk big enough' is two trips to the bench.
#
# It reads facts out of the CONTEXT VARIABLES, never CIM. Gathering is phase 02's
# job and it already happened; a step that re-gathered would be a second answer
# to the same question, and PROJECT constraint 4 forbids it reaching CIM at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 1; Name = 'Validate'; Type = 'Validate'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }

    # The Gen2 lab VM's own disk: 64 GiB, RAW, and BusType SAS rather than
    # anything VM-specific (SPIKES S6).
    $script:targetDisk = @{
        Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
        BusType = 'SAS'; PartitionStyle = 'RAW'
    }

    # The content disk 04-04's VM carries alongside it: too small to be a
    # deployment target, which is what keeps the choice unambiguous.
    $script:contentDisk = @{
        Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 8589934592
        BusType = 'SAS'; PartitionStyle = 'GPT'
    }
}

Describe 'Invoke-HDTValidateStep' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 17, [System.DateTimeKind]::Utc))
        $script:disk = New-HDTFakeDiskService -Disk @($script:targetDisk)
        $script:image = New-HDTFakeImageService

        $script:newContextFor = {
            param([object] $DiskService, [System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Disk $DiskService -Image $script:image

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTMemory'] = 4096
            $live['HDTIsUEFI'] = $true
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContextFor $script:disk $null
    }

    Context 'the checks' {

        It 'returns Completed when every check passes' {
            $step = & $script:newStep ([ordered] @{ minRamMB = 2048; minDiskGB = 60 })

            (Invoke-HDTValidateStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'fails when the machine has less RAM than minRamMB' {
            $step = & $script:newStep ([ordered] @{ minRamMB = 8192 })

            (Invoke-HDTValidateStep -Step $step -Context $script:context).Status | Should -BeExactly 'Failed'
        }

        It 'names the required and the actual memory in the message' {
            $step = & $script:newStep ([ordered] @{ minRamMB = 8192 })

            $result = Invoke-HDTValidateStep -Step $step -Context $script:context

            $result.Message | Should -BeLike '*8192*'
            $result.Message | Should -BeLike '*4096*'
        }

        It 'fails when no disk meets minDiskGB' {
            $small = New-HDTFakeDiskService -Disk @($script:contentDisk)
            $context = & $script:newContextFor $small $null
            $step = & $script:newStep ([ordered] @{ minDiskGB = 60 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*60*'
        }

        It 'fails when requireUefi is set on a BIOS machine' {
            $context = & $script:newContextFor $script:disk ([ordered] @{ HDTIsUEFI = $false })
            $step = & $script:newStep ([ordered] @{ requireUefi = $true })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*UEFI*'
        }

        It 'passes requireUefi on a UEFI machine' {
            $step = & $script:newStep ([ordered] @{ requireUefi = $true })

            (Invoke-HDTValidateStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'reports every failed check, not the first' {
            # Two trips to the bench is the failure this assertion prevents.
            $small = New-HDTFakeDiskService -Disk @($script:contentDisk)
            $context = & $script:newContextFor $small ([ordered] @{ HDTMemory = 1024 })
            $step = & $script:newStep ([ordered] @{ minRamMB = 2048; minDiskGB = 60 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Message | Should -BeLike '*2048*'
            $result.Message | Should -BeLike '*60*'
        }

        It 'passes when minRamMB is absent' {
            # Every check is opt-in: a Validate step that declares nothing still
            # runs the target disk selection and nothing else.
            $step = & $script:newStep ([ordered] @{ minDiskGB = 60 })

            (Invoke-HDTValidateStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'fails when minRamMB is declared and HDTMemory was never gathered' {
            $context = & $script:newContextFor $script:disk $null
            $context.Variable.Remove('HDTMemory')
            $step = & $script:newStep ([ordered] @{ minRamMB = 2048 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTMemory*'
        }

        It 'fails when a requireVariable is unset' {
            $step = & $script:newStep ([ordered] @{ requireVariable = @('HDTComputerName') })

            $result = Invoke-HDTValidateStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTComputerName*'
        }

        It 'passes when every requireVariable is set' {
            $context = & $script:newContextFor $script:disk ([ordered] @{ HDTComputerName = 'HDT-M3-01' })
            $step = & $script:newStep ([ordered] @{ requireVariable = @('HDTComputerName') })

            (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
        }

        It 'accepts a single requireVariable written as a scalar' {
            $step = & $script:newStep ([ordered] @{ requireVariable = 'HDTComputerName' })

            (Invoke-HDTValidateStep -Step $step -Context $script:context).Message |
                Should -BeLike '*HDTComputerName*'
        }
    }

    Context 'the target disk' {

        It 'fails when the target disk is ambiguous' {
            # The reason this step exists: the refusal happens here, before
            # anything destructive, rather than in DiskPartition.
            $twin = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW' })

            $context = & $script:newContextFor $twin $null
            $step = & $script:newStep $null

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*disk 0*'
            $result.Message | Should -BeLike '*disk 1*'
        }

        It 'carries the refusal errorId in the result data' {
            $twin = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW' })

            $context = & $script:newContextFor $twin $null
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $context

            [string] $result.Data['errorId'] | Should -BeExactly 'HDTAmbiguousTargetError'
        }

        It 'honours an explicit diskNumber' {
            $twin = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW' })

            $context = & $script:newContextFor $twin $null
            $step = & $script:newStep ([ordered] @{ diskNumber = 1 })

            (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
        }

        It 'refuses an explicit diskNumber naming the boot disk' {
            $host0 = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Host disk'; SizeBytes = 512110190592; BusType = 'NVMe'
                    PartitionStyle = 'GPT'; IsBoot = $true; IsSystem = $true
                })

            $context = & $script:newContextFor $host0 $null
            $step = & $script:newStep ([ordered] @{ diskNumber = 0 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTUnsafeTargetError'
        }

        It 'protects the disk carrying the workspace' {
            # Z: is the workspace root in this context, and disk 1 holds it.
            $shared = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Content'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'GPT' }
            ) -Partition @(
                @{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'Z'; SizeBytes = 68719476736 })

            $context = & $script:newContextFor $shared $null

            # Disk 1 is excluded by the protected letter, so disk 0 is the only
            # candidate and the step passes rather than refusing as ambiguous.
            (Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $context).Status |
                Should -BeExactly 'Completed'
        }

        It 'reports the target disk it selected in the result data' {
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $script:context

            $result.Data['diskNumber'] | Should -Be 0
        }

        It 'reads the disks through the injected service' {
            Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $script:context | Out-Null

            @($script:disk.GetOperationName()) | Should -Contain 'GetDisk'
        }

        It 'touches no write method' {
            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minRamMB = 2048 })) -Context $script:context | Out-Null

            foreach ($operation in @($script:disk.GetOperationName())) {
                $operation | Should -BeLike 'Get*' -Because 'a pre-flight reads and never writes'
            }
        }
    }

    Context 'the step contract' {

        It 'returns Failed rather than throwing for a step with no properties' {
            # An empty fake disk service is a machine reporting no disk at all,
            # which is a refusal rather than an exception.
            $empty = New-HDTFakeDiskService
            $context = & $script:newContextFor $empty $null

            $result = Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }

        It 'logs a step.fail record when it refuses' {
            $empty = New-HDTFakeDiskService
            $context = & $script:newContextFor $empty $null

            Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $context | Out-Null

            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.fail') |
                Should -Not -BeNullOrEmpty
        }

        It 'does not rethrow' {
            $empty = New-HDTFakeDiskService
            $context = & $script:newContextFor $empty $null

            { Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $context } | Should -Not -Throw
        }
    }
}

Describe 'Get-HDTValidateStepDescription' {

    It 'describes the checks it will make' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['minRamMB'] = 2048
        $bag['minDiskGB'] = 60

        $step = [pscustomobject] @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Property = $bag }

        $description = Get-HDTValidateStepDescription -Step $step

        $description | Should -BeLike '*2048*'
        $description | Should -BeLike '*60*'
    }

    It 'describes a step that declares nothing' {
        $step = [pscustomobject] @{ Index = 1; Name = 'Validate'; Type = 'Validate'
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTValidateStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
