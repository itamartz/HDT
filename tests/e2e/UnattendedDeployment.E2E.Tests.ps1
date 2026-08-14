# ROADMAP M4's EXIT CRITERION, AS AN EXECUTABLE TEST.
#
#   "a VM boots the ISO produced by Update-HDTBootImage / New-HDTBootIso and
#    deploys to Windows 11 WITH ZERO KEYSTROKES"
#
# This file builds a boot image with Update-HDTBootImage, creates a Generation 2
# VM on the isolated 'HDT Lab' switch, boots it from the ISO that build produced,
# and THEN DOES NOTHING. It sends the machine no input at all. Inside the image,
# startnet.cmd runs wpeinit and then X:\HDT\Start-HDTDeployment.ps1, which
# resolves its own deploy root, runs DEMO-M4 against the real disk and image
# services, and powers the machine off.
#
# WHAT MAKES THE ZERO-KEYSTROKE CLAIM HONEST - THREE PROOFS, BECAUSE ONE WOULD
# NOT BE ENOUGH:
#
#   1. THIS FILE SENDS NOTHING, and that is checked in the FAST suite.
#      tests/unit/UnattendedDeploymentE2E.Tests.ps1 parses this file and asserts
#      that it names neither the lab keyboard helper nor either of the two
#      Msvm keyboard methods SPIKES S4 records - four assertions with four
#      messages, and that file names all four in full. A claim a suite makes
#      about itself must be checkable without running it, or it is only true on
#      the days somebody remembered to look.
#
#      THE FOUR NAMES ARE DELIBERATELY NOT WRITTEN OUT HERE. 05-05's verification
#      asks a human to run a plain Select-String over this file for them and
#      expect nothing back, so a sentence that spelled them would make the
#      simplest check anyone can perform report a hit - and the next author would
#      resolve that by deleting the sentence rather than by keeping the property.
#   2. THE GUEST SAYS WHO STARTED IT. startnet.cmd sets HDT_LAUNCHED_BY=startnet
#      (05-04) and Start-HDTDeployment.ps1 records it in RESULT.json (05-03). A
#      hand-typed launch leaves that field empty.
#   3. A RUN THAT DID NOT START ITSELF CANNOT LOOK LIKE SUCCESS. Nothing types,
#      so a startnet.cmd that failed to launch the payload leaves the VM at a
#      WinPE prompt and Wait-HDTLabVmState -State Off times out. That is the same
#      discriminator SPIKES S3 used to prove the no-prompt ISO: give the machine
#      nothing else that could produce the observed outcome.
#
# THE deployRoot IS VOLUME-RELATIVE, AND IT IS THE SINGLE LIKELIEST WAY THIS RUN
# FAILS. SPIKES S9.1 recorded WinPE giving the CONTENT disk C: and the RAM disk
# X:. This phase's payload does not scan for a letter and may not: it enumerates
# volumes and Resolve-HDTDeployRoot picks the one carrying rules.yaml. A boot
# image built with a LETTERED deployRoot would boot, find nothing, and shut the
# machine down - which from outside is indistinguishable from success, because
# the discriminator for this whole plan is "the VM powered itself off". So the
# resolution is asserted explicitly: deployRootSource must be 'Discovered'.
#
# NO VM IN THIS PHASE DEPLOYS OVER SMB. PROJECT.md rule 2 keeps test VMs on the
# isolated 'HDT Lab' switch and SPIKES S6 records that a VM there cannot reach a
# share on the host, so the image declares provider Local. The Smb provider's
# evidence is 05-02's unit refusals and its loopback integration run. DO NOT move
# a test VM to one of the host's other three switches to close that gap - it
# would put the machine on a segment where CM01's PXE responder can answer it.
# tests/e2e/README.md names them; this file may not, for the reason above.
#
# LAB SAFETY. Every Hyper-V call is module-qualified (SPIKES S9.9: PowerCLI
# shadows Get-VM on this host) and name-filtered. CM01 and DC01 are recorded
# before anything starts and asserted identical afterwards, in an AfterAll that
# runs even when the test failed. Nothing here creates or removes a VM except
# through New-/Remove-HDTLabVirtualMachine, whose guards are unit tested and
# whose delete is fronted by Assert-HDTLabVmPath (SPIKES S9.13).
#
# EVERY SKIP CONDITION IS RECOMPUTED INSIDE BeforeAll (SPIKES S9.15).

