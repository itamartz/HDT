# ROADMAP M7'S CAPTURE STEP, PROVED AGAINST REAL DISM ON REAL HARDWARE.
#
# WHAT THIS FILE PROVES, AND WHAT IT DELIBERATELY DOES NOT.
#
# It proves Invoke-HDTCaptureImageStep end to end: a machine is deployed, THIS
# RUN'S OWN RUN ID IS STAMPED ONTO THE VOLUME, and the volume is captured into a
# WIM on the deployment share - which is then mounted read-only and the run id
# read back out of it. That last step is the whole point. A capture that merely
# produces a valid WIM proves dism ran; it says nothing about WHICH volume was
# read, and dism reports a capture of the wrong directory as success, exit code
# zero, every time.
#
# IT DOES NOT PROVE THE FULL REFERENCE BUILD, because HDT cannot run one yet.
# DESIGN 9.3's loop is
#
#   WinPE   deploy                          -> restart
#   FullOS  customize, sysprep /generalize   -> restart
#   WinPE   capture
#
# and that third leg CANNOT HAPPEN. Nothing in HDT resumes a task sequence in
# WinPE: Start-HDTResume.ps1 is hardcoded to the full OS and is launched by
# autologon inside Windows, while Start-HDTDeployment.ps1 mints a NEW run at
# step 1 every time WinPE boots. A machine that rebooted after sysprep would be
# repartitioned and redeployed, destroying the very image it was meant to hand
# over. Established on real hardware on 2026-08-31; TaskSequences\REF-BUILD\ on
# the lab share is that sequence, and it stops at its restart.
#
# SO THIS SEQUENCE HAS NO REBOOT IN IT AT ALL. Deploy, stamp, capture, one WinPE
# leg, which is the largest part of the loop that HDT can currently execute -
# and it exercises every branch of the capture step: the Local-provider refusal,
# the Captures\ write probe, the resolved exclusion list, dism /Capture-Image,
# the progress meter and the published HDTCapturePath.
#
# THE ASSERTION THAT CARRIES THE MOST WEIGHT IS THAT \HDT IS ABSENT. dism does
# NOT refuse a missing /ConfigFile: - it warns and captures everything, exit code
# zero, and the image is wrong while the run is green. \HDT was certainly on the
# volume when the capture ran, because the deployment put it there. Its absence
# from the WIM is the only evidence that the exclusion list was read and applied.
#
# WHY THIS RUNS AGAINST THE REAL SHARE AND NOT A CONTENT DISK. Every other E2E
# file here builds its own workspace on a scratch VHDX. This one cannot:
# Test-HDTCaptureTarget REFUSES the Local provider outright, because under it the
# deploy root is a read-only disc and a captured image would have nowhere to go
# (DESIGN 9.3 note 6). A capture is an SMB-share operation by construction, so
# the share is the lab's own and the sequence is one this file owns inside it.
#
# WHAT IT WRITES ON THAT SHARE, AND NOTHING ELSE: TaskSequences\REF-CAPTURE\, one
# Control\machines\<UUID>.yaml keyed to a VM that exists only for this run and
# removed again afterwards, and whatever the capture puts in Captures\.
# rules.yaml, workspace.yaml, Applications\, Drivers\, Scripts\ and every other
# sequence are read and never touched.
#
# NOTHING TYPES AT THE PROMPT. The VM boots the HDT-built ISO and startnet.cmd
# starts the payload; tests/contract/NoKeystroke.Contract.Tests.ps1 keeps it
# that way.
#
# LAB SAFETY. Every Hyper-V call that ACTS is module-qualified and name-filtered
# to HDT-*. Every VM outside that prefix is enumerated before anything starts
# and asserted identical afterwards, in an AfterAll that runs even when the test
# failed - a set, never a list of names, because a name list rots.

