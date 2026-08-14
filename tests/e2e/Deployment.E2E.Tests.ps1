# ROADMAP M3's EXIT CRITERION, AS AN EXECUTABLE TEST.
#
#   "a VM boots into Windows from a sequence run end-to-end"
#
# A Generation 2 VM on the isolated 'HDT Lab' switch is booted from a boot image
# THIS FILE BUILDS, whose startnet.cmd launches Start-HDTLabDeployment.ps1, and
# Invoke-HDTTaskSequence runs samples/workspace/TaskSequences/DEMO-M3 -
# Validate, DiskPartition, ApplyImage, ApplyUnattend, ConfigureBoot - against
# the REAL disk and image services. Then the VM is started again, WITHOUT
# touching the boot order or ejecting the ISO, and must reach full Windows.
#
# WHAT MAKES THAT LAST SENTENCE THE POINT. SPIKES S6's fourth finding: after an
# apply, a machine whose firmware still has the boot media first simply reboots
# into WinPE and the deployment appears to loop. ConfigureBoot's
# SetBootOrderFirst is what ends the loop, and it has never run anywhere but
# here - it edits the firmware boot order of the machine it runs on, so it
# cannot be tested on the developer's. A VM that boots WinPE again FAILS this
# file, and that failure is the finding.
#
# THE ASSERTION THAT THE MACHINE REACHED WINDOWS IS THE INTEGRATION-SERVICES
# HEARTBEAT, not a screenshot. WinPE carries no integration services and never
# reports one; full Windows does. The screenshot is saved for a human to look
# at, which is diagnosis rather than assertion.
#
# LAB SAFETY. Every Hyper-V call is module-qualified and name-filtered. CM01 and
# DC01 are recorded before anything starts and asserted identical afterwards, in
# an AfterAll that runs even when the test failed. Nothing here creates a VM
# except through New-HDTLabVirtualMachine, whose guards are unit tested.
#
# NOTHING TYPES AT THE PROMPT. This file used to send a
# 'for %d in (C D E F G) do @if exist ...' line to the VM's keyboard, because
# the hand-built WinPE ISO ran a startnet.cmd that launched nothing. It builds
# its own image now: workspace.yaml's extraContent stages the launcher inside
# the image and entryCommand points startnet.cmd at it, so the launcher runs
# from X: - the RAM disk, whose letter is fixed - with nothing to scan for.
# tests/contract/NoKeystroke.Contract.Tests.ps1 keeps it that way.
#
# THE LAUNCHER IS STILL THIS FILE'S OWN, not src/Hephaestus/Payload's. Keeping
# it is what keeps this file distinct from UnattendedDeployment.E2E: the engine
# is loaded off the CONTENT DISK here, which is the topology where the boot
# image is thin and the share carries the code.

