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

        It 'passes on a disk that already carries Windows' {
            # A REBUILD IS THE NORMAL CASE, AND THE PRE-FLIGHT USED TO REFUSE
            # IT. Validate ran Select-HDTTargetDisk with the same
            # existing-data guard DiskPartition uses, so a machine with C: and
            # D: on disk 0 - every machine that has ever been deployed - failed
            # step 1 with "the step did not declare that it may be replaced",
            # and the fix was to repeat `wipe: true` on a step that wipes
            # nothing. A real VM run failed exactly this way.
            #
            # WHETHER THE DISK MAY BE ERASED IS DiskPartition'S QUESTION,
            # because DiskPartition is what erases it. The pre-flight asks
            # whether a usable disk of the right size is present, and that is
            # all.
            $used = New-HDTFakeDiskService -Disk @(@{
                    Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; SizeBytes = 60000000000 }
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; SizeBytes = 8000000000 }
            )

            $context = & $script:newContextFor $used $null
            $step = & $script:newStep ([ordered] @{ minDiskGB = 60 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
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

Describe 'the TPM check' {

    # WINDOWS 11 REQUIRES TPM 2.0, and a machine without one gets all the way
    # through partitioning and imaging before Setup says so - on a disk that has
    # already been wiped. Checking it in the pre-flight costs nothing and is the
    # difference between a refusal and a rebuild.
    #
    # HDTTPMVersion IS ALREADY GATHERED: Win32_Tpm.SpecVersion's first component,
    # or null where there is no TPM or it cannot be read.

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 17, 0, 0, 0, [System.DateTimeKind]::Utc))
        $script:disk = New-HDTFakeDiskService -Disk @($script:targetDisk)
        $script:image = New-HDTFakeImageService

        $script:tpmContextFor = {
            param([object] $Value)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Disk $script:disk -Image $script:image

            $log = New-HDTLogContext -RunId 'run-0002' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTMemory'] = 4096
            $live['HDTIsUEFI'] = $true
            $live['HDTTPMVersion'] = $Value

            return (New-HDTExecutionContext -RunId 'run-0002' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }
    }

    It 'passes a machine whose TPM meets the minimum' {
        $context = & $script:tpmContextFor '2.0'
        $step = & $script:newStep ([ordered] @{ minTpmVersion = '2.0' })

        (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
    }

    It 'refuses a machine whose TPM is older than the minimum' {
        $context = & $script:tpmContextFor '1.2'
        $step = & $script:newStep ([ordered] @{ minTpmVersion = '2.0' })

        $result = Invoke-HDTValidateStep -Step $step -Context $context

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*1.2*'
        $result.Message | Should -BeLike '*2.0*'
    }

    It 'refuses a machine with no TPM at all, and says so rather than comparing nothing' {
        $context = & $script:tpmContextFor $null
        $step = & $script:newStep ([ordered] @{ minTpmVersion = '2.0' })

        $result = Invoke-HDTValidateStep -Step $step -Context $context

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*no TPM*'
    }

    It 'checks nothing when the step does not ask' {
        # EVERY CHECK IS OPT-IN. A Validate step that says nothing about the TPM
        # must not start refusing machines that deployed yesterday.
        $context = & $script:tpmContextFor $null
        $step = & $script:newStep ([ordered] @{ minRamMB = 2048 })

        (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
    }

    It 'refuses a version it cannot read rather than passing it' {
        $context = & $script:tpmContextFor 'not a version'
        $step = & $script:newStep ([ordered] @{ minTpmVersion = '2.0' })

        (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Failed'
    }
}

Describe 'the pre-flight log' {

    # THE PASS PATH USED TO BE ONE LINE. A real run's 002-Validate.log said
    # "this machine passed the pre-flight; disk 0 is the deployment target." and
    # nothing else - so a reader could not tell whether eight checks ran or one,
    # and a check weakened tomorrow would leave the log looking identical. A
    # validation step's content IS its checks; "passed" without them is
    # unfalsifiable.
    #
    # THE ASYMMETRY WAS THE TELL. The FAILURE path already enumerated every
    # failed check with its threshold, so the only way to learn what HDT checks
    # was to fail it - an administrator qualifying a new hardware model had to
    # break a machine to read the rules. These tests hold the pass path to the
    # failure path's standard.
    #
    # AND THE DISK DECISION IS A CHOICE, NOT A FACT. "disk 0 is the deployment
    # target" on a machine with an NVMe, an SD reader and the USB stick it
    # booted from means three disks were excluded. Rule 6 says HDT must not
    # guess which disk to wipe; the log has to show that it did not.

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 19, 1, 5, [System.DateTimeKind]::Utc))
        $script:image = New-HDTFakeImageService

        $script:logContextFor = {
            param([object] $DiskService, [System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Disk $DiskService -Image $script:image

            $log = New-HDTLogContext -RunId 'run-0003' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTMemory'] = 32627
            $live['HDTIsUEFI'] = $true
            $live['HDTTPMVersion'] = '2.0'
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0003' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:everyCheck = [ordered] @{
            minRamMB        = 2048
            minDiskGB       = 60
            requireUefi     = $true
            minTpmVersion   = '2.0'
            requireVariable = @('HDTComputerName')
        }

        $script:soleDisk = New-HDTFakeDiskService -Disk @($script:targetDisk)
        $script:context = & $script:logContextFor $script:soleDisk ([ordered] @{ HDTComputerName = 'LT-7FJ45S2' })

        $script:infoLine = {
            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Severity 'Info' |
                    Where-Object { [string] $_.component -eq 'Validate' } | ForEach-Object { [string] $_.message })
        }

        $script:debugLine = {
            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Severity 'Debug' |
                    Where-Object { [string] $_.component -eq 'Validate' } | ForEach-Object { [string] $_.message })
        }

        $script:warningLine = {
            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Severity 'Warning' |
                    Where-Object { [string] $_.component -eq 'Validate' } | ForEach-Object { [string] $_.message })
        }
    }

    Context 'the Info summary' {

        It 'says how many checks ran and how many warned' {
            Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context | Out-Null

            $line = @(& $script:infoLine)

            @($line | Where-Object { $_ -match '^pre-flight passed: \d+ checks?, \d+ warnings?\.$' }).Count |
                Should -Be 1 -Because 'a technician reads the verdict and the warning count at a glance'
        }

        It 'gives the reason the disk was selected, not just the number' {
            # "disk 0 is the deployment target" is a CHOICE reported without its
            # reason. On a laptop with an NVMe, an SD reader and a USB stick,
            # picking disk 0 means excluding two others.
            Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context | Out-Null

            $selected = @(& $script:infoLine | Where-Object { $_ -like 'disk 0 is the deployment target*' })

            $selected.Count | Should -Be 1
            $selected[0] | Should -BeLike '*the only disk*'
        }

        It 'keeps the summary to two lines' {
            Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context | Out-Null

            @(& $script:infoLine).Count | Should -Be 2 -Because 'Info is a glance; the enumeration belongs at Debug'
        }

        It 'carries both lines in the step result message' {
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context

            $result.Message | Should -BeLike '*pre-flight passed*'
            $result.Message | Should -BeLike '*deployment target*'
        }

        It 'names the disk the sequence named, and says the sequence named it' {
            $twin = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW' })

            $context = & $script:logContextFor $twin $null
            $step = & $script:newStep ([ordered] @{ minDiskGB = 60; diskNumber = 1 })

            Invoke-HDTValidateStep -Step $step -Context $context | Out-Null

            @(& $script:infoLine | Where-Object { $_ -like 'disk 1 is the deployment target*named by the sequence*' }).Count |
                Should -Be 1
        }
    }

    Context 'the Debug enumeration' {

        It 'enumerates every check with its observed value and its threshold' {
            # THE THRESHOLD IS THE PART THAT IS CURRENTLY UNKNOWABLE. MDT logs
            # "Disk Size : ..." and "Min Size : ..." as adjacent lines; this is
            # the same information, one line per check.
            Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context | Out-Null

            $line = @(& $script:debugLine)

            @($line | Where-Object { $_ -like 'memory*32627 MB*2048 MB*pass' }).Count | Should -Be 1
            @($line | Where-Object { $_ -like 'firmware*UEFI*pass' }).Count | Should -Be 1
            @($line | Where-Object { $_ -like 'TPM*2.0*pass' }).Count | Should -Be 1
        }

        It 'says a check was not asked for rather than leaving it out' {
            # A check absent from the log and a check that passed look the same.
            # "skipped" is what tells an administrator the check EXISTS.
            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minRamMB = 2048 })) -Context $script:context | Out-Null

            @(& $script:debugLine | Where-Object { $_ -like 'TPM*skipped' }).Count | Should -Be 1
            @(& $script:debugLine | Where-Object { $_ -like 'firmware*skipped' }).Count | Should -Be 1
        }

        It 'lists every disk it considered, not only the one it chose' {
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:contentDisk)
            $context = & $script:logContextFor $twin $null

            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context | Out-Null

            $line = @(& $script:debugLine)

            @($line | Where-Object { $_ -like 'disk 0 *' }).Count | Should -Be 1
            @($line | Where-Object { $_ -like 'disk 1 *' }).Count | Should -Be 1
        }

        It 'gives the reason each rejected disk was rejected' {
            # RULE 6 EVIDENCE. Disk selection going wrong is how the wrong thing
            # gets erased, so the log must show what was excluded and why.
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:contentDisk)
            $context = & $script:logContextFor $twin $null

            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context | Out-Null

            $rejected = @(& $script:debugLine | Where-Object { $_ -like 'disk 1 *excluded*' })

            $rejected.Count | Should -Be 1
            $rejected[0] | Should -BeLike '*under the minimum*'
        }

        It 'reports the boot disk as excluded and says which rule excluded it' {
            $host0 = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Host disk'; SizeBytes = 512110190592; BusType = 'NVMe'
                    PartitionStyle = 'GPT'; IsBoot = $true; IsSystem = $true
                },
                @{ Number = 1; FriendlyName = 'Virtual HD'; SizeBytes = 68719476736
                    BusType = 'SAS'; PartitionStyle = 'RAW'
                })

            $context = & $script:logContextFor $host0 $null

            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context | Out-Null

            @(& $script:debugLine | Where-Object { $_ -like 'disk 0 *excluded*booted from*' }).Count | Should -Be 1
        }

        It 'enumerates the checks on the failure path too' {
            # SYMMETRY. A reader who has seen one path should recognise the other.
            $step = & $script:newStep ([ordered] @{ minRamMB = 65536; minDiskGB = 60 })

            Invoke-HDTValidateStep -Step $step -Context $script:context | Out-Null

            # The verdict carries its reason on the failure path, so the line
            # does not end at the word - which is the whole difference from a
            # pass, and why -like needs the trailing wildcard here.
            @(& $script:debugLine | Where-Object { $_ -like 'memory*65536 MB*fail: *' }).Count | Should -Be 1
        }
    }

    Context 'warnings' {

        # THE STEP WAS PASS/FAIL BINARY. A finding that should not stop a
        # deployment but is worth recording had nowhere to go, so it went
        # nowhere. MDT's convention is copied: a warning states the assumption
        # it is proceeding on.

        It 'reports no warning on a machine with none' {
            Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context | Out-Null

            @(& $script:warningLine).Count | Should -Be 0
            @(& $script:infoLine | Where-Object { $_ -like '*0 warnings*' }).Count | Should -Be 1
        }

        It 'warns when the selected disk has less headroom than Setup itself needs' {
            # MDT'S OWN NUMBER: ZTIValidate needs the image plus 150 MB for
            # WinPE and logs plus 3 GB for Setup. A disk that clears the minimum
            # by less than that clears it on paper only.
            $tight = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 65498251264
                    BusType = 'SAS'; PartitionStyle = 'RAW'
                })

            $context = & $script:logContextFor $tight $null

            $result = Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context

            $result.Status | Should -BeExactly 'Completed' -Because 'a warning does not stop a deployment'
            @(& $script:warningLine | Where-Object { $_ -like '*headroom*' }).Count | Should -Be 1
        }

        It 'counts the warning on the Info summary line' {
            $tight = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 65498251264
                    BusType = 'SAS'; PartitionStyle = 'RAW'
                })

            $context = & $script:logContextFor $tight $null

            Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context | Out-Null

            @(& $script:infoLine | Where-Object { $_ -like '*1 warning.*' }).Count |
                Should -Be 1 -Because 'the count must be visible without opening Debug'
        }

        It 'warns when naming a disk overrode a rule that would have excluded it' {
            # Select-HDTTargetDisk already warns here and the step threw the
            # warning away with -WarningAction SilentlyContinue. Overriding rule
            # 6 or 7 by naming a disk is the definition of worth recording.
            $stick = New-HDTFakeDiskService -Disk @(
                $script:targetDisk,
                @{ Number = 1; FriendlyName = 'Ultra Fit'; SizeBytes = 68719476736
                    BusType = 'USB'; PartitionStyle = 'RAW'
                })

            $context = & $script:logContextFor $stick $null
            $step = & $script:newStep ([ordered] @{ minDiskGB = 60; diskNumber = 1 })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @(& $script:warningLine | Where-Object { $_ -like '*USB*named it*' }).Count | Should -Be 1
        }

        It 'carries every warning in the result data' {
            $tight = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 65498251264
                    BusType = 'SAS'; PartitionStyle = 'RAW'
                })

            $context = & $script:logContextFor $tight $null

            $result = Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minDiskGB = 60 })) -Context $context

            [int] $result.Data['warningCount'] | Should -Be 1
            @($result.Data['warning']).Count | Should -Be 1
        }
    }

    Context 'the data payload' {

        # THE SUMMARY WINDOW AND ANY REPORT MUST NOT RE-PARSE PROSE. The
        # structured rows are the same information the Debug lines render.

        It 'carries a check row for every check a Validate step can make' {
            # THE SET, NOT THE ONES TOUCHED TODAY. Get-HDTValidateCheckDefinition
            # is the one place a check is declared; a seventh added there fails
            # this until the step reports it.
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context

            $reported = @($result.Data['check'] | ForEach-Object { [string] $_['key'] })

            InModuleScope Hephaestus -Parameters @{ Reported = $reported } {
                param($Reported)

                foreach ($definition in @(Get-HDTValidateCheckDefinition)) {
                    $Reported | Should -Contain ([string] $definition.Key) -Because (
                        'the log must report the {0} check, declared or not' -f $definition.Key)
                }
            }
        }

        It 'carries every check even when the step declares nothing' {
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $null) -Context $script:context

            $reported = @($result.Data['check'] | ForEach-Object { [string] $_['key'] })

            InModuleScope Hephaestus -Parameters @{ Reported = $reported } {
                param($Reported)

                foreach ($definition in @(Get-HDTValidateCheckDefinition)) {
                    $Reported | Should -Contain ([string] $definition.Key)
                }
            }
        }

        It 'gives every row the same six fields' {
            $result = Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context

            foreach ($row in @($result.Data['check'])) {
                @($row.Keys) | Should -Be @('check', 'key', 'observed', 'threshold', 'result', 'reason')
            }
        }

        It 'carries only results from the closed set' {
            # A result outside the set is a rendering the summary window cannot
            # colour and a report cannot count.
            $twin = New-HDTFakeDiskService -Disk @($script:targetDisk, $script:contentDisk)
            $context = & $script:logContextFor $twin ([ordered] @{ HDTComputerName = 'LT-7FJ45S2' })

            $passed = Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $context
            $failed = Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minRamMB = 65536 })) -Context $context

            $closed = InModuleScope Hephaestus { Get-HDTValidateCheckResultName }

            foreach ($row in @($passed.Data['check']) + @($failed.Data['check'])) {
                [string] $row['result'] | Should -BeIn $closed
            }
        }

        It 'names the closed set of results exactly' {
            # A sixth result added without listing it here would be reported and
            # never rendered.
            InModuleScope Hephaestus {
                Get-HDTValidateCheckResultName | Should -Be @('pass', 'fail', 'warn', 'skipped', 'excluded')
            }
        }

        It 'keeps diskNumber and failedCheck exactly as they were' {
            $passed = Invoke-HDTValidateStep -Step (& $script:newStep $script:everyCheck) -Context $script:context
            $passed.Data['diskNumber'] | Should -Be 0

            $failed = Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minRamMB = 65536 })) -Context $script:context
            @($failed.Data['failedCheck']).Count | Should -Be 1
        }

        It 'carries the check rows on the failure path too' {
            $failed = Invoke-HDTValidateStep -Step (& $script:newStep ([ordered] @{ minRamMB = 65536 })) -Context $script:context

            $memory = @($failed.Data['check'] | Where-Object { [string] $_['key'] -eq 'minRamMB' })

            $memory.Count | Should -Be 1
            [string] $memory[0]['result'] | Should -BeExactly 'fail'
        }
    }
}