BeforeDiscovery {
    $script:discoveryWim = Test-Path -LiteralPath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' -PathType Leaf

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
        Write-Warning ("UnattendedDeployment.E2E.Tests.ps1 is SKIPPED. It builds its own boot image and deploys Windows 11 to a VM, which needs the staged media (currently present: {0}) and the Windows ADK with the Windows PE add-on (currently resolvable: {1})." -f
            $script:discoveryWim, $script:discoveryAdk)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:vmName = 'HDT-M4-Deploy'
    $script:vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M4-Deploy-osdisk.vhdx'
    $script:contentPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M4-Deploy-content.vhdx'
    $script:wimPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e-m4'

    $script:buildRoot = 'C:\HDTLab\scratch\e2e-bootimage'
    $script:buildWorkspace = Join-Path -Path $script:buildRoot -ChildPath 'Share'
    $script:buildScratch = Join-Path -Path $script:buildRoot -ChildPath 'work'
    $script:manifestPath = Join-Path -Path $script:buildWorkspace -ChildPath 'Boot\HDTPE_x64.manifest.json'

    # THE PROTECTED PAIR, RECORDED BEFORE ANYTHING STARTS.
    #
    # MemoryStartup, NOT MemoryStartupBytes. SPIKES S9.14: the property is called
    # MemoryStartupBytes on New-VM's PARAMETER and MemoryStartup on the object
    # Get-VM returns. Without StrictMode a missing property is $null, [long]
    # $null is 0, and the assertion that protects the user's live lab compared 0
    # with 0 through six green runs.
    $script:snapshotProtected = {
        return @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
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

    $script:build = $null
    $script:manifest = $null
    $script:result = $null
    $script:record = @()
    $script:rawJsonl = ''
    $script:relocatedJsonl = ''
    $script:relocatedRecord = @()
    $script:logFirstByte = @()
    $script:state = $null
    $script:launcherLog = ''
    $script:endedCleanly = $false
    $script:deploymentSecond = 0
    $script:buildSecond = 0
    $script:bootedWindows = $false
    $script:heartbeatSecond = 0
    $script:offlineComputerName = ''
    $script:stoppedGracefully = $false
    $script:targetPartition = @()
    $script:targetFile = @{}
    $script:isoSha256 = ''
    $script:vmUuid = ''

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery (SPIKES S9.15). Pester's
    # discovery and run phases do not share a scope: reading the discovery
    # variable here throws under ./build.ps1's StrictMode, and without StrictMode
    # it evaluated to $null - and 'if (-not $null)' is TRUE, so the whole
    # deployment ran on a machine that was supposed to skip it.
    $script:hasAdk = $false
    try {
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:hasAdk = $true
    } catch {
        $script:hasAdk = $false
    }

    $script:canDeploy = (Test-Path -LiteralPath $script:wimPath -PathType Leaf) -and $script:hasAdk

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

        # -- THE BOOT IMAGE, BUILT BY THE CODE UNDER TEST -------------------
        #
        # THE WORKSPACE THIS BUILDS FROM IS NOT THE WORKSPACE THE MACHINE
        # DEPLOYS FROM. This one supplies workspace.yaml, which decides what goes
        # into the image; the content disk below supplies rules.yaml, the
        # sequence and the OS, which is what the booted machine reads.
        #
        # ITS deployRoot IS '\Share' - VOLUME-RELATIVE, NO DRIVE LETTER. See the
        # header: a letter here is the one edit that makes this whole
        # demonstration fail in the way that looks most like success.

        foreach ($folder in @($script:buildWorkspace,
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Control'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Boot'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Logs'),
                $script:artifactRoot)) {

            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
            }
        }

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'workspace.yaml'), @"
# Written by tests/e2e/UnattendedDeployment.E2E.Tests.ps1.
#
# deployRoot is VOLUME-RELATIVE and carries no drive letter, because WinPE
# chooses the content disk's letter and SPIKES S9.1 recorded it choosing C:
# while the RAM disk was X:. Update-HDTBootImage writes this string into
# bootstrap.json verbatim, and Resolve-HDTDeployRoot finds the volume carrying
# rules.yaml at boot.
schemaVersion: 1
id: HDT-LAB-M4
name: HDT M4 exit criterion workspace
deployRoot: \Share
logLevel: Debug
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
"@, $utf8NoBom)

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", $utf8NoBom)

        # REUSE ONLY WHEN THE MANIFEST STILL DESCRIBES THE FILES ON DISK, never
        # on age alone: a stale boot image is precisely what would make this run
        # green about code it did not exercise.
        $reuse = $false
        if ($env:HDT_REUSE_BOOT_IMAGE -eq '1' -and (Test-Path -LiteralPath $script:manifestPath -PathType Leaf)) {
            try {
                $candidate = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:manifestPath))

                $wimOk = (Test-Path -LiteralPath ([string] $candidate.artifacts.wim.path) -PathType Leaf) -and
                    ((Get-FileHash -LiteralPath ([string] $candidate.artifacts.wim.path) -Algorithm SHA256).Hash -eq [string] $candidate.artifacts.wim.sha256)
                $isoOk = (Test-Path -LiteralPath ([string] $candidate.artifacts.iso.path) -PathType Leaf) -and
                    ((Get-FileHash -LiteralPath ([string] $candidate.artifacts.iso.path) -Algorithm SHA256).Hash -eq [string] $candidate.artifacts.iso.sha256)

                $reuse = $wimOk -and $isoOk
            } catch {
                $reuse = $false
            }
        }

        if ($reuse) {
            $script:manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:manifestPath))
            $script:build = [pscustomobject] @{
                WimPath   = [string] $script:manifest.artifacts.wim.path
                WimSha256 = [string] $script:manifest.artifacts.wim.sha256
                IsoPath   = [string] $script:manifest.artifacts.iso.path
                IsoSha256 = [string] $script:manifest.artifacts.iso.sha256
            }

            Write-Information "HDT_REUSE_BOOT_IMAGE=1 and the manifest hashes still match the artifacts on disk; reusing the existing build." -InformationAction Continue
        } else {
            $buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            $script:build = Update-HDTBootImage -WorkspaceRoot $script:buildWorkspace `
                -ScratchPath $script:buildScratch -Confirm:$false

            $buildStopwatch.Stop()
            $script:buildSecond = [int] $buildStopwatch.Elapsed.TotalSeconds

            $script:manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:manifestPath))

            Write-Information ("boot image built in {0}s: {1} ({2} bytes)" -f
                $script:buildSecond, $script:build.IsoPath, $script:build.IsoSizeBytes) -InformationAction Continue
        }

        $script:isoSha256 = (Get-FileHash -LiteralPath ([string] $script:build.IsoPath) -Algorithm SHA256).Hash

        # -- the VM, BEFORE the content disk --------------------------------
        #
        # THE ORDER MATTERS, and the reason is DESIGN 3.1's second variable
        # source. The per-machine override is keyed on the machine's UUID, so the
        # VM has to exist before the content disk that carries the override can
        # be written (04-04's finding 2, SPIKES S9.11).

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        if (Test-Path -LiteralPath $script:osDiskPath) {
            Remove-Item -LiteralPath $script:osDiskPath -Force
        }

        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 68719476736 -Dynamic | Out-Null

        # Disk 0 is the target. The content disk is attached after it is built,
        # so the target is certainly disk 0 - and DEMO-M4's minDiskGB: 60
        # excludes the 8 GB content disk by size, while DiskPartition ALSO
        # protects it by drive letter.
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT Lab' -VhdPath @($script:osDiskPath) `
            -IsoPath ([string] $script:build.IsoPath) -Confirm:$false | Out-Null

        # The UUID the guest will report as HDTUUID. Hyper-V holds it as the
        # firmware BIOS GUID, in braces.
        $vmSetting = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemSettingData' |
                Where-Object { $_.ConfigurationID -eq [string] (Hyper-V\Get-VM -Name $script:vmName).Id })

        if ($vmSetting.Count -ge 1 -and $null -ne $vmSetting[0].BIOSGUID) {
            $script:vmUuid = ([string] $vmSetting[0].BIOSGUID).Trim('{', '}').ToUpperInvariant()
        }

        if ([string]::IsNullOrWhiteSpace($script:vmUuid)) {
            # Not a Should: this is a BeforeAll, and a failed assertion here
            # would report as a mystery in every test below it.
            throw "could not read the BIOS GUID of '$script:vmName'; the per-machine override is keyed on it."
        }

        Write-Information ("VM UUID: {0}" -f $script:vmUuid) -InformationAction Continue

        # THE PER-MACHINE OVERRIDE - DESIGN 3.1's SECOND SOURCE, and it carries
        # TWO variables here rather than one.
        #
        # HDTComputerName, because rules.yaml's fallback would name this machine
        # PC-<32 character VM serial>, which is over the 15 character NetBIOS
        # limit and which Windows Setup silently discards (SPIKES S9.11).
        #
        # HDTTaskSequenceID, because NOTHING ELSE NAMES THE SEQUENCE. The M3 run
        # was told which sequence to run on the command line somebody typed; this
        # one is told nothing at all, so the answer has to be somewhere the
        # machine can read. bootstrap.json's sequenceId is empty, so the payload
        # falls through to the resolved variables - and the override is the
        # mechanism HDT already has for making one machine an exception.
        $overrideStaging = Join-Path -Path $script:artifactRoot -ChildPath 'machines'
        if (-not (Test-Path -LiteralPath $overrideStaging -PathType Container)) {
            New-Item -Path $overrideStaging -ItemType Directory -Force | Out-Null
        }

        $script:overrideFile = Join-Path -Path $overrideStaging -ChildPath ('{0}.yaml' -f $script:vmUuid)

        [System.IO.File]::WriteAllText($script:overrideFile, @"
# Written by tests/e2e/UnattendedDeployment.E2E.Tests.ps1 for this run's VM.
#
# DESIGN 3.1 source 2, keyed on the machine's UUID. It beats every rule below it.
#
# HDTComputerName: rules.yaml's fallback sets PC-%HDTSerialNumber%, and a
# Hyper-V serial is 32 characters - a 35 character name Windows Setup silently
# discards (SPIKES S9.11).
#
# HDTTaskSequenceID: nothing types a sequence id at this machine, so it has to
# be readable from the content. This is where it lives.
schemaVersion: 1
variables:
  HDTComputerName: HDT-M4-01
  HDTTaskSequenceID: DEMO-M4
"@, $utf8NoBom)

        # -- the content disk: THE WORKSPACE AND NOTHING ELSE ---------------
        #
        # NO ENGINE AND NO powershell-yaml. Both live inside the boot image now,
        # staged by Update-HDTBootImage at X:\HDT\Modules\ - which is the whole
        # point of this milestone. The M3 content disk carried them because there
        # was no HDT-built boot image to put them in.

        Write-Information "staging content: the workspace, the override and a 4 GB install.wim - no engine, it is in the image" -InformationAction Continue

        $contentStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        New-HDTLabContentDisk -Path $script:contentPath -SizeByte 8589934592 -Confirm:$false -Source @{
            ('Share\Control\machines\{0}.yaml' -f $script:vmUuid)         = $script:overrideFile
            'Share\rules.yaml'                                           = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/rules.yaml')
            'Share\Scripts'                                              = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/Scripts')
            # THE SAMPLE FILES, COPIED, NOT RETYPED, so the sample and the lab
            # run cannot drift apart.
            'Share\TaskSequences\DEMO-M4'                                = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences/DEMO-M4')
            'Share\OperatingSystems\Win11-LTSC-2024\os.yaml'             = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/OperatingSystems/Win11-LTSC-2024/os.yaml')
            'Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = $script:wimPath
        } | Out-Null

        $contentStopwatch.Stop()
        Write-Information ("content disk staged in {0}s" -f [int] $contentStopwatch.Elapsed.TotalSeconds) -InformationAction Continue

        # Attached second, so the target is certainly disk 0.
        Hyper-V\Add-VMHardDiskDrive -VMName $script:vmName -Path $script:contentPath

        # -- START IT, AND THEN SEND IT NOTHING -----------------------------

        $deployStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        # SPIKES S1 measured boot to a WinPE prompt at well under 100 s, and
        # SPIKES S9.12's five-step run took 273 s wall. At 150 s the engine
        # should be part way through the apply - which is what m4-01-winpe.png
        # has to show. A BARE X:\Windows\System32> PROMPT THERE IS THE FAILURE
        # THIS WHOLE PHASE EXISTS TO ELIMINATE.
        #
        # This is diagnosis, never assertion (SPIKES S4): no test reads a pixel.
        Start-Sleep -Seconds 150
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm4-01-winpe.png') | Out-Null

        Start-Sleep -Seconds 90
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm4-02-running.png') | Out-Null

        # THE DISCRIMINATOR. The payload powers the machine off when the sequence
        # ends, whatever the outcome; nothing types, so a startnet.cmd that did
        # not launch it leaves a WinPE prompt and this times out.
        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 45

        $deployStopwatch.Stop()
        $script:deploymentSecond = [int] $deployStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm4-03-ended.png') | Out-Null
        Write-Information ("the WinPE leg ended after {0}s (clean shutdown: {1})" -f $script:deploymentSecond, $script:endedCleanly) -InformationAction Continue

        # -- read the evidence off the content disk -------------------------
        #
        # FROM Share\Logs, WHERE 05-03's PAYLOAD WRITES IT - not from X:, which
        # died with the RAM disk when the machine powered off.

        $harvest = & $script:readContent {
            param([string] $Drive)

            $logRoot = '{0}\Share\Logs' -f $Drive
            $answer = @{ Result = $null; Jsonl = ''; State = $null; Launcher = ''; FirstByte = @(); RunFolder = '' }

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
                $answer['RunFolder'] = [string] $runFolder[0].Name

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
            $script:runFolderName = [string] $harvest['RunFolder']

            if (-not [string]::IsNullOrWhiteSpace($script:rawJsonl)) {
                $script:record = @(($script:rawJsonl -split "`r?`n") |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ConvertFrom-Json $_ })
            }
        }

        Write-Information ("RESULT.json status: {0}; launchedBy '{1}'; deployRoot '{2}' ({3})" -f
            $(if ($null -ne $script:result) { [string] $script:result.status } else { '<absent>' }),
            $(if ($null -ne $script:result) { [string] $script:result.launchedBy } else { '' }),
            $(if ($null -ne $script:result) { [string] $script:result.resolvedDeployRoot } else { '' }),
            $(if ($null -ne $script:result) { [string] $script:result.deployRootSource } else { '' })) -InformationAction Continue

        # PERSIST THE EVIDENCE. Everything above was read off a content disk the
        # AfterAll destroys, so a claim like "reported Succeeded" could otherwise
        # only be re-checked by re-running the whole deployment (04-04's lesson).
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
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'), $script:rawJsonl)
        }
        if (-not [string]::IsNullOrWhiteSpace($script:launcherLog)) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAUNCHER.log'), $script:launcherLog)
        }

        # -- read the machine it built, off the target VHDX -----------------
        #
        # MOUNTED READ-WRITE, AND ONLY FOR ONE REASON: Windows does not give an
        # EFI System partition a drive letter, so bootmgfw.efi cannot be read off
        # a read-only mount at all. The ESP is given a temporary letter, read,
        # and the letter removed again. Nothing on the disk is modified; this is
        # our own throwaway VHDX.
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
                        'Windows\Panther\unattend.xml',
                        # DELIVERABLE 7. 05-03's Set-HDTLogPath mirrors the whole
                        # log tree onto the volume DiskPartition just formatted,
                        # at the one point in the loop that sees every step
                        # finish. This file could not exist without it, and it is
                        # the difference between "the logs were written" and "the
                        # logs survived the machine".
                        'HDT\Logs\HDT.jsonl',
                        'HDT\state.json')) {

                    $path = Join-Path -Path $letter -ChildPath $relative
                    if (Test-Path -LiteralPath $path) {
                        $script:targetFile[$relative] = $true

                        if ($relative -like '*unattend.xml') {
                            $script:targetFile['unattendText'] = [System.IO.File]::ReadAllText($path)
                        }

                        if ($relative -eq 'HDT\Logs\HDT.jsonl') {
                            $script:relocatedJsonl = [System.IO.File]::ReadAllText($path)
                        }
                    }
                }
            }

            if ($espLettered) {
                Remove-PartitionAccessPath -DiskNumber $number -PartitionNumber ([int] $esp[0].PartitionNumber) `
                    -AccessPath ('{0}:\' -f $espLetter) -ErrorAction SilentlyContinue
            }

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'TARGET-PARTITION.json'),
                (ConvertTo-Json -InputObject @($script:targetPartition) -Depth 4))

            if (-not [string]::IsNullOrWhiteSpace($script:relocatedJsonl)) {
                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $script:artifactRoot -ChildPath 'HDT-relocated.jsonl'),
                    $script:relocatedJsonl)

                $script:relocatedRecord = @(($script:relocatedJsonl -split "`r?`n") |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ConvertFrom-Json $_ })
            }
        } finally {
            Dismount-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue | Out-Null
        }

        # -- start it again and change NOTHING ------------------------------
        #
        # No boot order edit, no ejected ISO. SPIKES S6's fourth finding as an
        # assertion: if ConfigureBoot did its job the firmware now prefers the
        # Windows Boot Manager, and if it did not this VM boots WinPE again and
        # reports no heartbeat.

        if ($null -ne $script:result -and [string] $script:result.status -eq 'Succeeded') {
            $bootStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            Hyper-V\Start-VM -Name $script:vmName

            # Settle across a window: ComputerName is applied in the specialize
            # pass and the heartbeat can appear while Setup is still working.
            $script:bootedWindows = Wait-HDTLabVmState -Name $script:vmName -Heartbeat `
                -TimeoutMinute 25 -SettleMinute 4

            $bootStopwatch.Stop()
            $script:heartbeatSecond = [int] $bootStopwatch.Elapsed.TotalSeconds

            Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm4-04-windows.png') | Out-Null
            Write-Information ("first Windows boot reported a settled heartbeat after {0}s: {1}" -f $script:heartbeatSecond, $script:bootedWindows) -InformationAction Continue

            # GRACEFULLY, through integration services, so specialize's writes
            # are committed before the disk is read offline.
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
            Hyper-V\Stop-VM -Name 'HDT-M4-Deploy' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M4-Deploy was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M4-Deploy' -Confirm:$false
        }
    }
}