BeforeDiscovery {
    $script:wimPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:discoveryWim = Test-Path -LiteralPath $script:wimPath -PathType Leaf

    # THE ADK, not a pre-built ISO: this file builds the image it boots.
    $script:discoveryAdk = $false
    try {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:discoveryAdk = $true
    } catch {
        $script:discoveryAdk = $false
    }

    $script:skipDeployment = (-not $script:discoveryWim) -or (-not $script:discoveryAdk)

    if ($script:skipDeployment) {
        Write-Warning ("Deployment.E2E.Tests.ps1 is SKIPPED. It builds its own boot image and deploys Windows 11 to a VM, which needs the staged media (currently present: {0}) and the Windows ADK with the Windows PE add-on (currently resolvable: {1})." -f
            $script:discoveryWim, $script:discoveryAdk)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:vmName = 'HDT-M3-Deploy'
    $script:vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M3-Deploy-osdisk.vhdx'
    $script:contentPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M3-Deploy-content.vhdx'
    $script:wimPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'

    # The image this file builds. Its own build root, so it cannot overwrite the
    # artifacts UnattendedDeployment.E2E or WinPeSmoke.E2E built.
    $script:isoPath = ''
    $script:buildRoot = 'C:\HDTLab\scratch\e2e-m3-bootimage'
    $script:buildWorkspace = Join-Path -Path $script:buildRoot -ChildPath 'Share'
    $script:buildScratch = Join-Path -Path $script:buildRoot -ChildPath 'work'
    $script:launcherStaging = Join-Path -Path $script:buildRoot -ChildPath 'stage'
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e'

    # THE PROTECTED PAIR, RECORDED BEFORE ANYTHING STARTS.
    #
    # MemoryStartup, NOT MemoryStartupBytes. The property is called
    # MemoryStartupBytes on New-VM's PARAMETER and MemoryStartup on the object
    # Get-VM returns, and that difference is not cosmetic here: without
    # StrictMode a missing property is $null, [long] $null is 0, and this
    # snapshot compared 0 with 0 - so the assertion that protects the user's
    # lab was passing while comparing nothing at all (helpers README 12).
    #
    # It surfaced only under ./build.ps1 -Task e2e, which sets
    # Set-StrictMode -Version Latest; a bare Invoke-Pester does not. Run the
    # E2E through the build script.
    $script:snapshotProtected = {
        # EVERY VM THIS SUITE DOES NOT OWN, not two names.
        #
        # It used to read 'CM01', 'DC01' explicitly. When those two were deleted
        # from this host the snapshot became an empty array, and comparing an
        # empty array with an empty array afterwards held while checking nothing
        # - the same shape as SPIKES S9.14, where the lab-safety assertion
        # compared 0 with 0 through six green runs.
        #
        # Reading every non-HDT-* VM instead means the guard covers whatever the
        # user builds next without anyone remembering to add its name, and the
        # count is asserted separately so an empty host reads as "there was
        # nothing to protect" rather than as "nothing was harmed".
        return @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
                Sort-Object Name |
                ForEach-Object {
                    [pscustomobject] @{
                        Name   = [string] $_.Name
                        State  = [string] $_.State
                        Memory = [long] $_.MemoryStartup
                        Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                    ForEach-Object { [string] $_.SwitchName }) -join ',')
                    }
                })
    }

    $script:protectedBefore = & $script:snapshotProtected

    # -- a helper that reads a file off the content disk, read-only ---------

    $script:readContent = {
        param([scriptblock] $Reader)

        $answer = $null
        try {
            Mount-DiskImage -ImagePath $script:contentPath -StorageType VHDX -Access ReadOnly | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $script:contentPath).Number
            $letter = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } | ForEach-Object { [string] $_.DriveLetter })

            if ($letter.Count -ge 1) {
                $answer = & $Reader ('{0}:' -f $letter[0])
            }
        } finally {
            Dismount-DiskImage -ImagePath $script:contentPath -ErrorAction SilentlyContinue | Out-Null
        }

        return $answer
    }

    $script:result = $null
    $script:record = @()
    $script:rawJsonl = ''
    $script:logFirstByte = @()
    $script:state = $null
    $script:launcherLog = ''
    $script:endedCleanly = $false
    $script:deploymentSecond = 0
    $script:bootedWindows = $false
    $script:heartbeatSecond = 0
    $script:offlineComputerName = ''
    $script:stoppedGracefully = $false
    $script:targetPartition = @()
    $script:targetFile = @{}

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope: $script:skipDeployment is set at discovery for
    # the -Skip: on each Describe, and reading it here throws under StrictMode -
    # which ./build.ps1 sets and a bare Invoke-Pester does not. Without
    # StrictMode it evaluated to $null, and 'if (-not $null)' is TRUE, so the
    # whole deployment ran on a machine that was supposed to skip it.
    $script:canDeploy = $false
    if (Test-Path -LiteralPath $script:wimPath -PathType Leaf) {
        try {
            [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
            $script:canDeploy = $true
        } catch {
            $script:canDeploy = $false
        }
    }

    if ($script:canDeploy) {

        # -- rule 4: the memory budget, before anything is started ----------

        $runningByte = [long] 0
        foreach ($vm in @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.State -eq 'Running' })) {
            $runningByte += [long] $vm.MemoryAssigned
        }

        if (($runningByte + 4294967296) -gt 12884901888) {
            throw ("running HDT VMs already hold {0} bytes; starting a 4 GB test VM would exceed the 12 GB lab budget (PROJECT.md rule 4)." -f $runningByte)
        }

        # -- the boot image, built by the product ---------------------------
        #
        # extraContent stages a DIRECTORY (Copy-HDTContentTree walks children),
        # so the launcher is copied into a staging folder of its own rather than
        # pointing extraContent at tests/e2e/payload and dragging the probe in
        # beside it.

        foreach ($folder in @($script:buildWorkspace,
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Boot'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Control'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Logs'),
                $script:launcherStaging)) {

            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
            }
        }

        Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/payload/Start-HDTLabDeployment.ps1') `
            -Destination (Join-Path -Path $script:launcherStaging -ChildPath 'Start-HDTLabDeployment.ps1') -Force

        $utf8NoBomBuild = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'workspace.yaml'), @"
# Written by tests/e2e/Deployment.E2E.Tests.ps1.
#
# entryCommand launches THIS FILE'S launcher rather than the deployment payload
# (DESIGN 5.1), and extraContent is what puts it where entryCommand says it is.
# X: is the WinPE RAM disk and its letter is fixed, which is why the launcher no
# longer has to be found by a drive scan typed at the prompt.
#
# The launcher still finds the ENGINE by scanning, and that is deliberate: the
# engine lives on the content disk here, not in the image.
schemaVersion: 1
id: HDT-LAB-M3
name: HDT M3 exit criterion workspace
deployRoot: \Share
logLevel: Debug
bootImage:
  name: HDTPE_m3_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  extraContent:
    - source: $script:launcherStaging
      destination: \HDT
  entryCommand: powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTLabDeployment.ps1