BeforeDiscovery {
    $script:shareRoot = 'C:\HDTLab\Share'
    $script:discoveryWim = Test-Path -LiteralPath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' -PathType Leaf
    $script:discoveryShare = Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf

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

    $script:skipCapture = (-not $script:discoveryWim) -or (-not $script:discoveryAdk) -or (-not $script:discoveryShare)

    if ($script:skipCapture) {
        Write-Warning ("ReferenceCapture.E2E.Tests.ps1 is SKIPPED. It builds a reference image on a real deployment share, which needs the staged media (present: {0}), the Windows ADK with the WinPE add-on (resolvable: {1}) and the lab share at C:\HDTLab\Share (present: {2})." -f
            $script:discoveryWim, $script:discoveryAdk, $script:discoveryShare)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:shareRoot     = 'C:\HDTLab\Share'
    $script:sequenceId    = 'REF-CAPTURE'
    $script:computerName  = 'HDT-M7-REF01'
    $script:vmName        = 'HDT-M7-Ref'
    $script:vmRoot        = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath    = Join-Path -Path $script:vmRoot -ChildPath ('{0}-osdisk.vhdx' -f $script:vmName)
    $script:isoPath       = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:bootWimPath   = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.wim'
    $script:sequenceRoot  = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $script:sequenceId)
    $script:capturePath   = Join-Path -Path $script:shareRoot -ChildPath ('Captures\{0}.wim' -f $script:sequenceId)
    $script:artifactRoot  = 'C:\HDTLab\scratch\e2e-m7'
    $script:mountRoot     = 'C:\HDTLab\scratch\e2e-m7-mount'

    if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
        New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
    }

    # -- THE PROTECTED PAIR, RECORDED BEFORE ANYTHING STARTS ---------------
    #
    # EVERY VM THIS SUITE DOES NOT OWN, not a list of names - a name list rots,
    # and when it does the comparison silently becomes empty-against-empty and
    # holds while checking nothing (SPIKES S9.14). The unfiltered Get-VM here is
    # READ-ONLY and is the one exception PROJECT.md rule 1 allows: you cannot
    # prove you left the other VMs alone without listing them.
    #
    # MemoryStartup, NOT MemoryStartupBytes: the property is called
    # MemoryStartupBytes on New-VM's PARAMETER and MemoryStartup on the object
    # Get-VM returns, and without StrictMode the wrong one is $null, [long]
    # $null is 0, and the snapshot compares 0 with 0 (helpers README 12).
    $script:snapshotProtected = {
        return @(Hyper-V\Get-VM -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'HDT-*' } |
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

    # -- a helper that mounts a WIM read-only and answers one question ------
    #
    # READ-ONLY AND DISCARDED, ALWAYS. Nothing here may alter the image it is
    # asserting about, and a mount left behind needs dism /cleanup-wim before
    # anything on this host can mount again - which is a failure that shows up
    # in somebody else's run.
    $script:readWim = {
        param([string] $ImagePath, [scriptblock] $Reader)

        $mount = $script:mountRoot
        if (-not (Test-Path -LiteralPath $mount -PathType Container)) {
            New-Item -Path $mount -ItemType Directory -Force | Out-Null
        }

        $answer = $null
        $mounted = $false
        try {
            & dism.exe /Mount-Wim ('/WimFile:{0}' -f $ImagePath) /Index:1 ('/MountDir:{0}' -f $mount) /ReadOnly | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('dism /Mount-Wim on {0} exited {1}' -f $ImagePath, $LASTEXITCODE) }
            $mounted = $true

            $answer = & $Reader $mount
        } finally {
            if ($mounted) {
                & dism.exe /Unmount-Wim ('/MountDir:{0}' -f $mount) /Discard | Out-Null
            }
        }

        return $answer
    }

    $script:bootImageCarries = @{}
    $script:overrideFile     = ''
    $script:vmUuid           = ''
    $script:bootOrder        = @()
    $script:runFolder        = ''
    $script:record           = @()
    $script:state            = $null
    $script:endedCleanly     = $false
    $script:runSecond        = 0
    $script:runId            = ''
    $script:imageInfo        = @()
    $script:captureContent   = @{}


    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope, and reading $script:skipCapture here throws
    # under StrictMode - which ./build.ps1 sets and a bare Invoke-Pester does
    # not. Without StrictMode it is $null, 'if (-not $null)' is TRUE, and the
    # whole reference build runs on a machine that was supposed to skip it.
    $script:canRun = $false
    if ((Test-Path -LiteralPath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf)) {
        try {
            [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
            $script:canRun = $true
        } catch {
            $script:canRun = $false
        }
    }

    if ($script:canRun) {

        # -- rule 4: the memory budget, before anything is started ----------
        $runningByte = [long] 0
        foreach ($vm in @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.State -eq 'Running' })) {
            $runningByte += [long] $vm.MemoryAssigned
        }

        if (($runningByte + 4294967296) -gt 12884901888) {
            throw ("running HDT VMs already hold {0} bytes; starting a 4 GB test VM would exceed the 12 GB lab budget (PROJECT.md rule 4)." -f $runningByte)
        }

        # -- THE SEQUENCE, SEEDED FROM THIS REPOSITORY ----------------------
        #
        # ONE PLACE OF TRUTH AND THE SHARE HOLDS A COPY (CLAUDE.md rule 8). The
        # authored sequence and its marker script live in tests/e2e/payload/,
        # New-HDTTaskSequence brings the two answer files across from the
        # MODULE's Templates\, and the copy on the share is refreshed from both
        # every run. REF-BUILD is this file's own sequence: refreshing it
        # destroys nobody's edits, which is exactly why the share's OTHER
        # sequences are never written by this file at all.
        $payloadRoot = Join-Path -Path $PSScriptRoot -ChildPath 'payload/REF-CAPTURE'

        if (-not (Test-Path -LiteralPath $script:sequenceRoot -PathType Container)) {
            New-HDTTaskSequence -Workspace $script:shareRoot -Id $script:sequenceId `
                -Name 'Deploy and capture in one WinPE leg (M7 capture proof)' -Template reference -Confirm:$false | Out-Null
        }

        foreach ($leaf in @('sequence.yaml', 'Set-ReferenceMarker.ps1')) {
            Copy-Item -LiteralPath (Join-Path -Path $payloadRoot -ChildPath $leaf) `
                -Destination (Join-Path -Path $script:sequenceRoot -ChildPath $leaf) -Force
        }

        # -- THE BOOT IMAGE HAS TO CARRY THE ENGINE THAT CAN DO THIS --------
        #
        # AND THE FAILURE IS SILENT IF IT DOES NOT. A share whose Boot\ was
        # built before the Sysprep and CaptureImage steps existed boots a WinPE
        # that cannot run them, and the run fails at step 10 of 12 - an hour in,
        # on a machine that has already been generalized. So the image is
        # inspected first and rebuilt when it is stale, which writes to
        # Share\Boot\ and to nothing else.
        $carries = $false
        if ((Test-Path -LiteralPath $script:bootWimPath -PathType Leaf) -and
            (Test-Path -LiteralPath $script:isoPath -PathType Leaf)) {
            try {
                $carries = [bool] (& $script:readWim $script:bootWimPath {
                        param([string] $Mount)

                        $ini = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Templates\Capture\wimscript.ini'
                        $bundle = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Hephaestus.bundle.ps1'

                        if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { return $false }
                        if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) { return $false }

                        $text = [System.IO.File]::ReadAllText($bundle)
                        return (($text -like '*function Invoke-HDTSysprepStep*') -and
                                ($text -like '*function Invoke-HDTCaptureImageStep*'))
                    })
            } catch {
                Write-Warning ("could not inspect the existing boot image: {0}" -f $_.Exception.Message)
                $carries = $false
            }
        }

        if (-not $carries) {
            Write-Information "the share's boot image does not carry the capture engine; rebuilding Share\Boot\." -InformationAction Continue
            [void] (Update-HDTBootImage -WorkspaceRoot $script:shareRoot -Confirm:$false)
        }

        # THE SAME INSPECTION AGAIN, AND ITS ANSWER IS WHAT THE TESTS ASSERT.
        # Asked after any rebuild, so the recorded answer describes the image the
        # VM is about to boot rather than the one that was there beforehand.
        $script:bootImageCarries = & $script:readWim $script:bootWimPath {
            param([string] $Mount)

            $bundle = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Hephaestus.bundle.ps1'
            $ini = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Templates\Capture\wimscript.ini'

            $text = ''
            if (Test-Path -LiteralPath $bundle -PathType Leaf) { $text = [System.IO.File]::ReadAllText($bundle) }

            $iniText = @()
            if (Test-Path -LiteralPath $ini -PathType Leaf) { $iniText = @(Get-Content -LiteralPath $ini) }

            return @{
                Sysprep       = ($text -like '*function Invoke-HDTSysprepStep*')
                CaptureImage  = ($text -like '*function Invoke-HDTCaptureImageStep*')
                CaptureTarget = ($text -like '*function Test-HDTCaptureTarget*')
                WimScript     = (Test-Path -LiteralPath $ini -PathType Leaf)
                ExcludesHdt   = ($iniText -contains '\HDT')
                ExcludesPage  = ($iniText -contains 'pagefile.sys')
            }
        }

        # -- THE VM, AND THE OVERRIDE THAT NAMES ITS SEQUENCE ---------------
        #
        # THE ORDER MATTERS. The per-machine override is keyed on the machine's
        # UUID (DESIGN 3.1 source 2), so the VM has to exist before the file
        # that selects its sequence can be named, let alone written.

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        if (-not (Test-Path -LiteralPath $script:vmRoot -PathType Container)) {
            New-Item -Path $script:vmRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:osDiskPath) {
            Remove-Item -LiteralPath $script:osDiskPath -Force
        }

        # 100 GB. reference.yaml validates minDiskGB 80 - a reference build needs
        # more disk than a deployment does, because the capture keeps its scratch
        # on the very volume it is reading.
        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 107374182400 -Dynamic | Out-Null

        # 'HDT External', NOT 'HDT Lab'. This deployment reads the image from the
        # share and WRITES THE CAPTURE BACK TO IT over SMB, and a VM on the
        # isolated switch gets no lease and cannot reach the share at all
        # (SPIKES S6). New-HDTLabVirtualMachine leaves the DVD first in the
        # firmware order, which is what leg 3 depends on.
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT External' -VhdPath @($script:osDiskPath) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

        $script:bootOrder = @((Hyper-V\Get-VMFirmware -VMName $script:vmName).BootOrder |
                ForEach-Object { [string] $_.BootType })

        # The UUID the guest will report as HDTUuid. Hyper-V holds it as the
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

        # THE PER-MACHINE OVERRIDE - DESIGN 3.1's SECOND SOURCE, WHICH BEATS
        # rules.yaml BELOW IT. That precedence is the whole reason this file
        # never edits the share's rules: the lab's rules.yaml pins every machine
        # behind this gateway to its own sequence, and nothing types a sequence
        # id at a zero-touch machine. The override is the mechanism HDT already
        # has for making ONE machine an exception, keyed to a VM that exists only
        # for this run, and the AfterAll takes it away again.
        #
        # HDTComputerName is set for a second reason: rules.yaml's fallback names
        # a machine PC-%HDTSerialNumber%, and a Hyper-V serial is 32 characters -
        # a name over the 15 character NetBIOS limit, which Windows Setup
        # silently discards (SPIKES S9.11).
        $script:overrideFile = Join-Path -Path $script:shareRoot -ChildPath ('Control\machines\{0}.yaml' -f $script:vmUuid)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:overrideFile, @"