Describe 'it started itself' -Tag 'E2E' -Skip:$skipDeployment {

    It 'ended by shutting the machine down rather than by timing out' {
        # THE DISCRIMINATOR FOR THE WHOLE PHASE. Nothing typed at this machine,
        # so a startnet.cmd that did not launch the payload leaves a WinPE prompt
        # and this is the test that fails.
        $script:endedCleanly | Should -BeTrue -Because (
            'the WinPE leg ran for {0}s. Open C:\HDTLab\scratch\e2e-m4\m4-01-winpe.png: a bare X:\Windows\System32> prompt there means startnet.cmd did not launch Start-HDTDeployment.ps1' -f $script:deploymentSecond)
    }

    It 'wrote a RESULT.json' {
        $script:result | Should -Not -BeNullOrEmpty -Because $script:launcherLog
    }

    It 'reports launchedBy startnet' {
        # THE GUEST'S OWN STATEMENT ABOUT WHO STARTED IT. startnet.cmd inside the
        # image runs 'set HDT_LAUNCHED_BY=startnet' before it launches anything,
        # and Start-HDTDeployment.ps1 copies that environment variable into
        # RESULT.json. A human typing the command at the prompt does not set it.
        [string] $script:result.launchedBy | Should -BeExactly 'startnet' -Because (
            'HDT_LAUNCHED_BY is set by the image''s own startnet.cmd and by nothing else')
    }

    It 'booted the ISO Update-HDTBootImage produced' {
        # By hash against the manifest, not by filename: a stale file at the same
        # path would otherwise pass.
        $script:isoSha256 | Should -BeExactly ([string] $script:manifest.artifacts.iso.sha256)
    }

    It 'booted an image whose boot.wim matches the standalone WIM' {
        # DESIGN 6.1.1, re-asserted here so the thing that actually booted is the
        # thing the equivalence test was about (SPIKES S11.2).
        [string] $script:manifest.artifacts.isoBootWimSha256 |
            Should -BeExactly ([string] $script:manifest.artifacts.wim.sha256)
    }

    It 'loaded powershell-yaml from inside the boot image' {
        # X:, not the content disk. The engine and the parser live in the image
        # now, which is what removed the M3 content disk's HDT\Modules folder.
        $script:result.yamlLoaded | Should -BeTrue
        [string] $script:result.yamlVersion | Should -Not -BeNullOrEmpty
        [string] $script:result.yamlBase | Should -BeLike 'X:\*'
    }

    It 'loaded the engine from inside the boot image' {
        [string] $script:result.engineVersion | Should -Not -BeNullOrEmpty
    }

    It 'connected through the Local provider' {
        [string] $script:result.provider | Should -BeExactly 'Local'
        $script:result.connected | Should -BeTrue
    }

    It 'discovered the content volume rather than being told it' {
        # SPIKES S9.1 IS THE REASON THIS ASSERTION EXISTS. The image carries the
        # volume-relative '\Share'; the payload enumerates volumes and
        # Resolve-HDTDeployRoot picks the one carrying rules.yaml. A lettered
        # deployRoot baked into the image would fail HERE instead of failing
        # silently by booting, finding nothing and powering the machine off.
        [string] $script:result.deployRoot | Should -BeExactly '\Share'
        [string] $script:result.deployRootSource | Should -BeExactly 'Discovered'
        [string] $script:result.resolvedDeployRoot | Should -Match '^[A-Za-z]:'

        @($script:result.candidateRoot).Count | Should -BeGreaterThan 0 -Because (
            'the volumes it searched are the whole investigation when this goes wrong on a machine nobody is watching')

        Write-Information ("WinPE assigned the content disk {0}; it searched {1}" -f
            [string] $script:result.resolvedDeployRoot, ((@($script:result.candidateRoot) -join ', '))) -InformationAction Continue
    }

    It 'recorded how it ended' {
        # EVIDENCE ABOUT THE PAYLOAD'S OWN ENDING, and only that: the payload
        # calls wpeutil directly, after the catch, because it must end the
        # machine even on a run where the module never imported.
        #
        # ROADMAP M2's question - wpeutil or shutdown.exe - is no longer open;
        # 05-06 answered it (shutdown.exe is not in the image) and
        # tests/e2e/WinPeSmoke.E2E.Tests.ps1 is where New-HDTPowerService is
        # EXECUTED. This line is still not that: DEMO-M4 has no Restart step, so
        # nothing here goes through IPowerService.
        [string] $script:result.endedWith | Should -BeExactly 'wpeutil shutdown'
    }
}