"@, $utf8NoBomBuild)

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", $utf8NoBomBuild)

        $bootBuildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $script:build = Update-HDTBootImage -WorkspaceRoot $script:buildWorkspace `
            -ScratchPath $script:buildScratch -Confirm:$false

        $bootBuildStopwatch.Stop()
        $script:isoPath = [string] $script:build.IsoPath

        Write-Information ("boot image built in {0}s: {1}" -f
            [int] $bootBuildStopwatch.Elapsed.TotalSeconds, $script:isoPath) -InformationAction Continue

        # -- the content disk: engine, parser, workspace, media -------------
        #
        # Every path under Share\ is written here BY HAND in the layout
        # Get-HDTWorkspacePath defines; the engine reading it builds the same
        # paths through that function, and 'the harness and the engine agree'
        # below asserts the two match.

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        # -- the 64 GB target and the VM, BEFORE the content disk -----------
        #
        # THE ORDER MATTERS, and the reason is DESIGN 3.1's second variable
        # source. rules.yaml's fallback sets HDTComputerName from the serial
        # number - and rules outrank a sequence's own defaults - so on a Hyper-V
        # VM whose serial is 32 characters, DEMO-M3's 'HDT-M3-01' loses to a
        # 35-character name that Windows Setup silently discards (04-04, first
        # deployment run: the machine came up as WIN-N91191NN153).
        #
        # The right answer is not to edit the sample rules: it is the mechanism
        # HDT already has for making one machine an exception. A per-machine
        # override is keyed on the machine's UUID, so the VM has to exist before
        # the content disk that carries the override can be written.

        if (Test-Path -LiteralPath $script:osDiskPath) {
            Remove-Item -LiteralPath $script:osDiskPath -Force
        }

        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 68719476736 -Dynamic | Out-Null

        # Disk 0 is the target. The content disk is attached after it is built,
        # so the target is certainly disk 0 - and DEMO-M3's minDiskGB: 60
        # excludes the 8 GB content disk by size, while DiskPartition ALSO
        # protects it by drive letter. Two independent rules stand between the
        # engine and the workspace it is reading.
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT Lab' -VhdPath @($script:osDiskPath) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

        # The UUID the guest will report as HDTUUID. Hyper-V holds it as the
        # firmware BIOS GUID, in braces.
        $vmSetting = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemSettingData' |
                Where-Object { $_.ConfigurationID -eq [string] (Hyper-V\Get-VM -Name $script:vmName).Id })

        $script:vmUuid = ''
        if ($vmSetting.Count -ge 1 -and $null -ne $vmSetting[0].BIOSGUID) {
            $script:vmUuid = ([string] $vmSetting[0].BIOSGUID).Trim('{', '}').ToUpperInvariant()
        }

        if ([string]::IsNullOrWhiteSpace($script:vmUuid)) {
            # Not a Should: this is a BeforeAll, and a failed assertion here
            # would report as a mystery in every test below it.
            throw "could not read the BIOS GUID of '$script:vmName'; the per-machine override is keyed on it."
        }

        Write-Information ("VM UUID: {0}" -f $script:vmUuid) -InformationAction Continue

        # The override itself, written to a scratch file the content disk copies.
        $overrideStaging = Join-Path -Path $script:artifactRoot -ChildPath 'machines'
        if (-not (Test-Path -LiteralPath $overrideStaging -PathType Container)) {
            New-Item -Path $overrideStaging -ItemType Directory -Force | Out-Null
        }

        $script:overrideFile = Join-Path -Path $overrideStaging -ChildPath ('{0}.yaml' -f $script:vmUuid)

        [System.IO.File]::WriteAllText($script:overrideFile, @"
# Written by tests/e2e/Deployment.E2E.Tests.ps1 for this run's VM.
#
# DESIGN 3.1 source 2. rules.yaml's fallback would name this machine
# PC-<32 character VM serial>, which is over the 15 character NetBIOS limit and
# which Windows Setup silently discards. An override is how one machine is made
# an exception without editing rules.yaml, and it beats every rule below it.
schemaVersion: 1
variables:
  HDTComputerName: HDT-M3-01
"@)

        $yamlModule = @(Get-Module -Name 'powershell-yaml' -ListAvailable | Sort-Object Version -Descending)[0]

        Write-Information ("staging content: powershell-yaml {0}, and a 4 GB install.wim" -f $yamlModule.Version) -InformationAction Continue

        $contentStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        New-HDTLabContentDisk -Path $script:contentPath -SizeByte 8589934592 -Confirm:$false -Source @{
            ('Share\Control\machines\{0}.yaml' -f $script:vmUuid)         = $script:overrideFile
            'HDT\Modules\Hephaestus'                                     = (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus')
            # The launcher is NOT here any more: it is inside the boot image,
            # staged by extraContent and launched by startnet.cmd. The engine
            # and the parser stay, because the launcher loads them from here.
            'HDT\Modules\powershell-yaml'                                = [string] $yamlModule.ModuleBase
            'Share\rules.yaml'                                           = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/rules.yaml')
            'Share\Scripts'                                              = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/Scripts')
            # THE SAMPLE FILES, COPIED, NOT RETYPED. The benchmark in
            # tests/unit/Imaging.EndToEnd.Tests.ps1 reads the same sequence off
            # disk, so the sample, the benchmark and this run cannot drift.
            'Share\TaskSequences\DEMO-M3'                                = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences/DEMO-M3')
            'Share\OperatingSystems\Win11-LTSC-2024\os.yaml'             = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/OperatingSystems/Win11-LTSC-2024/os.yaml')
            'Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = $script:wimPath
        } | Out-Null

        $contentStopwatch.Stop()
        Write-Information ("content disk staged in {0}s" -f [int] $contentStopwatch.Elapsed.TotalSeconds) -InformationAction Continue

        # Attached second, so the target is certainly disk 0.
        Hyper-V\Add-VMHardDiskDrive -VMName $script:vmName -Path $script:contentPath

        # -- boot WinPE and start the launcher ------------------------------

        $deployStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        # NOTHING IS SENT TO THIS MACHINE. startnet.cmd launches the launcher,
        # so these screenshots are diagnosis rather than a moment we have to hit:
        # the first is taken once WinPE is up and the sequence should be running,
        # and a bare X:\Windows\System32> prompt in it means startnet.cmd did not
        # launch anything.
        Start-Sleep -Seconds 150

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'deploy-01-winpe.png') | Out-Null

        Start-Sleep -Seconds 60
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'deploy-02-running.png') | Out-Null

        # The launcher shuts the machine down when the sequence ends, whatever
        # the outcome - so this is how the harness knows, rather than guessing.
        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 45

        $deployStopwatch.Stop()
        $script:deploymentSecond = [int] $deployStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'deploy-03-ended.png') | Out-Null
        Write-Information ("the WinPE leg ended after {0}s (clean shutdown: {1})" -f $script:deploymentSecond, $script:endedCleanly) -InformationAction Continue

        # -- read the evidence off the content disk -------------------------

        $harvest = & $script:readContent {
            param([string] $Drive)

            $logRoot = '{0}\Share\Logs' -f $Drive
            $answer = @{ Result = $null; Jsonl = ''; State = $null; Launcher = ''; FirstByte = @() }

            $resultPath = Join-Path -Path $logRoot -ChildPath 'RESULT.json'
            if (Test-Path -LiteralPath $resultPath) {
                $answer['Result'] = ConvertFrom-Json ([System.IO.File]::ReadAllText($resultPath))
            }

            $launcherPath = Join-Path -Path $logRoot -ChildPath 'LAUNCHER.log'
            if (Test-Path -LiteralPath $launcherPath) {
                $answer['Launcher'] = [System.IO.File]::ReadAllText($launcherPath)
            }

            # Copy-HDTLog writes <Logs>\<ComputerName>-<RunId>\.
            $runFolder = @(Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)

            if ($runFolder.Count -ge 1) {
                $jsonlPath = Join-Path -Path $runFolder[0].FullName -ChildPath 'HDT.jsonl'
                if (Test-Path -LiteralPath $jsonlPath) {
                    $answer['Jsonl'] = [System.IO.File]::ReadAllText($jsonlPath)
                }

                $masterPath = Join-Path -Path $runFolder[0].FullName -ChildPath 'HDT.log'
                if (Test-Path -LiteralPath $masterPath) {
                    $answer['FirstByte'] = @([System.IO.File]::ReadAllBytes($masterPath) | Select-Object -First 4)
                }

                $statePath = Join-Path -Path $runFolder[0].FullName -ChildPath 'state.json'
                if (Test-Path -LiteralPath $statePath) {
                    $answer['State'] = ConvertFrom-Json ([System.IO.File]::ReadAllText($statePath))
                }
            }

            return $answer
        }

        if ($null -ne $harvest) {
            $script:result = $harvest['Result']
            $script:rawJsonl = [string] $harvest['Jsonl']
            $script:state = $harvest['State']
            $script:launcherLog = [string] $harvest['Launcher']
            $script:logFirstByte = @($harvest['FirstByte'])

            if (-not [string]::IsNullOrWhiteSpace($script:rawJsonl)) {
                $script:record = @(($script:rawJsonl -split "`r?`n") |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ConvertFrom-Json $_ })
            }
        }

        Write-Information ("RESULT.json status: {0}" -f $(if ($null -ne $script:result) { [string] $script:result.status } else { '<absent>' })) -InformationAction Continue

        # PERSIST THE EVIDENCE THE ASSERTIONS ARE MADE FROM. Everything above was
        # read into memory off a content disk that the AfterAll destroys, so a
        # claim like 'reported Succeeded on all five steps' could only ever be
        # re-checked by re-running the whole deployment. Screenshots were being
        # kept and the four files the assertions actually rest on were not.
        if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
            New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
        }

        if ($null -ne $script:result) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'RESULT.json'),
                ($script:result | ConvertTo-Json -Depth 12))
        }
        if ($null -ne $script:state) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'state.json'),
                ($script:state | ConvertTo-Json -Depth 12))
        }
        if (-not [string]::IsNullOrWhiteSpace($script:rawJsonl)) {
            # Verbatim, not re-serialised: the seq continuity and the record
            # shape are the things a later reader needs to check.
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'),
                $script:rawJsonl)
        }
        if (-not [string]::IsNullOrWhiteSpace($script:launcherLog)) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAUNCHER.log'),
                $script:launcherLog)
        }

        # THE CAPTURE THAT CLOSES tests/fixtures/disk/gen2-vm-raw-disk.json's
        # DEBT: a Generation 2 VM's virgin 64 GB disk, read through IDiskService
        # a moment before the deployment repartitioned it. Saved outside the VM,
        # because the AfterAll destroys both its disks.
        if ($null -ne $script:result -and $null -ne $script:result.diskBefore) {
            if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
                New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'DISK-BEFORE.json'),
                (ConvertTo-Json -InputObject @($script:result.diskBefore) -Depth 4))
        }

        # -- read the machine it built, off the target VHDX -----------------

        # MOUNTED READ-WRITE, AND ONLY FOR ONE REASON: Windows does not give an
        # EFI System partition a drive letter, so bootmgfw.efi cannot be read
        # off a read-only mount at all - the first run of this file reported it
        # missing on a machine that had demonstrably booted from it. The ESP is
        # given a temporary letter, read, and the letter removed again. Nothing
        # on the disk is modified; this is our own throwaway VHDX.
        $espLetter = 'Q'

        try {
            Mount-DiskImage -ImagePath $script:osDiskPath -StorageType VHDX -Access ReadWrite | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $script:osDiskPath).Number
            $script:targetPartition = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Select-Object PartitionNumber, Size, Type, GptType, DriveLetter, Offset)

            $esp = @($script:targetPartition |
                    Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and -not $_.DriveLetter })

            $espLettered = $false
            if ($esp.Count -eq 1 -and -not (Test-Path -LiteralPath ('{0}:\' -f $espLetter))) {
                try {
                    Set-Partition -DiskNumber $number -PartitionNumber ([int] $esp[0].PartitionNumber) `
                        -NewDriveLetter $espLetter -ErrorAction Stop
                    $espLettered = $true
                } catch {
                    Write-Warning ("could not letter the ESP for inspection: {0}" -f $_.Exception.Message)
                }
            }

            $drive = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } | ForEach-Object { '{0}:' -f $_.DriveLetter })

            foreach ($letter in $drive) {
                foreach ($relative in @('Windows\System32\ntoskrnl.exe',
                        'EFI\Microsoft\Boot\bootmgfw.efi',
                        'EFI\Microsoft\Boot\BCD',
                        'Windows\Panther\unattend.xml')) {

                    $path = Join-Path -Path $letter -ChildPath $relative
                    if (Test-Path -LiteralPath $path) {
                        $script:targetFile[$relative] = $true

                        if ($relative -like '*unattend.xml') {
                            $script:targetFile['unattendText'] = [System.IO.File]::ReadAllText($path)
                        }
                    }
                }
            }

            if ($espLettered) {
                Remove-PartitionAccessPath -DiskNumber $number -PartitionNumber ([int] $esp[0].PartitionNumber) `
                    -AccessPath ('{0}:\' -f $espLetter) -ErrorAction SilentlyContinue
            }

            # Saved outside the VM: the AfterAll destroys this disk, and the
            # partition table is the evidence for everything below.
            if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
                New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'TARGET-PARTITION.json'),
                (ConvertTo-Json -InputObject @($script:targetPartition) -Depth 4))
        } finally {
            Dismount-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue | Out-Null
        }

        # -- THE EXIT CRITERION: start it again and change NOTHING ----------
        #
        # No boot order edit, no ejected ISO. If ConfigureBoot did its job the
        # firmware now prefers the Windows Boot Manager; if it did not, this VM
        # boots WinPE again and reports no heartbeat, which is a failure and a
        # finding rather than something to work around.

        if ($null -ne $script:result -and [string] $script:result.status -eq 'Succeeded') {
            $bootStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            Hyper-V\Start-VM -Name $script:vmName

            # Settle across a window: ComputerName is applied in the specialize
            # pass and the heartbeat can appear while Setup is still working, so
            # a VM stopped at the first Ok may not have committed it yet.
            $script:bootedWindows = Wait-HDTLabVmState -Name $script:vmName -Heartbeat `
                -TimeoutMinute 25 -SettleMinute 4

            $bootStopwatch.Stop()
            $script:heartbeatSecond = [int] $bootStopwatch.Elapsed.TotalSeconds

            Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'deploy-04-windows.png') | Out-Null
            Write-Information ("first Windows boot reported a settled heartbeat after {0}s: {1}" -f $script:heartbeatSecond, $script:bootedWindows) -InformationAction Continue

            # GRACEFULLY, through integration services, so specialize's writes
            # are committed before the disk is read offline. -TurnOff only after
            # a timeout, and the summary records that it had to.
            try {
                Hyper-V\Stop-VM -Name $script:vmName -Force -Confirm:$false -ErrorAction Stop
                $script:stoppedGracefully = $true
            } catch {
                Write-Warning ("graceful stop failed ({0}); turning it off" -f $_.Exception.Message)
                Hyper-V\Stop-VM -Name $script:vmName -TurnOff -Force -Confirm:$false
            }

            [void] (Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 10)

            $script:offlineComputerName = Get-HDTLabOfflineComputerName -VhdPath $script:osDiskPath
            Write-Information ("offline computer name: '{0}'" -f $script:offlineComputerName) -InformationAction Continue
        }
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.
    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        try {
            foreach ($path in @($script:contentPath, $script:osDiskPath)) {
                if ($path -and (Test-Path -LiteralPath $path)) {
                    $image = Get-DiskImage -ImagePath $path -ErrorAction SilentlyContinue
                    if ($null -ne $image -and $image.Attached) {
                        Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        } catch {
            Write-Warning ("could not dismount a lab VHDX: {0}" -f $_.Exception.Message)
        }

        if ($env:HDT_KEEP_LAB_VM -eq '1') {
            Hyper-V\Stop-VM -Name 'HDT-M3-Deploy' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M3-Deploy was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M3-Deploy' -Confirm:$false
        }
    }
}

Describe 'the engine ran the deployment' -Tag 'E2E' -Skip:$skipDeployment {

    It 'ended by shutting the machine down rather than by timing out' {
        $script:endedCleanly | Should -BeTrue -Because ('the WinPE leg ran for {0}s' -f $script:deploymentSecond)
    }

    It 'wrote a RESULT.json' {
        $script:result | Should -Not -BeNullOrEmpty -Because $script:launcherLog
    }

    It 'was started by startnet.cmd, not by anything typed at the prompt' {
        # THE ASSERTION THAT MAKES THIS FILE'S HEADER TRUE, and it is the guest's
        # own answer rather than a property of the harness source.
        # HDT_LAUNCHED_BY is set by the image's startnet.cmd - written from
        # workspace.yaml's entryCommand - and by nothing else.
        [string] $script:result.launchedBy | Should -BeExactly 'startnet' -Because (
            'the launcher runs because Update-HDTBootImage pointed startnet.cmd at it; open {0}\deploy-01-winpe.png if this fails - a bare X:\Windows\System32> prompt means startnet.cmd did not launch it' -f $script:artifactRoot)
    }

    It 'loaded powershell-yaml inside WinPE' {
        # If this is false nothing else could have happened: the engine reads
        # every YAML document through it.
        $script:result.yamlLoaded | Should -BeTrue
        [string] $script:result.yamlVersion | Should -Not -BeNullOrEmpty
    }

    It 'reports Succeeded' {
        [string] $script:result.status | Should -BeExactly 'Succeeded' -Because (
            'failed at step "{0}": {1}' -f [string] $script:result.failedStep, [string] $script:result.message)
    }

    It 'completed all five steps' {
        @($script:state.step | ForEach-Object { [string] $_.status }) | Should -Be @(
            'Completed',   # 1 Validate
            'Completed',   # 2 Format and Partition
            'Completed',   # 3 Apply OS
            'Completed',   # 4 Apply Unattend
            'Completed')   # 5 Prepare Boot
    }

    It 'wrote no step.fail record' {
        @($script:record | Where-Object { $_.event -eq 'step.fail' }) | Should -BeNullOrEmpty
    }

    It 'ran the steps in sequence order' {
        $started = @($script:record | Where-Object { $_.event -eq 'step.start' } |
                ForEach-Object { [string] $_.data.name })

        $started | Should -Be @('Validate', 'Format and Partition', 'Apply OS', 'Apply Unattend', 'Prepare Boot')
    }

    It 'logged the disk it chose' {
        $chosen = @($script:record | Where-Object {
                $_.component -eq 'DiskPartition' -and [string] $_.message -like '*repartition*'
            })

        $chosen.Count | Should -BeGreaterThan 0
        [string] $chosen[0].message | Should -BeLike '*disk 0*'
    }

    It 'never named the content disk as a target' {
        # Disk 1 carries the workspace. DEMO-M3's minDiskGB excludes it by size
        # AND DiskPartition protects it by drive letter - two independent rules.
        $partitionRecord = @($script:record | Where-Object { $_.component -eq 'DiskPartition' -and $null -ne $_.data })

        foreach ($entry in $partitionRecord) {
            if ($null -ne $entry.data.PSObject.Properties['diskNumber']) {
                [int] $entry.data.diskNumber | Should -Be 0
            }
        }
    }

    It 'applied index 1' {
        $applied = @($script:record | Where-Object { $_.component -eq 'ApplyImage' -and $null -ne $_.data } |
                Where-Object { $null -ne $_.data.PSObject.Properties['index'] })

        $applied.Count | Should -BeGreaterThan 0
        [int] $applied[0].data.index | Should -Be 1
    }

    It 'wrote UTF-8 without a BOM' {
        # SPIKES S6's THIRD FINDING, asserted: Tee-Object defaults to UTF-16
        # under 5.1, producing logs half the tooling cannot read.
        @($script:logFirstByte).Count | Should -BeGreaterThan 2

        $bom = @($script:logFirstByte | Select-Object -First 3)
        ($bom -join ',') | Should -Not -BeExactly '239,187,191' -Because 'a UTF-8 BOM'
        ($bom[0], $bom[1] -join ',') | Should -Not -BeExactly '255,254' -Because 'UTF-16 LE'
        ($bom[0], $bom[1] -join ',') | Should -Not -BeExactly '254,255' -Because 'UTF-16 BE'

        # And the second byte of a UTF-16 stream is a NUL, which UTF-8 never has
        # in ASCII text.
        $script:logFirstByte[1] | Should -Not -Be 0
    }

    It 'kept the deployment password out of the log' {
        # Read out of the STAGED UNATTEND, not off the state document: the
        # teardown nulls state.deploymentPassword at the end of a successful
        # run, so reading it there would compare against an empty string.
        $password = [string] ([regex]::Match(
                [string] $script:targetFile['unattendText'],
                '<AdministratorPassword>\s*<Value>([^<]+)</Value>').Groups[1].Value)

        $password | Should -Not -BeNullOrEmpty
        $script:rawJsonl | Should -Not -BeLike ('*{0}*' -f $password)
        $script:launcherLog | Should -Not -BeLike ('*{0}*' -f $password)
    }

    It 'recorded the apply duration' {
        $applied = @($script:record | Where-Object { $_.component -eq 'ApplyImage' })

        $applied.Count | Should -BeGreaterThan 0
        [int] $script:result.elapsedSecond | Should -BeGreaterThan 0

        Write-Information ("the whole WinPE leg took {0}s inside the VM" -f $script:result.elapsedSecond) -InformationAction Continue
    }

    It 'captured the target disk as a Generation 2 VM presents it' {
        # tests/fixtures/disk/gen2-vm-raw-disk.json was DERIVED from SPIKES S6's
        # notes because there was no HDT test VM to capture from. This is the
        # capture, and this is the assertion that the derivation was honest.
        $disk0 = @($script:result.diskBefore | Where-Object { $_.Number -eq 0 })

        $disk0.Count | Should -Be 1
        $disk0[0].BusType | Should -BeExactly 'SAS' -Because 'not SCSI and not Virtual - do not filter on a guessed bus type'
        $disk0[0].PartitionStyle | Should -BeExactly 'RAW'
        [long] $disk0[0].SizeBytes | Should -Be 68719476736
        $disk0[0].IsBoot | Should -BeFalse
        $disk0[0].IsSystem | Should -BeFalse

        # Assigned first, wrapped second (helpers README F12).
        $capturedFixture = ConvertFrom-Json ([System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/disk/gen2-vm-raw-disk.json')))
        $fixture = @($capturedFixture)[0]

        $disk0[0].BusType | Should -BeExactly ([string] $fixture.BusType)
        $disk0[0].PartitionStyle | Should -BeExactly ([string] $fixture.PartitionStyle)
        [long] $disk0[0].SizeBytes | Should -Be ([long] $fixture.SizeBytes)
        [string] $disk0[0].FriendlyName | Should -BeExactly ([string] $fixture.FriendlyName)
    }

    It 'agreed with the harness about where the workspace is' {
        # The harness staged Share\TaskSequences\DEMO-M3\ by hand; the engine
        # found it through Get-HDTWorkspacePath. If the two disagreed the run
        # could not have imported a sequence at all.
        [string] $script:result.sequenceId | Should -BeExactly 'DEMO-M3'
    }
}

Describe 'the machine it built' -Tag 'E2E' -Skip:$skipDeployment {

    It 'has three partitions' {
        # THREE, NOT FOUR - AND THAT IS A FINDING (04-04, SPIKES S9.10).
        #
        # On the HOST, Initialize-Disk -PartitionStyle GPT creates a Microsoft
        # Reserved partition of its own; the integration suite observes it, at
        # 16759808 bytes and offset 17408. INSIDE WinPE IT DOES NOT. The
        # deployed disk carries ESP, Windows and Recovery and nothing else.
        #
        # SPIKES S6's own hand-run log said so all along and nobody noticed:
        #
        #     00:09:26  Partitions:  #1 S 260MB   #2 W 64250MB   #3 1024MB
        #
        # It changes nothing about correctness. HDT never creates an MSR, the
        # 16 MB ReservedSizeByte allowance is subtracted whether or not one
        # appears, and the recovery partition carries UseMaximumSize so the
        # unused allowance lands there rather than being left unallocated.
        @($script:targetPartition).Count | Should -Be 3
    }

    It 'has no duplicate reserved partition' {
        # SPIKES S6's trap, on a real deployment. PSD's PSDPartition.ps1
        # initialises GPT and then creates an MSR by hand; HDT's layouts declare
        # no Reserved role at all, and the one door that could let one back in -
        # a -Definition override - refuses the role by name.
        @($script:targetPartition | Where-Object { $_.GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' }).Count |
            Should -BeLessOrEqual 1
    }

    It 'has the three roles the layout declares, and only those' {
        $type = @($script:targetPartition | Sort-Object PartitionNumber | ForEach-Object { [string] $_.GptType })

        $type | Should -Be @(
            '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System
            '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'   # Basic data - Windows
            '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')  # Windows Recovery
    }

    It 'has a 260MB FAT32 system partition' {
        $esp = @($script:targetPartition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' })

        $esp.Count | Should -Be 1
        $esp[0].Size | Should -Be 272629760
    }

    It 'has a recovery partition with the recovery type' {
        @($script:targetPartition | Where-Object { $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' }).Count |
            Should -Be 1
    }

    It 'has ntoskrnl.exe on the Windows volume' {
        $script:targetFile['Windows\System32\ntoskrnl.exe'] | Should -BeTrue
    }

    It 'has bootmgfw.efi on the system partition' {
        # Read by giving the ESP a temporary drive letter: Windows does not
        # letter an EFI System partition, so a read-only mount cannot see inside
        # it at all. The first run of this file reported the file missing on a
        # machine that had demonstrably booted from it.
        $script:targetFile['EFI\Microsoft\Boot\bootmgfw.efi'] | Should -BeTrue
    }

    It 'has a BCD store beside it' {
        $script:targetFile['EFI\Microsoft\Boot\BCD'] | Should -BeTrue
    }

    It 'has the unattend staged at Windows\Panther\unattend.xml' {
        # SPIKES S7's verified location.
        $script:targetFile['Windows\Panther\unattend.xml'] | Should -BeTrue
    }

    It 'expanded the computer name into the staged unattend' {
        # HDT-M3-01 comes from the PER-MACHINE OVERRIDE this run staged, not
        # from DEMO-M3's own variables block. rules.yaml's fallback sets
        # HDTComputerName from the serial number and rules outrank a sequence's
        # defaults, so on this VM the sequence's name loses - and the resulting
        # 35-character name is one Windows Setup silently discards. The override
        # is DESIGN 3.1's answer, and the first run of this file is what made
        # anyone look.
        [string] $script:targetFile['unattendText'] | Should -BeLike '*<ComputerName>HDT-M3-01</ComputerName>*'
    }

    It 'resolved that name through the machine override' {
        # DESIGN 3.1 source 2, exercised end to end for the first time. The
        # launcher logs which override file it found, keyed on the UUID the
        # guest reported - so this asserts that the file was located by UUID
        # rather than that a name happened to come out right.
        $script:launcherLog | Should -BeLike ('*{0}.yaml*' -f $script:vmUuid)
    }
}

Describe 'it boots into Windows' -Tag 'E2E' -Skip:$skipDeployment {

    It 'boots into Windows with the installation media still attached' {
        # THE EXIT CRITERION. The VM was started again with the ISO still in the
        # DVD drive and the boot order untouched. SPIKES S6's fourth finding,
        # inverted: a machine that boots WinPE again fails here, and that means
        # ConfigureBoot's firmware reorder did not do its job.
        $script:bootedWindows | Should -BeTrue -Because (
            'no settled integration-services heartbeat after {0}s; look at C:\HDTLab\scratch\e2e\deploy-04-windows.png - a WinPE prompt there means SetBootOrderFirst did not take' -f $script:heartbeatSecond)
    }

    It 'reports an Ok heartbeat, which WinPE never does' {
        $script:heartbeatSecond | Should -BeGreaterThan 0
    }

    It 'saved a screenshot of the running machine' {
        Test-Path -LiteralPath (Join-Path -Path $script:artifactRoot -ChildPath 'deploy-04-windows.png') |
            Should -BeTrue
    }

    It 'applied the computer name from the unattend' {
        # SPIKES S7's specialize behaviour, now driven by the engine. Read
        # offline from the deployed SYSTEM hive after a graceful stop, so
        # specialize's writes are certainly committed.
        $script:offlineComputerName | Should -BeExactly 'HDT-M3-01' -Because (
            'the VM was stopped {0}' -f $(if ($script:stoppedGracefully) { 'gracefully' } else { 'with -TurnOff after a timeout, which is itself a finding' }))
    }
}

Describe 'the lab is unharmed' -Tag 'E2E' {

    It 'left CM01 in the state it found it' {
        $after = & $script:snapshotProtected

        $before = @($script:protectedBefore | Where-Object { $_.Name -eq 'CM01' })
        $now = @($after | Where-Object { $_.Name -eq 'CM01' })

        ($now | ConvertTo-Json -Depth 3) | Should -BeExactly ($before | ConvertTo-Json -Depth 3)
    }

    It 'left DC01 in the state it found it' {
        $after = & $script:snapshotProtected

        $before = @($script:protectedBefore | Where-Object { $_.Name -eq 'DC01' })
        $now = @($after | Where-Object { $_.Name -eq 'DC01' })

        ($now | ConvertTo-Json -Depth 3) | Should -BeExactly ($before | ConvertTo-Json -Depth 3)
    }

    It 'left every HDT VM powered off' {
        $running = @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue |
                Where-Object { $_.State -ne 'Off' } | ForEach-Object { [string] $_.Name })

        $running | Should -BeNullOrEmpty -Because ($running -join ', ')
    }

    It 'touched no VM outside HDT-*' {
        # Asserted from the guard rather than from a transcript: every VM this
        # file creates or removes goes through New-/Remove-HDTLabVirtualMachine,
        # and Assert-HDTLabVmName refuses anything not named HDT-*, plus CM01
        # and DC01 by name. tests/unit/New-HDTLabVirtualMachine.Tests.ps1 proves
        # those refusals, and that the guard runs before the first Hyper-V call.
        { Assert-HDTLabVmName -Name 'CM01' } | Should -Throw
        { Assert-HDTLabVmName -Name 'DC01' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDT-*' } | Should -Throw
    }
}
