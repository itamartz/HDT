# THE M3 BENCHMARK, and DESIGN 12.2.1's target applied to the imaging half:
#
#   "the entire task sequence engine can execute a full sequence end-to-end in a
#    Pester run against fake services, asserting the ordered list of operations
#    it WOULD have performed."
#
# This is one WinPE deployment leg - validate, partition, apply, unattend, boot -
# executed against doubles, asserting the exact ordered list of operations it
# would have performed on a machine. It is what makes 04-04's real VM run a
# CONFIRMATION rather than the first time anybody has seen this work.
#
# The sequence is samples/workspace/TaskSequences/DEMO-M3/sequence.yaml, read off
# disk and seeded into the fake filesystem as TEXT (03-05's rule), so the sample
# an administrator copies, the file 04-04 deploys and the sequence this test
# proves can never drift apart.
#
# TWO DISKS, WHICH IS THE SHAPE 04-04's VM ACTUALLY HAS: the 64 GiB RAW target
# and an 8 GiB content disk carrying the workspace volume. So the benchmark
# proves the selection rules on the same topology the real run uses, rather than
# on a machine with exactly one disk where there is nothing to get wrong.
#
# WHY THE OPERATION LIST IS FILTERED. Log writes dominate the journal by volume -
# every JSONL line is an AppendAllText - so the headline assertion keeps the
# services whose calls are SIDE EFFECTS ON A MACHINE, plus the three filesystem
# operations that are: creating a directory, writing a file and copying one. An
# unfiltered list would break on every added log line, which makes it a list
# nobody maintains and therefore nobody trusts.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # -- the sample files, read off disk -----------------------------------

    $script:sampleRoot = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace'
    $script:sampleYaml = Get-Content -LiteralPath (Join-Path -Path $script:sampleRoot -ChildPath 'TaskSequences/DEMO-M3/sequence.yaml') -Raw
    $script:sampleUnattend = Get-Content -LiteralPath (Join-Path -Path $script:sampleRoot -ChildPath 'TaskSequences/DEMO-M3/unattend.xml') -Raw
    $script:sampleCatalog = Get-Content -LiteralPath (Join-Path -Path $script:sampleRoot -ChildPath 'OperatingSystems/Win11-LTSC-2024/os.yaml') -Raw

    # -- where everything lives, as it would on the lab VM -----------------

    $script:runId = 'run-demo-m3'
    $script:workspaceRoot = 'Z:\Deploy'
    $script:sequencePath = 'Z:\Deploy\TaskSequences\DEMO-M3\sequence.yaml'
    $script:unattendTemplate = 'Z:\Deploy\TaskSequences\DEMO-M3\unattend.xml'
    $script:catalogPath = 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\os.yaml'
    $script:wimPath = 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
    $script:winrePath = 'W:\Windows\System32\Recovery\Winre.wim'
    $script:pantherPath = 'W:\Windows\Panther\unattend.xml'
    $script:logPath = 'X:\HDT\Logs'
    $script:jsonlPath = 'X:\HDT\Logs\HDT.jsonl'

    # The services whose calls are side effects on a machine.
    $script:machineService = @('DiskService', 'ImageService')
    $script:machineFileOperation = @('CreateDirectory', 'WriteAllText', 'CopyItem')

    # -- the topology 04-04's VM has ---------------------------------------

    $script:targetDiskRow = @{
        Number = 0; FriendlyName = 'Msft Virtual Disk'; SerialNumber = 'FIXTURE-SERIAL-0001'
        SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW'
    }

    $script:contentDiskRow = @{
        Number = 1; FriendlyName = 'Msft Virtual Disk'; SerialNumber = 'FIXTURE-SERIAL-0002'
        SizeBytes = 8589934592; BusType = 'SAS'; PartitionStyle = 'GPT'
    }

    # -- one leg, built the way a real one is ------------------------------

    $script:runLeg = {
        param([switch] $WithSecondBlankDisk)

        $journal = [System.Collections.ArrayList]::new()

        $fileSystem = New-HDTFakeFileSystem
        $fileSystem.SeedFile($script:sequencePath, $script:sampleYaml)
        $fileSystem.SeedFile($script:unattendTemplate, $script:sampleUnattend)
        $fileSystem.SeedFile($script:catalogPath, $script:sampleCatalog)

        # The WIM and the WinRE the apply would have left behind. Seeded rather
        # than written: neither is an operation the engine performed.
        $fileSystem.SeedFile($script:wimPath, 'WIM')
        $fileSystem.SeedFile($script:winrePath, 'WINRE')

        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 15, [System.DateTimeKind]::Utc)) -TickMillisecond 250

        $diskRow = @($script:targetDiskRow, $script:contentDiskRow)

        if ($WithSecondBlankDisk) {
            # A second blank 64 GiB disk, which is DESIGN 9.1's headline case: two
            # disks that are both perfectly good deployment targets and nothing
            # in the data to choose between them.
            $diskRow += @{
                Number = 2; FriendlyName = 'Msft Virtual Disk'; SerialNumber = 'FIXTURE-SERIAL-0003'
                SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'RAW'
            }
        }

        $disk = New-HDTFakeDiskService -Disk $diskRow -Partition @(
            @{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'Z'; SizeBytes = 8589934592
                Type = 'Basic'; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
            }
        ) -Volume @(
            @{ DriveLetter = 'Z'; FileSystem = 'NTFS'; FileSystemLabel = 'HDT Content'; SizeBytes = 8589934592 })

        $image = New-HDTFakeImageService -Image @{
            $script:wimPath = @(
                @{ Index = 1; Name = 'Windows 11 Enterprise LTSC'; Edition = 'EnterpriseS'
                    SizeBytes = 18356832906; Version = '10.0.26100.1742'
                },
                @{ Index = 2; Name = 'Windows 11 Enterprise N LTSC'; Edition = 'EnterpriseSN'
                    SizeBytes = 17928774068; Version = '10.0.26100.1742'
                })
        }

        $registry = New-HDTFakeRegistryService
        $lsa = New-HDTFakeLsaService
        $power = New-HDTFakePowerService
        $process = New-HDTFakeProcessService
        $invoker = New-HDTFakeScriptInvoker
        $cim = New-HDTFakeCimProvider
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
            -Lsa $lsa -Process $process -Power $power -ScriptInvoker $invoker -Cim $cim `
            -Environment $environment -Disk $disk -Image $image

        $sequence = Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $fileSystem

        # DESIGN 3.1: the sequence's own defaults, then what the rules resolved
        # before the sequence began. HDTMemory and HDTIsUEFI are gathered facts.
        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($sequence.Variable.Keys)) { $live[[string] $name] = $sequence.Variable[$name] }
        $live['HDTMemory'] = 4088
        $live['HDTIsUEFI'] = $true

        $log = New-HDTLogContext -RunId $script:runId -Phase 'WinPE' -LogPath $script:logPath `
            -FileSystem $fileSystem -Clock $clock -Level Debug -ThreadId 1

        $state = New-HDTRunState -SequenceId $sequence.Id -RunId $script:runId -Phase 'WinPE' `
            -Clock $clock -Variable $live -Step $sequence.Step

        $context = New-HDTExecutionContext -RunId $script:runId -Phase 'WinPE' -WorkspaceRoot $script:workspaceRoot `
            -Variable $live -Service $catalog -Log $log -State $state

        # THE JOURNAL GOES ON LAST, after every seed, so its first entry is the
        # first thing the ENGINE did (tests/helpers/README.md section 4).
        foreach ($fake in @($fileSystem, $clock, $registry, $lsa, $process, $power, $invoker,
                $cim, $environment, $disk, $image)) {

            $fake.Journal = $journal
        }

        $result = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state

        return [pscustomobject] @{
            Result     = $result
            Journal    = $journal
            FileSystem = $fileSystem
            Disk       = $disk
            Image      = $image
            Variable   = $live
            State      = $state
            Log        = $log
        }
    }

    # -- the run this file is about ----------------------------------------

    $script:stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:leg = & $script:runLeg
    $script:stopwatch.Stop()
    $script:elapsedSecond = $script:stopwatch.Elapsed.TotalSeconds

    # READ BACK OUT OF THE STAGED UNATTEND, not off the state document. DESIGN
    # 4.5.3's teardown runs in the loop's finally and NULLS state.deploymentPassword
    # at the end of a successful run, so reading it afterwards yields nothing and
    # the 'it never reached the log' assertion would pass against an empty string.
    # The document Setup will read is the one place the secret still exists.
    $script:deploymentPassword = [string] ([regex]::Match(
            $script:leg.FileSystem.ReadAllText($script:pantherPath),
            '<AdministratorPassword>\s*<Value>([^<]+)</Value>').Groups[1].Value)

    # Everything below reads the run rather than driving it.
    $script:operation = @($script:leg.Journal |
            Where-Object {
                ($script:machineService -contains $_.Service) -or
                ($_.Service -eq 'FileSystem' -and $script:machineFileOperation -contains $_.Operation -and
                    ([string] $_.Arguments[0]) -notlike 'X:\HDT\Logs*')
            } |
            ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })

    $script:finalState = $script:leg.Result.State
    $script:record = @(Get-HDTLogRecord -FileSystem $script:leg.FileSystem -Path $script:jsonlPath)
    $script:rawLog = [string] (Get-HDTLogRecord -FileSystem $script:leg.FileSystem -Path $script:jsonlPath -Raw)

    # -- and the same topology, made ambiguous -----------------------------
    #
    # One more blank 64 GiB disk, so two disks qualify and HDT must refuse rather
    # than guess which one to wipe.
    #
    # Growing the CONTENT disk instead would not have done it, and the reason is
    # worth knowing: disk 1 carries drive letter Z, which is the workspace root,
    # so rule 2 excludes it however large it is. The guard that stops HDT wiping
    # the share it is reading from also keeps that disk out of the ambiguity.
    $script:refusal = & $script:runLeg -WithSecondBlankDisk
}