# Written by tests/e2e/ReferenceCapture.E2E.Tests.ps1 for this run's VM, and
# removed by its AfterAll. DESIGN 3.1 source 2, keyed on the machine's UUID.
schemaVersion: 1
variables:
  HDTComputerName: $script:computerName
  HDTTaskSequenceID: $script:sequenceId
"@, $utf8NoBom)

        # -- START IT, AND THEN SEND IT NOTHING -----------------------------
        #
        # THREE LEGS AND TWO REBOOTS, and the VM state does not distinguish them:
        # it is Running throughout, including across each restart. So the wait is
        # for the END - the payload powers the machine off when the sequence
        # finishes, whatever the outcome - and the LOG is what says which leg it
        # reached. A startnet.cmd that did not launch the payload leaves a WinPE
        # prompt and this times out, which is the discriminator for the whole
        # file.
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        Start-Sleep -Seconds 150
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm7-01-winpe.png') | Out-Null

        # NO BOOT-ORDER SCAFFOLD HERE, BECAUSE THERE IS NO SECOND BOOT.
        #
        # REF-BUILD needs one and cannot have it: its two restarts want opposite
        # things - the first must reach Windows, the second must reach the boot
        # media - and one firmware-order switch cannot serve both. MDT never
        # fights the firmware order at all; it stages WinPE onto the local disk
        # and gives that entry ONE boot with bcdedit /bootsequence
        # (ZTIBCDUtility.vbs:167). HDT has no equivalent, which is one of the two
        # reasons the full loop is blocked - the other being that nothing
        # resumes a run in WinPE.
        #
        # THIS SEQUENCE SIDESTEPS ALL OF IT by never rebooting. The payload
        # powers the machine off when the sequence ends, whatever the outcome, so
        # the wait is simply for Off - and a startnet.cmd that did not launch the
        # payload leaves a WinPE prompt and times out, which is the discriminator
        # for the whole file.

        # 40 minutes: an apply and a capture, both measured in single minutes on
        # this host, with room for a slow disk.
        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 40

        $runStopwatch.Stop()
        $script:runSecond = [int] $runStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'm7-02-ended.png') | Out-Null
        Write-Information ("the capture run ended after {0}s (clean shutdown: {1})" -f
            $script:runSecond, $script:endedCleanly) -InformationAction Continue

        # -- the evidence, off the share ------------------------------------
        #
        # STRAIGHT OFF Share\Logs\<ComputerName>\<RunId>\, because this run had a
        # share the whole way through. The other E2E files read a content disk
        # they then destroy; this one does not have to.
        $logRoot = Join-Path -Path $script:shareRoot -ChildPath ('Logs\{0}' -f $script:computerName)

        $runDir = @(Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)

        if ($runDir.Count -ge 1) {
            $script:runFolder = [string] $runDir[0].FullName
            $script:runId = [string] $runDir[0].Name

            $jsonlPath = Join-Path -Path $script:runFolder -ChildPath 'HDT.jsonl'
            if (Test-Path -LiteralPath $jsonlPath) {
                $raw = [System.IO.File]::ReadAllText($jsonlPath)
                $script:record = @(($raw -split "`r?`n") |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ConvertFrom-Json $_ })

                # PERSISTED, because a claim like "ImageState read back
                # GENERALIZE_RESEAL" could otherwise only be re-checked by
                # re-running the whole reference build.
                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'), $raw)
            }

            $statePath = Join-Path -Path $script:runFolder -ChildPath 'state.json'
            if (Test-Path -LiteralPath $statePath) {
                $script:state = ConvertFrom-Json ([System.IO.File]::ReadAllText($statePath))
            }
        }

        # -- THE CAPTURED WIM, CHEAPEST QUESTION FIRST -----------------------

        if (Test-Path -LiteralPath $script:capturePath -PathType Leaf) {
            $script:imageInfo = @(Get-WindowsImage -ImagePath $script:capturePath -ErrorAction SilentlyContinue)

            # AND THEN THE ONE THAT COSTS A MOUNT. Four questions, and the last
            # is the valuable one: dism does NOT refuse a missing /ConfigFile:,
            # it warns and captures everything, exit code zero. \HDT absent is
            # the only evidence that the exclusion list was actually applied.
            $script:captureContent = & $script:readWim $script:capturePath {
                param([string] $Mount)

                $answer = @{}
                $answer['ntoskrnl']   = Test-Path -LiteralPath (Join-Path $Mount 'Windows\System32\ntoskrnl.exe') -PathType Leaf
                $answer['marker']     = Test-Path -LiteralPath (Join-Path $Mount 'ReferenceBuild\marker.txt') -PathType Leaf
                $answer['hdtTree']    = Test-Path -LiteralPath (Join-Path $Mount 'HDT')
                $answer['pagefile']   = Test-Path -LiteralPath (Join-Path $Mount 'pagefile.sys') -PathType Leaf
                $answer['markerText'] = ''

                if ($answer['marker']) {
                    $answer['markerText'] = [System.IO.File]::ReadAllText((Join-Path $Mount 'ReferenceBuild\marker.txt'))
                }

                # THE SOFTWARE HIVE OUT OF THE IMAGE ITSELF. The file at the root
                # proves the volume; this proves the OPERATING SYSTEM inside it,
                # because HKLM\SOFTWARE travels as
                # Windows\System32\config\SOFTWARE and nothing else does.
                $answer['registryRunId'] = ''
                $hive = Join-Path $Mount 'Windows\System32\config\SOFTWARE'
                if (Test-Path -LiteralPath $hive -PathType Leaf) {
                    & reg.exe load 'HKLM\HDTCAPTURE' $hive | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        try {
                            $key = 'HKLM:\HDTCAPTURE\HDT\ReferenceBuild'
                            if (Test-Path -LiteralPath $key) {
                                $answer['registryRunId'] = [string] (Get-ItemProperty -LiteralPath $key -Name 'RunId' -ErrorAction SilentlyContinue).RunId
                            }
                        } finally {
                            # THE HANDLES HAVE TO GO BEFORE THE UNLOAD, or reg
                            # refuses - and a hive left loaded holds the mounted
                            # WIM open, so the unmount fails too.
                            [gc]::Collect()
                            [gc]::WaitForPendingFinalizers()
                            & reg.exe unload 'HKLM\HDTCAPTURE' | Out-Null
                        }
                    }
                }

                return $answer
            }
        }
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.

    # A MOUNT LEFT BEHIND IS SOMEBODY ELSE'S FAILING RUN. dism refuses to mount
    # anything while a stale mount stands, so this is swept whatever happened
    # above - and by /Discard, because nothing here was ever allowed to change
    # an image.
    try {
        foreach ($mounted in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { [string] $_.Path -eq $script:mountRoot })) {
            & dism.exe /Unmount-Wim ('/MountDir:{0}' -f $script:mountRoot) /Discard | Out-Null
        }
    } catch {
        Write-Warning ("could not sweep the WIM mount at {0}: {1}" -f $script:mountRoot, $_.Exception.Message)
    }

    try {
        if ($script:osDiskPath -and (Test-Path -LiteralPath $script:osDiskPath)) {
            $image = Get-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue
            if ($null -ne $image -and $image.Attached) {
                Dismount-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        Write-Warning ("could not dismount the lab VHDX: {0}" -f $_.Exception.Message)
    }

    # THE OVERRIDE GOES BACK. It names a UUID that will not exist once the VM is
    # gone, so leaving it would leave a file on somebody's share that can never
    # match a machine again. Removed by explicit -LiteralPath to the one file
    # this run wrote, never by enumerating Control\machines\.
    if ($script:overrideFile -and (Test-Path -LiteralPath $script:overrideFile -PathType Leaf)) {
        Remove-Item -LiteralPath $script:overrideFile -Force -ErrorAction SilentlyContinue
    }

    # AND THE MOUNT DIRECTORY, WHICH IS WORKING SPACE AND NOT EVIDENCE. The
    # artifact root beside it is on ScratchTeardown.Contract's KEEP list because
    # it holds the log and the screenshots a failed run is diagnosed from; this
    # one holds nothing once the image is unmounted, so it goes back every run.
    if (Get-Command -Name 'Remove-HDTLabScratchTree' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-m7-mount' -Confirm:$false
    }

    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        if ($env:HDT_KEEP_LAB_VM -eq '1') {
            Hyper-V\Stop-VM -Name 'HDT-M7-Ref' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M7-Ref was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M7-Ref' -Confirm:$false
        }
    }

    # THE CAPTURED WIM STAYS. It is the deliverable this file exists to produce
    # and the only copy of the evidence every assertion above rests on; a second
    # run of REF-BUILD overwrites its own output rather than somebody else's,
    # which is what naming the capture after the sequence id is for.
}