Describe 'the engine ran the deployment' -Tag 'E2E' -Skip:$skipDeployment {

    It 'reports Succeeded' {
        [string] $script:result.status | Should -BeExactly 'Succeeded' -Because (
            'failed at step "{0}": {1}' -f [string] $script:result.failedStep, [string] $script:result.message)
    }

    It 'ran DEMO-M4' {
        [string] $script:result.sequenceId | Should -BeExactly 'DEMO-M4'
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

    It 'applied index 1' {
        $applied = @($script:record | Where-Object { $_.component -eq 'ApplyImage' -and $null -ne $_.data } |
                Where-Object { $null -ne $_.data.PSObject.Properties['index'] })

        $applied.Count | Should -BeGreaterThan 0
        [int] $applied[0].data.index | Should -Be 1
    }

    It 'never named the content disk as a target' {
        # Disk 1 carries the workspace. DEMO-M4's minDiskGB excludes it by size
        # AND DiskPartition protects it by drive letter - two independent rules.
        $partitionRecord = @($script:record | Where-Object { $_.component -eq 'DiskPartition' -and $null -ne $_.data })

        foreach ($entry in $partitionRecord) {
            if ($null -ne $entry.data.PSObject.Properties['diskNumber']) {
                [int] $entry.data.diskNumber | Should -Be 0
            }
        }
    }

    It 'kept the deployment password out of the log' {
        # Read out of the STAGED UNATTEND, not off the state document: the
        # teardown nulls state.deploymentPassword at the end of a successful run.
        $password = [string] ([regex]::Match(
                [string] $script:targetFile['unattendText'],
                '<AdministratorPassword>\s*<Value>([^<]+)</Value>').Groups[1].Value)

        $password | Should -Not -BeNullOrEmpty
        $script:rawJsonl | Should -Not -BeLike ('*{0}*' -f $password)
        $script:launcherLog | Should -Not -BeLike ('*{0}*' -f $password)
        $script:relocatedJsonl | Should -Not -BeLike ('*{0}*' -f $password)
    }

    It 'wrote UTF-8 without a BOM' {
        # SPIKES S6's THIRD FINDING, asserted: Tee-Object defaults to UTF-16
        # under 5.1, producing logs half the tooling cannot read.
        @($script:logFirstByte).Count | Should -BeGreaterThan 2

        $bom = @($script:logFirstByte | Select-Object -First 3)
        ($bom -join ',') | Should -Not -BeExactly '239,187,191' -Because 'a UTF-8 BOM'
        ($bom[0], $bom[1] -join ',') | Should -Not -BeExactly '255,254' -Because 'UTF-16 LE'
        ($bom[0], $bom[1] -join ',') | Should -Not -BeExactly '254,255' -Because 'UTF-16 BE'

        $script:logFirstByte[1] | Should -Not -Be 0
    }

    It 'resolved the computer name through the machine override' {
        # DESIGN 3.1 source 2. The launcher logs which override file it found,
        # keyed on the UUID the guest reported - so this asserts the file was
        # located BY UUID rather than that a name happened to come out right.
        $script:launcherLog | Should -BeLike ('*{0}.yaml*' -f $script:vmUuid)
        [string] $script:result.computerName | Should -BeExactly 'HDT-M4-01'
    }
}

Describe 'the log survived the machine' -Tag 'E2E' -Skip:$skipDeployment {

    It 'relocated the WinPE log to the target volume' {
        # DELIVERABLE 7. Without 05-03's Set-HDTLogPath this file cannot exist:
        # the log started on X:, the RAM disk, which died with the power-off.
        $script:targetFile['HDT\Logs\HDT.jsonl'] | Should -BeTrue -Because (
            'the log started on the RAM disk and the relocation is what moves it somewhere that survives the reboot')
    }

    It 'carries the run.start record in the relocated log' {
        # THE HISTORY MOVED, NOT JUST THE FILE. A relocation that opened a fresh
        # log on the target would satisfy the test above and lose everything the
        # run had already recorded.
        @($script:relocatedRecord | Where-Object { $_.event -eq 'run.start' }).Count |
            Should -BeGreaterThan 0
    }

    It 'has a continuous seq across the relocation' {
        # Read from the relocated log, which is the complete one: the mirror the
        # copy-back shipped and the file on the target volume are the same
        # history, so seq must have no repeat and no gap.
        $seq = @($script:relocatedRecord | ForEach-Object { [int] $_.seq })

        $seq.Count | Should -BeGreaterThan 20 -Because 'a five-step deployment writes more records than that'
        @($seq | Sort-Object -Unique).Count | Should -Be $seq.Count -Because 'no seq is repeated'
        ($seq[-1] - $seq[0]) | Should -Be ($seq.Count - 1) -Because 'no seq is skipped'
    }

    It 'mirrored the state document to the target volume' {
        # DESIGN 4.3's state mirror rides the same trigger as the relocation.
        $script:targetFile['HDT\state.json'] | Should -BeTrue
    }

    It 'copied the logs back to the deploy root' {
        $script:runFolderName | Should -BeLike 'HDT-M4-01-*'
        $script:rawJsonl | Should -Not -BeNullOrEmpty
    }
}

Describe 'the machine it built' -Tag 'E2E' -Skip:$skipDeployment {

    It 'has three partitions' {
        # THREE, NOT FOUR - SPIKES S9.10. Initialize-Disk creates a Microsoft
        # Reserved partition on the HOST and not inside WinPE.
        @($script:targetPartition).Count | Should -Be 3
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

    It 'has ntoskrnl.exe on the Windows volume' {
        $script:targetFile['Windows\System32\ntoskrnl.exe'] | Should -BeTrue
    }

    It 'has bootmgfw.efi on the system partition' {
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
        [string] $script:targetFile['unattendText'] | Should -BeLike '*<ComputerName>HDT-M4-01</ComputerName>*'
    }
}

Describe 'it boots into Windows' -Tag 'E2E' -Skip:$skipDeployment {

    It 'boots into Windows with the installation media still attached' {
        # The VM was started again with the ISO still in the DVD drive and the
        # boot order untouched. SPIKES S6's fourth finding, inverted: a machine
        # that boots WinPE again fails here, and that means ConfigureBoot's
        # firmware reorder did not do its job.
        $script:bootedWindows | Should -BeTrue -Because (
            'no settled integration-services heartbeat after {0}s; look at C:\HDTLab\scratch\e2e-m4\m4-04-windows.png' -f $script:heartbeatSecond)
    }

    It 'reports an Ok heartbeat, which WinPE never does' {
        $script:heartbeatSecond | Should -BeGreaterThan 0
    }

    It 'saved a screenshot of the running machine' {
        Test-Path -LiteralPath (Join-Path -Path $script:artifactRoot -ChildPath 'm4-04-windows.png') |
            Should -BeTrue
    }

    It 'applied the computer name from the unattend' {
        # Read offline from the deployed SYSTEM hive after a graceful stop, so
        # specialize's writes are certainly committed.
        $script:offlineComputerName | Should -BeExactly 'HDT-M4-01' -Because (
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
        # and Assert-HDTLabVmName refuses anything not named HDT-*, plus CM01 and
        # DC01 by name.
        { Assert-HDTLabVmName -Name 'CM01' } | Should -Throw
        { Assert-HDTLabVmName -Name 'DC01' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDT-*' } | Should -Throw
    }
}