Describe 'the DEMO-M3 imaging sequence, end to end against fakes' {

    Context 'the leg runs' {

        It 'completes every step' {
            @($script:finalState.step | ForEach-Object { [string] $_.status }) | Should -Be @(
                'Completed',   # 1 Validate
                'Completed',   # 2 Format and Partition
                'Completed',   # 3 Apply OS
                'Completed',   # 4 Apply Unattend
                'Completed')   # 5 Prepare Boot
        }

        It 'writes no step.fail record' {
            @($script:record | Where-Object { $_.event -eq 'step.fail' }) | Should -BeNullOrEmpty
        }

        It 'reports Succeeded' {
            $script:leg.Result.Status | Should -BeExactly 'Succeeded'
            $script:finalState.status | Should -BeExactly 'Succeeded'
        }

        It 'never asked for a reboot' {
            # DEMO-M3 has no Restart step: the WinPE -> full OS handoff is phase
            # 05's, and the first logon is configured by the unattend.
            @($script:record | Where-Object { $_.event -eq 'reboot.arm' }) | Should -BeNullOrEmpty
        }
    }

    Context 'performed exactly these operations, in this order' {

        It 'performed exactly these operations, in this order' {
            # THIS LIST IS THE SPECIFICATION OF WHAT HDT DOES TO A MACHINE in the
            # WinPE half of a deployment. A future refactor that changes it
            # announces itself as a diff here, which is the entire point of
            # writing it out in full with a comment per line.
            #
            # ASSERTED AS ONE NEWLINE-JOINED STRING rather than as two arrays,
            # because Pester abbreviates a long array to '...16 more' - and a
            # failure message that hides the operation which changed is not the
            # specification a human can read. Joined, the whole actual list is
            # printed under -Because.
            $expectedOperation = @(

                # -- 1 Validate: the pre-flight reads, and only reads ----------
                'DiskService.GetDisk'
                'DiskService.GetPartition'
                'DiskService.GetVolume'

                # -- 2 Format and Partition -----------------------------------
                'DiskService.GetDisk'                   # the three listings again, for the real selection
                'DiskService.GetPartition'
                'DiskService.GetVolume'
                # NO ClearDisk. The lab VM's target disk is RAW - a brand-new
                # VHDX, exactly as a factory-fresh machine's disk is - and 04-04
                # found by running it that Clear-Disk throws "The disk has not
                # been initialized" on a RAW disk. There is nothing to clear, so
                # the step does not try. On a redeploy, where the disk carries a
                # partition table, ClearDisk appears here.
                'DiskService.InitializeDisk'            # GPT; THIS is what creates the MSR
                'DiskService.NewPartition'              # ESP, created as basic data so it can take a letter
                'DiskService.SetPartitionDriveLetter'   # S:
                'DiskService.FormatVolume'              # FAT32
                'DiskService.SetPartitionType'          # now it becomes the ESP
                'DiskService.NewPartition'              # Windows
                'DiskService.SetPartitionDriveLetter'   # W:
                'DiskService.FormatVolume'              # NTFS
                'DiskService.NewPartition'              # Recovery, UseMaximumSize
                'DiskService.SetPartitionDriveLetter'   # R:
                'DiskService.FormatVolume'              # NTFS
                'DiskService.SetPartitionType'          # the recovery type

                # -- 3 Apply OS -----------------------------------------------
                'ImageService.ApplyImage'               # index 1 to W:\

                # -- 4 Apply Unattend -----------------------------------------
                'FileSystem.CreateDirectory'            # W:\Windows\Panther
                'FileSystem.WriteAllText'               # unattend.xml (SPIKES S7's verified location)

                # -- 5 Prepare Boot -------------------------------------------
                'ImageService.InstallBootFile'          # bcdboot W:\Windows /s S: /f UEFI
                'FileSystem.CreateDirectory'            # R:\Recovery\WindowsRE
                'FileSystem.CopyItem'                   # Winre.wim, out of the applied image
                'ImageService.SetRecoveryImage'         # the applied image's own Reagentc.exe
                'ImageService.SetBootOrderFirst'        # SPIKES S6: or the machine reboots into WinPE
            )

            ($script:operation -join [System.Environment]::NewLine) |
                Should -BeExactly ($expectedOperation -join [System.Environment]::NewLine) `
                    -Because ("the leg performed:{0}{1}" -f [System.Environment]::NewLine,
                        ($script:operation -join [System.Environment]::NewLine))
        }

        It 'read the image catalog rather than the WIM' {
            # os.yaml carries the indices, so the apply does not have to open a
            # 4 GB file over SMB to find out what is in it.
            @($script:leg.Image.GetOperationName()) | Should -Not -Contain 'GetImageInfo'
        }
    }

    Context 'the machine it would have left behind' {

        It 'left exactly four partitions on the target disk' {
            @($script:leg.Disk.Partition | Where-Object { $_.DiskNumber -eq 0 }).Count | Should -Be 4
        }

        It 'left exactly one reserved partition' {
            # The implicit MSR that Initialize-Disk made, and NOT a second one
            # created by hand - which is the bug SPIKES S6 found in
            # PSDPartition.ps1 and the reason the fake models this at all.
            @($script:leg.Disk.Partition | Where-Object { $_.DiskNumber -eq 0 -and $_.Type -eq 'Reserved' }).Count |
                Should -Be 1
        }

        It 'left a 260MB FAT32 system partition' {
            $esp = @($script:leg.Disk.Partition | Where-Object { $_.DriveLetter -eq 'S' })[0]
            $volume = @($script:leg.Disk.Volume | Where-Object { $_.DriveLetter -eq 'S' })[0]

            $esp.SizeBytes | Should -Be 272629760
            $esp.Type | Should -BeExactly 'System'
            $volume.FileSystem | Should -BeExactly 'FAT32'
        }

        It 'left the Windows volume as NTFS' {
            $volume = @($script:leg.Disk.Volume | Where-Object { $_.DriveLetter -eq 'W' })[0]

            $volume.FileSystem | Should -BeExactly 'NTFS'
            $volume.FileSystemLabel | Should -BeExactly 'Windows'
        }

        It 'left a recovery partition with the recovery type' {
            $recovery = @($script:leg.Disk.Partition | Where-Object { $_.DriveLetter -eq 'R' })[0]

            $recovery.Type | Should -BeExactly 'Recovery'
            $recovery.GptType | Should -BeExactly '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        }

        It 'never touched the content disk' {
            # Disk 1 carries the workspace volume. Every write names disk 0.
            $written = @($script:leg.Disk.Operations |
                    Where-Object { $_.Operation -notlike 'Get*' -and $_.Operation -ne 'FormatVolume' } |
                    ForEach-Object { [int] $_.Arguments[0] })

            @($written | Where-Object { $_ -ne 0 }) | Should -BeNullOrEmpty
            @($script:leg.Disk.Partition | Where-Object { $_.DiskNumber -eq 1 }).Count | Should -Be 1
        }

        It 'staged the unattend at W:\Windows\Panther\unattend.xml' {
            $script:leg.FileSystem.TestPath($script:pantherPath) | Should -BeTrue
        }

        It 'expanded the computer name into the unattend' {
            $script:leg.FileSystem.ReadAllText($script:pantherPath) |
                Should -BeLike '*<ComputerName>HDT-M3-01</ComputerName>*'
        }

        It 'staged an unattend that still parses as XML' {
            { [xml] $script:leg.FileSystem.ReadAllText($script:pantherPath) } | Should -Not -Throw
        }

        It 'applied index 1' {
            $apply = @($script:leg.Image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0]

            [string] $apply.Arguments[0] | Should -BeExactly $script:wimPath
            [int] $apply.Arguments[1] | Should -Be 1
            [string] $apply.Arguments[2] | Should -BeExactly 'W:\'
        }

        It 'wrote UEFI boot files from W: to S:' {
            $boot = @($script:leg.Image.Operations | Where-Object { $_.Operation -eq 'InstallBootFile' })[0]

            [string] $boot.Arguments[0] | Should -BeExactly 'W:\'
            [string] $boot.Arguments[1] | Should -BeExactly 'S:'
            [string] $boot.Arguments[2] | Should -BeExactly 'UEFI'
        }
    }

    Context 'the variables it published' {

        It 'published HDTTargetDisk' {
            $script:leg.Variable['HDTTargetDisk'] | Should -Be 0
        }

        It 'published HDTSystemVolume' {
            $script:leg.Variable['HDTSystemVolume'] | Should -BeExactly 'S'
        }

        It 'published HDTOSVolume' {
            $script:leg.Variable['HDTOSVolume'] | Should -BeExactly 'W'
        }

        It 'published HDTRecoveryVolume' {
            $script:leg.Variable['HDTRecoveryVolume'] | Should -BeExactly 'R'
        }

        It 'published HDTImageIndex' {
            $script:leg.Variable['HDTImageIndex'] | Should -Be 1
        }

        It 'published HDTUnattendPath' {
            [string] $script:leg.Variable['HDTUnattendPath'] | Should -BeExactly $script:pantherPath
        }

        It 'carried them into the state document' {
            $script:finalState.variable['HDTOSVolume'] | Should -BeExactly 'W'
            $script:finalState.variable['HDTImageIndex'] | Should -Be 1
        }
    }

    Context 'it touched nothing real' {

        It 'wrote no file on the real filesystem' {
            foreach ($path in @('W:\Windows\Panther\unattend.xml', 'R:\Recovery\WindowsRE',
                    'X:\HDT\Logs\HDT.jsonl', 'Z:\Deploy\TaskSequences')) {

                Test-Path -LiteralPath $path | Should -BeFalse -Because "$path exists only inside the fake"
            }
        }

        It 'left the deployment password out of the log' {
            # The unattend carries it twice; the log carries it never.
            $script:deploymentPassword | Should -Not -BeNullOrEmpty
            $script:rawLog | Should -Not -BeLike ('*{0}*' -f $script:deploymentPassword)
        }

        It 'left the unattend body out of the log' {
            $script:rawLog | Should -Not -BeLike '*AdministratorPassword*'
        }

        It 'finished in seconds' {
            # A run that waited on anything real could not: SPIKES S6 measured
            # 95 seconds for the apply alone.
            $script:elapsedSecond | Should -BeLessThan 15
        }

        It 'started no process and rebooted nothing' {
            @($script:leg.Journal | Where-Object { $_.Service -eq 'ProcessService' }) | Should -BeNullOrEmpty
            @($script:leg.Journal | Where-Object { $_.Service -eq 'PowerService' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the refusal, on the same topology' {

        # The same machine with one more blank 64 GiB disk. Both are perfectly
        # good targets and nothing in the data chooses between them, so HDT
        # refuses - which is DESIGN 9.1's entire subject.

        It 'refuses when two disks qualify' {
            $script:refusal.Result.Status | Should -BeExactly 'Failed'
        }

        It 'refuses in the pre-flight, before anything destructive' {
            # The Validate step runs the SAME selection with the SAME arguments,
            # so the refusal happens in step 1 and the destructive step is never
            # reached at all. That is the whole reason Validate exists.
            $validate = @($script:refusal.Result.State.step | Where-Object { $_.index -eq 1 })[0]

            $validate.status | Should -BeExactly 'Failed'
        }

        It 'never reached the partition step' {
            $partition = @($script:refusal.Result.State.step | Where-Object { $_.index -eq 2 })[0]

            $partition.status | Should -Not -BeExactly 'Completed'
        }

        It 'cleared no disk' {
            @($script:refusal.Disk.GetOperationName() | Where-Object { $_ -eq 'ClearDisk' }) | Should -BeNullOrEmpty
        }

        It 'created no partition' {
            @($script:refusal.Disk.GetOperationName() | Where-Object { $_ -eq 'NewPartition' }) | Should -BeNullOrEmpty
        }

        It 'applied no image' {
            @($script:refusal.Image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'names both candidate disks in the refusal' {
            $message = [string] @($script:refusal.Result.Result | Where-Object { $_.Index -eq 1 })[0].Message

            $message | Should -BeLike '*disk 0*'
            $message | Should -BeLike '*disk 2*'
        }

        It 'leaves the workspace disk out of the ambiguity' {
            # Disk 1 holds Z:, the workspace root, so rule 2 excludes it before
            # the count is taken - and the message does not offer it as a choice.
            $message = [string] @($script:refusal.Result.Result | Where-Object { $_.Index -eq 1 })[0].Message

            $message | Should -Not -BeLike '*disk 1*'
        }

        It 'classifies the refusal as Configuration, so it is never retried' {
            @($script:refusal.Result.Result | Where-Object { $_.Index -eq 1 })[0].FailureClass |
                Should -BeExactly 'Configuration'
        }
    }
}