Describe 'the boot image carries the capture engine' -Tag 'E2E' -Skip:$skipCapture {

    # ASKED OF THE IMAGE THE VM ACTUALLY BOOTED, by mounting it read-only. A
    # share whose Boot\ predates these steps boots a WinPE that cannot run them
    # and fails at step 10 of 12 - an hour in, on a generalized machine.

    It 'has Invoke-HDTSysprepStep in it' {
        [bool] $script:bootImageCarries['Sysprep'] | Should -BeTrue
    }

    It 'has Invoke-HDTCaptureImageStep in it' {
        [bool] $script:bootImageCarries['CaptureImage'] | Should -BeTrue
    }

    It 'has Test-HDTCaptureTarget in it, which is what refuses a share it cannot write' {
        [bool] $script:bootImageCarries['CaptureTarget'] | Should -BeTrue
    }

    It 'carries Templates\Capture\wimscript.ini' {
        [bool] $script:bootImageCarries['WimScript'] | Should -BeTrue
    }

    It 'excludes HDT''s own working tree, which is the entry that exists because of HDT' {
        [bool] $script:bootImageCarries['ExcludesHdt'] | Should -BeTrue
    }

    It 'excludes the page file' {
        [bool] $script:bootImageCarries['ExcludesPage'] | Should -BeTrue
    }
}

Describe 'the deploy-and-capture leg ran end to end' -Tag 'E2E' -Skip:$skipCapture {

    It 'started with the boot media first in the firmware order' {
        # WHERE THE WHOLE RUN COMES FROM. New-HDTLabVirtualMachine leaves the DVD
        # first, which is what boots WinPE on a blank machine at all - and since
        # this sequence never reboots, that one setting is the only firmware
        # question it has to answer.
        @($script:bootOrder)[0] | Should -BeExactly 'Drive'
    }

    It 'ended by shutting the machine down rather than by timing out' {
        $script:endedCleanly | Should -BeTrue -Because (
            'the run went {0}s. Open {1}\m7-02-ended.png: a bare X:\Windows\System32> prompt means startnet.cmd did not launch the payload' -f
                $script:runSecond, $script:artifactRoot)
    }

    It 'ran the sequence the override named' {
        $script:record | Should -Not -BeNullOrEmpty
        @($script:record | Where-Object { [string] $_.message -like ('*{0}*' -f $script:sequenceId) }).Count |
            Should -BeGreaterThan 0
    }

    It 'reports Succeeded in state.json' {
        $script:state | Should -Not -BeNullOrEmpty
        [string] $script:state.status | Should -BeExactly 'Succeeded'
    }

    It 'completed all seven steps' {
        [int] $script:state.stepCount | Should -Be 7
    }

    It 'stamped the marker before capturing' {
        @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Stamp the reference build marker*'
            }).Count | Should -BeGreaterThan 0
    }

    It 'ran the capture in WinPE' {
        # THE PHASE IS THE ASSERTION, not just that the step ran. A CaptureImage
        # that executed in FullOS would be reading a volume Windows is writing.
        @($script:record | Where-Object {
                [string] $_.component -eq 'CaptureImage' -and [string] $_.phase -eq 'WinPE'
            }).Count | Should -BeGreaterThan 0
    }

    It 'resolved an exclusion list rather than capturing without one' {
        # NAMED IN THE LOG, WHICH IS THE ONLY PLACE IT SHOWS. The step logs which
        # wimscript.ini it chose - the share's Control\ copy when there is one,
        # otherwise the module's, which travels into every boot image. A capture
        # with no list at all is what this sentence exists to rule out.
        @($script:record | Where-Object {
                [string] $_.message -like '*excluding what*wimscript.ini names*'
            }).Count | Should -BeGreaterThan 0
    }

    It 'never failed a step' {
        $failed = @($script:record | Where-Object { [string] $_.event -eq 'step.fail' } |
                ForEach-Object { [string] $_.message })

        $failed | Should -BeNullOrEmpty -Because ($failed -join ' | ')
    }
}


Describe 'the captured image' -Tag 'E2E' -Skip:$skipCapture {

    It 'exists at Captures\REF-CAPTURE.wim on the share' {
        Test-Path -LiteralPath $script:capturePath -PathType Leaf | Should -BeTrue
    }

    It 'is a valid WIM with exactly one index' {
        # Get-WindowsImage READS THE WIM HEADER. A file dism could not parse
        # throws here, which is the cheapest possible "is this actually a WIM".
        @($script:imageInfo).Count | Should -Be 1
    }

    It 'carries the name the capture step passed' {
        [string] @($script:imageInfo)[0].ImageName | Should -BeExactly 'REF-CAPTURE'
    }

    It 'is a plausible size for a Windows installation' {
        # A FLOOR AND A CEILING. Four gigabytes is below any real Windows 11
        # image and above any empty one, and the ceiling catches the failure this
        # whole file is about: a capture with no exclusion list swallows the page
        # file and the hibernation file and comes out enormous.
        (Get-Item -LiteralPath $script:capturePath).Length | Should -BeGreaterThan 4294967296
        (Get-Item -LiteralPath $script:capturePath).Length | Should -BeLessThan 21474836480
    }

    It 'has ntoskrnl.exe in it, so it is an operating system and not a folder' {
        [bool] $script:captureContent['ntoskrnl'] | Should -BeTrue
    }

    It 'carries the marker this run stamped' {
        # THE ASSERTION THAT SEPARATES "a WIM exists" FROM "a WIM of the machine
        # we just built". Anything else here would pass for a WIM captured from
        # any machine at all.
        [bool] $script:captureContent['marker'] | Should -BeTrue
    }

    It 'carries THIS run''s id in the marker, not some earlier run''s' {
        [string] $script:captureContent['markerText'] | Should -BeLike ('*{0}*' -f $script:runId)
    }

    It 'does not claim a SOFTWARE-hive stamp this leg never wrote' {
        # THE HONEST ASSERTION, AND IT IS THE NEGATIVE ONE. The marker script
        # stamps HKLM\SOFTWARE\HDT\ReferenceBuild as well as the file, which is
        # the stronger evidence because that hive TRAVELS INSIDE the image - but
        # it can only do so from the FULL OS. In WinPE, HKLM is the boot image's
        # own registry, not the applied installation's, so the script skips the
        # hive deliberately rather than stamping a RAM disk that evaporates.
        #
        # This sequence is WinPE-only, so the hive stamp is absent BY DESIGN, and
        # asserting that keeps the file from quietly growing a claim it has not
        # earned. When REF-BUILD can run its full-OS Customize group, the
        # positive assertion belongs there.
        [string] $script:captureContent['registryRunId'] | Should -BeNullOrEmpty
    }

    It 'does NOT carry HDT''s own working tree' {
        # THE SINGLE MOST VALUABLE ASSERTION IN THIS FILE. dism does not refuse a
        # missing /ConfigFile: - it warns and captures everything, exit code
        # zero, and the image is wrong while the run is green. \HDT was certainly
        # on that volume when the capture ran, because the deployment put it
        # there and the Sysprep step deliberately does NOT delete it. So its
        # absence here is proof the exclusion list was read and applied, and
        # nothing else would be.
        [bool] $script:captureContent['hdtTree'] | Should -BeFalse
    }

    It 'does NOT carry the page file' {
        [bool] $script:captureContent['pagefile'] | Should -BeFalse
    }
}

Describe 'the lab is unharmed' -Tag 'E2E' {

    It 'had something to protect in the first place' {
        # ASSERTED SEPARATELY, AND ON PURPOSE. Comparing an empty snapshot with
        # an empty snapshot passes while checking nothing, which is exactly what
        # happened when an earlier file named two VMs that had been retired. An
        # empty host is a finding, not a pass - and on 2026-08-31 this host had
        # no non-HDT VM at all, so this is the assertion that says so out loud
        # rather than letting the comparison below quietly check nothing.
        @($script:protectedBefore).Count | Should -BeGreaterThan 0 -Because (
            'this host had no VM outside HDT-* when the run started, so the ' +
            'lab-safety comparison below has nothing to compare')
    }

    It 'left every VM it does not own exactly as it found it' {
        $after = & $script:snapshotProtected

        ($after | ConvertTo-Json -Depth 3) |
            Should -BeExactly ($script:protectedBefore | ConvertTo-Json -Depth 3)
    }

    It 'left every HDT VM powered off' {
        $running = @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue |
                Where-Object { $_.State -ne 'Off' } | ForEach-Object { [string] $_.Name })

        $running | Should -BeNullOrEmpty -Because ($running -join ', ')
    }

    It 'left no WIM mounted' {
        # A STALE MOUNT IS THE FAILURE THAT SHOWS UP IN SOMEBODY ELSE'S RUN.
        # This file mounts three images - the boot WIM twice and the capture once
        # - and every one of them read-only and discarded.
        @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object { [string] $_.Path -eq $script:mountRoot }) | Should -BeNullOrEmpty
    }

    It 'left the share''s other task sequences alone' {
        # REF-BUILD is this file's own and is refreshed every run. Nothing else
        # under TaskSequences\ is written, and the one that has to survive is
        # named here because it is the one another test depends on.
        Test-Path -LiteralPath (Join-Path -Path $script:shareRoot -ChildPath 'TaskSequences\PNP-TEST\sequence.yaml') |
            Should -BeTrue
    }

    It 'took its per-machine override back off the share' {
        if (-not [string]::IsNullOrWhiteSpace($script:overrideFile)) {
            Test-Path -LiteralPath $script:overrideFile | Should -BeFalse
        }
    }

    It 'touched no VM outside HDT-*' {
        # Asserted from the guard rather than from a transcript: every VM this
        # file creates or removes goes through New-/Remove-HDTLabVirtualMachine,
        # and Assert-HDTLabVmName refuses a wildcard and anything not named
        # HDT-*. tests/unit/New-HDTLabVirtualMachine.Tests.ps1 proves those
        # refusals, and that the guard runs before the first Hyper-V call.
        { Assert-HDTLabVmName -Name 'SomeOtherVm' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDTNoDash' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDT-*' } | Should -Throw
    }
}
