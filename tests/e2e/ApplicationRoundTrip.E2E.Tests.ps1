# THE REFERENCE-IMAGE LOOP, WITH SOFTWARE INSIDE IT - AND ONE STEP SHORT OF
# CLOSED. Read the ⚠ below before running it.
#
# TWO MACHINES AND ONE CLAIM. The first runs REF-BUILD: it deploys Windows,
# INSTALLS ACROBAT READER, stamps a marker, stages a WinPE onto its own disk,
# arms one boot into it, generalizes itself with sysprep, restarts, comes back in
# that staged WinPE and captures the volume. The second runs REF-DEPLOY-APP,
# which applies that capture and HAS NO APPLICATION STEP AT ALL.
#
# THE PROOF IS THAT ACROBAT IS ON THE SECOND MACHINE. Nothing in the second
# sequence installs software and nothing in it can - the assertion below parses
# the document and counts InstallApplications steps, so a step added later
# breaks this file rather than quietly weakening it. So the only route Acrobat
# has to that disk is INSIDE the WIM, which is the single claim a
# reference-image workflow exists to support. Every other assertion here is
# supporting evidence for that one.
#
# WHY THIS IS NOT ReferenceCapture.E2E.Tests.ps1 WITH AN EXTRA STEP.
#
# That file deploys and captures in ONE WinPE leg, deliberately, because when it
# was written the full loop could not run: nothing resumed a task sequence in
# WinPE, so the boot after sysprep minted a NEW run at step 1 and repartitioned
# the disk it had just sealed. Two mechanisms closed that hole and this file is
# what exercises them on a machine:
#
#   BootToWinPE            stages the share's boot image to <volume>\HDT\Boot,
#                          gives it a ramdisk BCD entry and hands that entry the
#                          NEXT boot with bcdedit /bootsequence - MDT's answer,
#                          which never fights the firmware order at all.
#   Get-HDTResumeCandidate scans the lettered volumes for a state document
#                          BEFORE minting anything, so the capture boot resumes
#                          the run in progress instead of starting a new one -
#                          and a resumed WinPE leg structurally refuses
#                          DiskPartition and ApplyImage.
#
# ⚠ IT DOES NOT PASS YET, AND IT IS OPT-IN FOR THAT REASON. SPIKES S23.7.
#
# Everything above the capture boot is proven on a machine, on 2026-08-31: the
# deploy, the Acrobat install (~95 s), the marker, the staging, the arm, and a
# real sysprep that genuinely generalizes - ImageState reads
# IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE and the step's own log says so. THE
# CAPTURE BOOT DOES NOT HAPPEN: the machine takes the armed one-shot, declines to
# boot the staged WinPE, and falls back to Windows and OOBE. The leading suspect
# is Secure Boot refusing the ADK's WinPE loader (S20); untested.
#
# ONE THING THIS FILE DID ALREADY SETTLE, and it is written down so nobody
# re-derives it: SYSPREP IS INDIFFERENT TO THE ARMED /bootsequence. Both
# orderings were run on a machine - arm before the seal and arm after it, MDT's
# split - and sysprep exits 0 either way and the arm succeeds either way. MDT's
# comment about deferring the BCD work "so that Sysprep doesn't complain" does
# not reproduce here, so the sequence keeps the ordering with the better
# fail-safe: nothing is generalized until the machine is known to be able to come
# back. SPIKES S23.5.
#
# SO THE ASSERTIONS BELOW ARE WRITTEN FOR THE LOOP THAT SHOULD WORK, and they
# are what will say it does when S23.7 is closed. Running this before then costs
# 45 minutes and two VMs to fail at a step already written down, which is why it
# skips unless HDT_RUN_APP_ROUND_TRIP=1.
#
# WHAT IT WRITES ON THE SHARE, AND NOTHING ELSE: TaskSequences\REF-BUILD\ and
# TaskSequences\REF-DEPLOY-APP\ (both refreshed from tests/e2e/payload, which is
# where they are authored - CLAUDE.md rule 8), two Control\machines\<UUID>.yaml
# keyed to VMs that exist only for this run and removed again afterwards,
# Captures\REF-BUILD.wim, and the OperatingSystems\REF-BUILD\ entry
# Import-HDTOperatingSystem writes. rules.yaml, workspace.yaml, Applications\,
# Drivers\, Scripts\ and every other sequence are read and never touched.
#
# THE APPLICATION IS NAMED IN THE SEQUENCE, NOT IN rules.yaml. REF-BUILD's step
# carries a fixed selection rather than reading %HDTApplications%, so this run
# proves what THIS file arranged rather than whatever the share's rules happened
# to say - and so that making it pass never means editing a rule another
# sequence depends on.
#
# THE VMs ARE SEQUENCED, NEVER CONCURRENT. Each is 4 GB and the lab budget is 12
# GB combined (PROJECT.md rule 4); more to the point the second cannot start
# until the first has produced the image it deploys. The first VM and its disk
# are removed before the second is created.
#
# NOTHING TYPES AT THE PROMPT. Both machines boot the HDT-built ISO and
# startnet.cmd starts the payload; tests/contract/NoKeystroke.Contract.Tests.ps1
# keeps it that way.
#
# LAB SAFETY. Every Hyper-V call that ACTS is module-qualified and name-filtered
# to HDT-*. Every VM outside that prefix is enumerated before anything starts and
# asserted identical afterwards, in an AfterAll that runs even when the test
# failed - a set, never a list of names, because a name list rots.

BeforeDiscovery {
    $script:shareRoot = 'C:\HDTLab\Share'
    $script:discoveryWim = Test-Path -LiteralPath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' -PathType Leaf
    $script:discoveryShare = Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf

    # THE APPLICATION IS A PRECONDITION, NOT A FIXTURE THIS FILE CAN CREATE. It
    # is a real vendor installer on the share; without it the whole claim is
    # untestable and the honest answer is to skip rather than to assert on an
    # empty install plan.
    $script:discoveryApp = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Applications\Acrobat-Acrobat-Reader-DC-2600121771\app.yaml') -PathType Leaf

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

    # ⚠ AND IT IS OPT-IN, BECAUSE THE LOOP DOES NOT CLOSE YET. SPIKES S23.7.
    #
    # Everything up to the capture boot is proven on a machine: the deploy, the
    # application install, the staging, the arm, and a real sysprep that
    # genuinely generalizes. THE CAPTURE BOOT ITSELF DOES NOT HAPPEN. The
    # machine takes the armed one-shot, declines to boot the staged WinPE, and
    # falls back to Windows and OOBE - twice, on 2026-08-31, with the arm before
    # the seal and again with it after. The leading suspect is Secure Boot
    # refusing the ADK's WinPE loader (S20), and it is not yet tested.
    #
    # SO THIS FILE SKIPS UNLESS SOMEBODY ASKS FOR IT. A suite that runs it by
    # default would burn 45 minutes and two VMs to fail at a step already
    # written down, and a red E2E nobody can fix teaches the next person to
    # ignore red E2Es. Set HDT_RUN_APP_ROUND_TRIP=1 to run it - which is what
    # the probe in S23.7 is for.
    $script:optedIn = ($env:HDT_RUN_APP_ROUND_TRIP -eq '1')

    $script:skipRoundTrip = (-not $script:optedIn) -or (-not $script:discoveryWim) -or
        (-not $script:discoveryAdk) -or (-not $script:discoveryShare) -or (-not $script:discoveryApp)

    if ($script:skipRoundTrip) {
        Write-Warning ("ApplicationRoundTrip.E2E.Tests.ps1 is SKIPPED. It closes the reference loop with an application inside it, and the capture boot is a known open blocker (SPIKES S23.7) - so it runs only when asked. Opted in (HDT_RUN_APP_ROUND_TRIP=1): {0}. It also needs the staged media (present: {1}), the Windows ADK with the WinPE add-on (resolvable: {2}), the lab share at C:\HDTLab\Share (present: {3}) and the Acrobat Reader application on it (present: {4})." -f
            $script:optedIn, $script:discoveryWim, $script:discoveryAdk, $script:discoveryShare, $script:discoveryApp)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:shareRoot        = 'C:\HDTLab\Share'
    $script:applicationId    = 'Acrobat-Acrobat-Reader-DC-2600121771'

    $script:buildSequenceId  = 'REF-BUILD'
    $script:deploySequenceId = 'REF-DEPLOY-APP'

    $script:buildVmName      = 'HDT-M7-RefApp'
    $script:deployVmName     = 'HDT-M7-RefDep'
    $script:buildComputer    = 'HDT-M7-APP01'
    $script:deployComputer   = 'HDT-M7-APP02'

    $script:isoPath          = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:bootWimPath      = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.wim'
    $script:capturePath      = Join-Path -Path $script:shareRoot -ChildPath ('Captures\{0}.wim' -f $script:buildSequenceId)

    $script:buildArtifact    = 'C:\HDTLab\scratch\e2e-refapp'
    $script:deployArtifact   = 'C:\HDTLab\scratch\e2e-refdep'
    $script:mountRoot        = 'C:\HDTLab\scratch\e2e-refapp-mount'

    foreach ($dir in @($script:buildArtifact, $script:deployArtifact)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    # -- THE PROTECTED SET, RECORDED BEFORE ANYTHING STARTS -----------------
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

    # -- a hive is COPIED OUT before it is loaded ---------------------------
    #
    # reg load OPENS THE FILE FOR WRITE. Every mount in this file is read-only -
    # deliberately, because nothing here may alter the evidence - so loading a
    # hive in place fails with a permissions error that reads like a privilege
    # problem and is not one. The copy is working space and goes back in the
    # AfterAll.
    $script:readHive = {
        param([string] $HivePath, [string] $Tag, [scriptblock] $Reader)

        $copy = Join-Path -Path $script:buildArtifact -ChildPath ('{0}.hive' -f $Tag)
        Copy-Item -LiteralPath $HivePath -Destination $copy -Force

        $answer = $null
        & reg.exe load ('HKLM\{0}' -f $Tag) $copy | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('reg load of {0} exited {1}' -f $HivePath, $LASTEXITCODE) }
        try {
            $answer = & $Reader ('HKLM:\{0}' -f $Tag)
        } finally {
            # THE HANDLES HAVE TO GO FIRST. Get-ItemProperty leaves a live key
            # handle behind and reg unload fails while one stands, which shows up
            # as a stale HKLM hive nothing else can load.
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload ('HKLM\{0}' -f $Tag) | Out-Null
        }

        return $answer
    }

    # -- one machine, start to finish ---------------------------------------
    #
    # THE VM STATE DOES NOT DISTINGUISH THE LEGS: it is Running throughout,
    # including across every restart. So the wait is for the END - the payload
    # powers the machine off when the sequence finishes, whatever the outcome -
    # and the LOG is what says which legs it reached. A startnet.cmd that did not
    # launch the payload leaves a WinPE prompt and this times out, which is the
    # discriminator for the whole file.
    $script:runMachine = {
        param(
            [string] $VmName,
            [string] $ComputerName,
            [string] $SequenceId,
            [long] $DiskByte,
            [int] $TimeoutMinute,
            [string] $ArtifactRoot,
            [string] $ShotPrefix
        )

        $vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $VmName
        $osDisk = Join-Path -Path $vmRoot -ChildPath ('{0}-osdisk.vhdx' -f $VmName)

        Remove-HDTLabVirtualMachine -Name $VmName -Confirm:$false

        if (-not (Test-Path -LiteralPath $vmRoot -PathType Container)) {
            New-Item -Path $vmRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $osDisk) { Remove-Item -LiteralPath $osDisk -Force }

        Hyper-V\New-VHD -Path $osDisk -SizeBytes $DiskByte -Dynamic | Out-Null

        # 'HDT External', NOT 'HDT Lab'. Both legs read from the share over SMB
        # and the first WRITES ITS CAPTURE BACK TO IT; a VM on the isolated
        # switch gets no lease and cannot reach the share at all (SPIKES S6).
        # New-HDTLabVirtualMachine leaves the DVD first in the firmware order,
        # which is what boots WinPE on a blank machine.
        New-HDTLabVirtualMachine -Name $VmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT External' -VhdPath @($osDisk) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

        $bootOrder = @((Hyper-V\Get-VMFirmware -VMName $VmName).BootOrder | ForEach-Object { [string] $_.BootType })

        # The UUID the guest reports as HDTUuid. Hyper-V holds it as the firmware
        # BIOS GUID, in braces.
        $vmSetting = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemSettingData' |
                Where-Object { $_.ConfigurationID -eq [string] (Hyper-V\Get-VM -Name $VmName).Id })

        $uuid = ''
        if ($vmSetting.Count -ge 1 -and $null -ne $vmSetting[0].BIOSGUID) {
            $uuid = ([string] $vmSetting[0].BIOSGUID).Trim('{', '}').ToUpperInvariant()
        }
        if ([string]::IsNullOrWhiteSpace($uuid)) {
            # Not a Should: this is setup, and a failed assertion here would
            # report as a mystery in every test below it.
            throw ("could not read the BIOS GUID of '{0}'; the per-machine override is keyed on it." -f $VmName)
        }

        # THE PER-MACHINE OVERRIDE - DESIGN 3.1's SECOND SOURCE, WHICH BEATS
        # rules.yaml BELOW IT. That precedence is the whole reason this file
        # never edits the share's rules.
        #
        # HDTComputerName is set for a second reason: rules.yaml's fallback names
        # a machine PC-%HDTSerialNumber%, and a Hyper-V serial is 32 characters -
        # a name over the 15 character NetBIOS limit, which Windows Setup
        # silently discards (SPIKES S9.11).
        $overrideFile = Join-Path -Path $script:shareRoot -ChildPath ('Control\machines\{0}.yaml' -f $uuid)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($overrideFile, @"
# Written by tests/e2e/ApplicationRoundTrip.E2E.Tests.ps1 for this run's VM, and
# removed by its AfterAll. DESIGN 3.1 source 2, keyed on the machine's UUID.
schemaVersion: 1
variables:
  HDTComputerName: $ComputerName
  HDTTaskSequenceID: $SequenceId
"@, $utf8NoBom)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Hyper-V\Start-VM -Name $VmName

        # A PICTURE EVERY TWO MINUTES, AND FOR THE FIRST MACHINE IT IS THE
        # SYSPREP PROBE'S ONLY LIVE WITNESS. Nothing in the VM state separates
        # "came back in the staged WinPE" from "came back in Windows running
        # OOBE"; the screen does, and a failed run is diagnosed from these.
        $shotIndex = 0
        $deadline = (Get-Date).AddMinutes($TimeoutMinute)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 120
            $shotIndex++
            $state = [string] (Hyper-V\Get-VM -Name $VmName).State
            try {
                Save-HDTLabVmScreen -Name $VmName -Path (Join-Path -Path $ArtifactRoot -ChildPath ('{0}-{1:d3}-{2}.png' -f $ShotPrefix, $shotIndex, $state)) | Out-Null
            } catch {
                Write-Warning ("could not photograph {0}: {1}" -f $VmName, $_.Exception.Message)
            }
            if ($state -eq 'Off') { break }
        }
        $stopwatch.Stop()

        $endedCleanly = ([string] (Hyper-V\Get-VM -Name $VmName).State -eq 'Off')

        Write-Information ("{0} ended after {1}s (clean shutdown: {2})" -f
            $VmName, [int] $stopwatch.Elapsed.TotalSeconds, $endedCleanly) -InformationAction Continue

        return [pscustomobject] @{
            Uuid         = $uuid
            OverrideFile = $overrideFile
            OsDiskPath   = $osDisk
            BootOrder    = $bootOrder
            EndedCleanly = $endedCleanly
            RunSecond    = [int] $stopwatch.Elapsed.TotalSeconds
        }
    }

    # -- the run's own record, straight off the share -----------------------
    $script:readRun = {
        param([string] $ComputerName)

        $logRoot = Join-Path -Path $script:shareRoot -ChildPath ('Logs\{0}' -f $ComputerName)
        $runDir = @(Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)

        if ($runDir.Count -eq 0) { return $null }

        $folder = $runDir[0].FullName
        $record = @()
        $jsonl = Join-Path -Path $folder -ChildPath 'HDT.jsonl'
        if (Test-Path -LiteralPath $jsonl -PathType Leaf) {
            $record = @(Get-Content -LiteralPath $jsonl -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object {
                        try { $_ | ConvertFrom-Json } catch { $null }
                    } | Where-Object { $null -ne $_ })
        }

        return [pscustomobject] @{
            Folder = $folder
            RunId  = $runDir[0].Name
            Record = $record
        }
    }

    $script:bootImageCarries = @{}
    $script:buildRun         = $null
    $script:deployRun        = $null
    $script:buildLog         = $null
    $script:deployLog        = $null
    $script:capturedFact     = @{}
    $script:deployedFact     = @{}
    $script:promoted         = $null
    $script:deploySequence   = $null
    $script:buildSequence    = $null
    $script:canRun           = $false

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope, and reading $script:skipRoundTrip here throws
    # under StrictMode - which ./build.ps1 sets and a bare Invoke-Pester does
    # not. Without StrictMode it is $null, 'if (-not $null)' is TRUE, and the
    # whole two-machine round trip runs on a host that was supposed to skip it.
    if (($env:HDT_RUN_APP_ROUND_TRIP -eq '1') -and
        (Test-Path -LiteralPath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot ('Applications\{0}\app.yaml' -f $script:applicationId)) -PathType Leaf)) {
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

        # -- BOTH SEQUENCES, SEEDED FROM THIS REPOSITORY --------------------
        #
        # ONE PLACE OF TRUTH AND THE SHARE HOLDS A COPY (CLAUDE.md rule 8). They
        # are authored in tests/e2e/payload/ and refreshed here every run, so a
        # change to either reaches the machine that runs it. Both are this
        # file's own: refreshing them destroys nobody's edits, which is exactly
        # why the share's OTHER sequences are never written by this file at all.
        foreach ($pair in @(
                @{ Id = $script:buildSequenceId;  Leaf = @('sequence.yaml', 'Set-ReferenceMarker.ps1'); Template = 'reference' },
                @{ Id = $script:deploySequenceId; Leaf = @('sequence.yaml');                            Template = 'client' })) {

            $root = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $pair.Id)
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                New-HDTTaskSequence -Workspace $script:shareRoot -Id $pair.Id `
                    -Name ('Application round trip - {0}' -f $pair.Id) -Template $pair.Template -Confirm:$false | Out-Null
            }

            $payloadRoot = Join-Path -Path $PSScriptRoot -ChildPath ('payload/{0}' -f $pair.Id)
            foreach ($leaf in $pair.Leaf) {
                Copy-Item -LiteralPath (Join-Path -Path $payloadRoot -ChildPath $leaf) `
                    -Destination (Join-Path -Path $root -ChildPath $leaf) -Force
            }
        }

        $script:buildSequence = Import-HDTSequenceDocument -Path (Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}\sequence.yaml' -f $script:buildSequenceId))
        $script:deploySequence = Import-HDTSequenceDocument -Path (Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}\sequence.yaml' -f $script:deploySequenceId))

        # -- THE BOOT IMAGE HAS TO CARRY THE ENGINE THAT CAN DO THIS --------
        #
        # AND THE FAILURE IS SILENT IF IT DOES NOT. A share whose Boot\ was built
        # before BootToWinPE and Get-HDTResumeCandidate existed boots a WinPE
        # that cannot stage, cannot arm and - worse - mints a NEW run on the
        # capture boot and repartitions the machine it just sealed. So the image
        # is inspected first and rebuilt when it is stale, which writes to
        # Share\Boot\ and to nothing else.
        #
        # THE FULL-OS LEG RUNS THE ENGINE COPIED OUT OF THE BOOT IMAGE, which is
        # why a stale Boot\ takes tonight's work out of the run even though the
        # repository is fixed.
        $carries = $false
        if ((Test-Path -LiteralPath $script:bootWimPath -PathType Leaf) -and
            (Test-Path -LiteralPath $script:isoPath -PathType Leaf)) {
            try {
                $carries = [bool] (& $script:readWim $script:bootWimPath {
                        param([string] $Mount)

                        $bundle = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Hephaestus.bundle.ps1'
                        if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) { return $false }

                        $text = [System.IO.File]::ReadAllText($bundle)
                        return (($text -like '*function Invoke-HDTBootToWinPEStep*') -and
                                ($text -like '*function Get-HDTResumeCandidate*') -and
                                ($text -like '*function Invoke-HDTInstallApplicationsStep*'))
                    })
            } catch {
                Write-Warning ("could not inspect the existing boot image: {0}" -f $_.Exception.Message)
                $carries = $false
            }
        }

        if (-not $carries) {
            Write-Information "the share's boot image does not carry the round-trip engine; rebuilding Share\Boot\." -InformationAction Continue
            [void] (Update-HDTBootImage -WorkspaceRoot $script:shareRoot -Confirm:$false)
        }

        # ASKED AGAIN AFTER ANY REBUILD, so the recorded answer describes the
        # image the VMs are about to boot rather than the one that was there
        # beforehand.
        $script:bootImageCarries = & $script:readWim $script:bootWimPath {
            param([string] $Mount)

            $bundle = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Hephaestus.bundle.ps1'
            $ini = Join-Path -Path $Mount -ChildPath 'HDT\Modules\Hephaestus\Templates\Capture\wimscript.ini'

            $text = ''
            if (Test-Path -LiteralPath $bundle -PathType Leaf) { $text = [System.IO.File]::ReadAllText($bundle) }

            $iniText = @()
            if (Test-Path -LiteralPath $ini -PathType Leaf) { $iniText = @(Get-Content -LiteralPath $ini) }

            return @{
                BootToWinPE     = ($text -like '*function Invoke-HDTBootToWinPEStep*')
                ResumeCandidate = ($text -like '*function Get-HDTResumeCandidate*')
                InstallApps     = ($text -like '*function Invoke-HDTInstallApplicationsStep*')
                Sysprep         = ($text -like '*function Invoke-HDTSysprepStep*')
                CaptureImage    = ($text -like '*function Invoke-HDTCaptureImageStep*')
                ExcludesHdt     = ($iniText -contains '\HDT')
            }
        }

        # ================================================================
        # LEG 1 - the reference build, with the application in it
        # ================================================================
        $script:buildRun = & $script:runMachine $script:buildVmName $script:buildComputer $script:buildSequenceId `
            107374182400 75 $script:buildArtifact 'refapp'

        $script:buildLog = & $script:readRun $script:buildComputer

        # -- THE CAPTURE, READ OUT OF THE WIM ITSELF ------------------------
        #
        # dism does NOT refuse a missing /ConfigFile: - it warns and captures
        # everything, exit code zero, and the image is wrong while the run is
        # green. So the image is asked rather than the log.
        if (Test-Path -LiteralPath $script:capturePath -PathType Leaf) {
            $script:capturedFact = & $script:readWim $script:capturePath {
                param([string] $Mount)

                $fact = @{
                    Ntoskrnl = (Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'Windows\System32\ntoskrnl.exe') -PathType Leaf)
                    Marker   = (Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'ReferenceBuild\marker.txt') -PathType Leaf)
                    HdtTree  = (Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'HDT'))
                    PageFile = (Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'pagefile.sys') -PathType Leaf)
                    Adobe    = ((Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'Program Files\Adobe')) -or
                                (Test-Path -LiteralPath (Join-Path -Path $Mount -ChildPath 'Program Files (x86)\Adobe')))
                    HivePath = (Join-Path -Path $Mount -ChildPath 'Windows\System32\config\SOFTWARE')
                }

                return $fact
            }

            # THE HIVE IS READ IN A SECOND PASS, because reg load needs a file
            # that outlives the mount - the copy is taken while it is mounted and
            # loaded after it is not.
            $hiveFact = & $script:readWim $script:capturePath {
                param([string] $Mount)

                $copy = Join-Path -Path 'C:\HDTLab\scratch\e2e-refapp' -ChildPath 'captured-SOFTWARE.hive'
                Copy-Item -LiteralPath (Join-Path -Path $Mount -ChildPath 'Windows\System32\config\SOFTWARE') -Destination $copy -Force
                return $copy
            }

            $script:capturedFact += & $script:readHive $hiveFact 'HDTCAPTUREDSW' {
                param([string] $Root)

                $imageState = ''
                $setup = Join-Path -Path $Root -ChildPath 'Microsoft\Windows\CurrentVersion\Setup\State'
                if (Test-Path -LiteralPath $setup) { $imageState = [string] (Get-ItemProperty -LiteralPath $setup).ImageState }

                # GENERALIZE REMOVES MachineGuid AND ZEROES InstallDate. That is
                # a stronger statement than the Sysprep step's own exit code,
                # which is why it is read here: sysprep can exit 0 having
                # declined to generalize.
                $machineGuid = ''
                $crypto = Join-Path -Path $Root -ChildPath 'Microsoft\Cryptography'
                if (Test-Path -LiteralPath $crypto) {
                    $p = Get-ItemProperty -LiteralPath $crypto
                    if ($p.PSObject.Properties.Name -contains 'MachineGuid') { $machineGuid = [string] $p.MachineGuid }
                }

                $installDate = [long] 0
                $cv = Join-Path -Path $Root -ChildPath 'Microsoft\Windows NT\CurrentVersion'
                if (Test-Path -LiteralPath $cv) {
                    $p = Get-ItemProperty -LiteralPath $cv
                    if ($p.PSObject.Properties.Name -contains 'InstallDate') { $installDate = [long] $p.InstallDate }
                }

                $acrobat = @()
                foreach ($branch in @('Microsoft\Windows\CurrentVersion\Uninstall',
                                      'Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
                    $key = Join-Path -Path $Root -ChildPath $branch
                    if (-not (Test-Path -LiteralPath $key)) { continue }
                    foreach ($child in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
                        $ip = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue
                        if ($null -ne $ip -and ($ip.PSObject.Properties.Name -contains 'DisplayName') -and
                            ([string] $ip.DisplayName) -match 'Acrobat') {
                            $acrobat += [string] $ip.DisplayName
                        }
                    }
                }

                return @{
                    ImageState  = $imageState
                    MachineGuid = $machineGuid
                    InstallDate = $installDate
                    Acrobat     = $acrobat
                }
            }
        }

        # -- PROMOTE THE CAPTURE INTO THE CATALOG ---------------------------
        #
        # -Copy IS LOAD-BEARING. Registering in place writes a ROOTED sourcePath,
        # and a rooted path does not resolve in WinPE: the deployment would go
        # looking for a C:\ path on a machine where the share is a mapped drive.
        if (Test-Path -LiteralPath $script:capturePath -PathType Leaf) {
            $script:promoted = Import-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:buildSequenceId `
                -SourcePath $script:capturePath -Name 'HDT reference image with Acrobat Reader' `
                -Description 'Built by REF-BUILD: Windows with Acrobat Reader installed, sysprepped and captured.' `
                -FileSystem (New-HDTFileSystem) -ImageService (New-HDTImageService) -Clock (New-HDTClock) `
                -Copy -Force -Confirm:$false
        }

        # -- THE FIRST MACHINE GOES BEFORE THE SECOND ARRIVES ---------------
        #
        # SEQUENCED, NEVER CONCURRENT. The budget is combined (PROJECT.md rule 4)
        # and the second machine deploys what the first produced, so there is
        # nothing to be gained by overlapping them and a rule to be broken by it.
        if ($env:HDT_KEEP_LAB_VM -ne '1') {
            Remove-HDTLabVirtualMachine -Name $script:buildVmName -Confirm:$false
        } else {
            Hyper-V\Stop-VM -Name $script:buildVmName -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
        }

        # ================================================================
        # LEG 2 - deploy that image, installing nothing
        # ================================================================
        if ($null -ne $script:promoted) {
            $script:deployRun = & $script:runMachine $script:deployVmName $script:deployComputer $script:deploySequenceId `
                85899345920 50 $script:deployArtifact 'refdep'

            $script:deployLog = & $script:readRun $script:deployComputer

            # -- THE PROOF, OFF THE SECOND MACHINE'S OWN DISK ---------------
            #
            # The VM is Off and the VHDX is mounted READ-ONLY. Nothing here may
            # change the machine it is asserting about.
            $disk = $script:deployRun.OsDiskPath
            if (Test-Path -LiteralPath $disk -PathType Leaf) {
                $image = Mount-DiskImage -ImagePath $disk -Access ReadOnly -PassThru
                try {
                    $number = ($image | Get-DiskImage | Get-Disk).Number
                    $volume = @(Get-Partition -DiskNumber $number | Get-Volume | Where-Object { $_.DriveLetter })

                    $osRoot = ''
                    foreach ($v in $volume) {
                        if (Test-Path -LiteralPath ('{0}:\Windows\System32\ntoskrnl.exe' -f $v.DriveLetter)) {
                            $osRoot = '{0}:' -f $v.DriveLetter
                            break
                        }
                    }

                    $script:deployedFact['OsRoot'] = $osRoot

                    if (-not [string]::IsNullOrWhiteSpace($osRoot)) {
                        $script:deployedFact['Ntoskrnl'] = $true
                        $script:deployedFact['Marker'] = (Test-Path -LiteralPath ('{0}\ReferenceBuild\marker.txt' -f $osRoot) -PathType Leaf)
                        $script:deployedFact['StagedWinPe'] = (Test-Path -LiteralPath ('{0}\HDT\Boot' -f $osRoot))

                        $adobe = @(@('Program Files\Adobe', 'Program Files (x86)\Adobe') |
                                Where-Object { Test-Path -LiteralPath (Join-Path -Path $osRoot -ChildPath $_) })
                        $script:deployedFact['AdobeDir'] = $adobe

                        $hive = & $script:readHive ('{0}\Windows\System32\config\SOFTWARE' -f $osRoot) 'HDTDEPLOYEDSW' {
                            param([string] $Root)

                            $acrobat = @()
                            foreach ($branch in @('Microsoft\Windows\CurrentVersion\Uninstall',
                                                  'Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
                                $key = Join-Path -Path $Root -ChildPath $branch
                                if (-not (Test-Path -LiteralPath $key)) { continue }
                                foreach ($child in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
                                    $ip = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue
                                    if ($null -ne $ip -and ($ip.PSObject.Properties.Name -contains 'DisplayName') -and
                                        ([string] $ip.DisplayName) -match 'Acrobat') {
                                        $acrobat += [string] $ip.DisplayName
                                    }
                                }
                            }

                            $machineGuid = ''
                            $crypto = Join-Path -Path $Root -ChildPath 'Microsoft\Cryptography'
                            if (Test-Path -LiteralPath $crypto) {
                                $p = Get-ItemProperty -LiteralPath $crypto
                                if ($p.PSObject.Properties.Name -contains 'MachineGuid') { $machineGuid = [string] $p.MachineGuid }
                            }

                            $installDate = [long] 0
                            $cv = Join-Path -Path $Root -ChildPath 'Microsoft\Windows NT\CurrentVersion'
                            if (Test-Path -LiteralPath $cv) {
                                $p = Get-ItemProperty -LiteralPath $cv
                                if ($p.PSObject.Properties.Name -contains 'InstallDate') { $installDate = [long] $p.InstallDate }
                            }

                            $imageState = ''
                            $setup = Join-Path -Path $Root -ChildPath 'Microsoft\Windows\CurrentVersion\Setup\State'
                            if (Test-Path -LiteralPath $setup) { $imageState = [string] (Get-ItemProperty -LiteralPath $setup).ImageState }

                            return @{
                                Acrobat     = $acrobat
                                MachineGuid = $machineGuid
                                InstallDate = $installDate
                                ImageState  = $imageState
                            }
                        }

                        foreach ($k in $hive.Keys) { $script:deployedFact[$k] = $hive[$k] }
                    }
                } finally {
                    Dismount-DiskImage -ImagePath $disk -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.

    # A MOUNT LEFT BEHIND IS SOMEBODY ELSE'S FAILING RUN. dism refuses to mount
    # anything while a stale mount stands, so this is swept whatever happened
    # above - and by /Discard, because nothing here was ever allowed to change an
    # image.
    try {
        foreach ($mounted in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { [string] $_.Path -eq $script:mountRoot })) {
            & dism.exe /Unmount-Wim ('/MountDir:{0}' -f $script:mountRoot) /Discard | Out-Null
        }
    } catch {
        Write-Warning ("could not sweep the WIM mount at {0}: {1}" -f $script:mountRoot, $_.Exception.Message)
    }

    # AND A LOADED HIVE IS THE SAME KIND OF DEBRIS. Named explicitly, never by
    # enumerating HKLM, and harmless when they were already unloaded.
    foreach ($tag in @('HDTCAPTUREDSW', 'HDTDEPLOYEDSW')) {
        if (Test-Path -LiteralPath ('HKLM:\{0}' -f $tag)) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload ('HKLM\{0}' -f $tag) 2>&1 | Out-Null
        }
    }

    foreach ($run in @($script:buildRun, $script:deployRun)) {
        if ($null -eq $run) { continue }

        try {
            if ($run.OsDiskPath -and (Test-Path -LiteralPath $run.OsDiskPath)) {
                $image = Get-DiskImage -ImagePath $run.OsDiskPath -ErrorAction SilentlyContinue
                if ($null -ne $image -and $image.Attached) {
                    Dismount-DiskImage -ImagePath $run.OsDiskPath -ErrorAction SilentlyContinue | Out-Null
                }
            }
        } catch {
            Write-Warning ("could not dismount {0}: {1}" -f $run.OsDiskPath, $_.Exception.Message)
        }

        # THE OVERRIDE GOES BACK. It names a UUID that will not exist once the VM
        # is gone, so leaving it would leave a file on somebody's share that can
        # never match a machine again. Removed by explicit -LiteralPath to the
        # one file this run wrote, never by enumerating Control\machines\.
        if ($run.OverrideFile -and (Test-Path -LiteralPath $run.OverrideFile -PathType Leaf)) {
            Remove-Item -LiteralPath $run.OverrideFile -Force -ErrorAction SilentlyContinue
        }
    }

    # THE MOUNT DIRECTORY IS WORKING SPACE AND NOT EVIDENCE. The two artifact
    # roots beside it are on ScratchTeardown.Contract's KEEP list because they
    # hold the logs and screenshots a failed run is diagnosed from; this one
    # holds nothing once the image is unmounted, so it goes back every run.
    if (Get-Command -Name 'Remove-HDTLabScratchTree' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-refapp-mount' -Confirm:$false
    }

    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        foreach ($name in @('HDT-M7-RefApp', 'HDT-M7-RefDep')) {
            if ($env:HDT_KEEP_LAB_VM -eq '1') {
                Hyper-V\Stop-VM -Name $name -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
                Write-Warning ("HDT_KEEP_LAB_VM=1: {0} was left in place, powered off." -f $name)
            } else {
                Remove-HDTLabVirtualMachine -Name $name -Confirm:$false
            }
        }
    }

    # THE CAPTURED WIM AND ITS CATALOG ENTRY STAY. They are the deliverable this
    # file exists to produce, and a second run overwrites its own output rather
    # than somebody else's - which is what naming both after the sequence id is
    # for.
}

Describe 'the boot image carries the round-trip engine' -Tag 'E2E' -Skip:$skipRoundTrip {

    # ASKED OF THE IMAGE THE VMs ACTUALLY BOOTED, by mounting it read-only. The
    # full-OS leg runs the engine copied out of this image, so a stale Boot\
    # takes the whole mechanism out of the run while the repository looks fixed.

    It 'has Invoke-HDTBootToWinPEStep in it, which is what stages and arms the capture boot' {
        [bool] $script:bootImageCarries['BootToWinPE'] | Should -BeTrue
    }

    It 'has Get-HDTResumeCandidate in it, which is what stops the capture boot repartitioning the disk' {
        [bool] $script:bootImageCarries['ResumeCandidate'] | Should -BeTrue
    }

    It 'has Invoke-HDTInstallApplicationsStep in it' {
        [bool] $script:bootImageCarries['InstallApps'] | Should -BeTrue
    }

    It 'has Invoke-HDTSysprepStep and Invoke-HDTCaptureImageStep in it' {
        [bool] $script:bootImageCarries['Sysprep'] | Should -BeTrue
        [bool] $script:bootImageCarries['CaptureImage'] | Should -BeTrue
    }

    It 'excludes HDT''s own working tree, which is where the WinPE was staged' {
        [bool] $script:bootImageCarries['ExcludesHdt'] | Should -BeTrue
    }
}

Describe 'the two sequences say what this file claims they say' -Tag 'E2E' -Skip:$skipRoundTrip {

    # PARSED, NOT GREPPED. The claim is about STEPS, and a comment naming a step
    # type would satisfy a text search while proving nothing.

    It 'the reference build installs the application by name rather than from a rule' {
        $step = @($script:buildSequence.Step | Where-Object { $_.Type -eq 'InstallApplications' })
        $step.Count | Should -Be 1

        # NAMED OUTRIGHT, which is what makes this run self-contained: reading
        # %HDTApplications% would prove whatever the share's rules said today,
        # and editing those rules to make this pass would break PNP-TEST.
        $selection = @($step[0].Property['selection'])
        $selection | Should -Contain $script:applicationId
    }

    It 'the reference build stages and arms BEFORE it generalizes, and tears down after' {
        # THE ORDER IS THE FAIL-SAFE RULE. Nothing is sealed until we know the
        # machine can come back: a generalized machine that cannot reach WinPE is
        # stranded, and there is no leg left that could fix it.
        $type = @($script:buildSequence.Step | ForEach-Object { [string] $_.Type })

        $stage = $type.IndexOf('BootToWinPE')
        $sysprep = $type.IndexOf('Sysprep')
        $capture = $type.IndexOf('CaptureImage')

        $stage | Should -BeGreaterThan -1
        $sysprep | Should -BeGreaterThan $stage
        $capture | Should -BeGreaterThan $sysprep

        @($script:buildSequence.Step | Where-Object { $_.Type -eq 'BootToWinPE' }).Count | Should -Be 3
    }

    It 'the deploy sequence has NO application step of any kind' {
        # THE WHOLE PROOF IS THIS ABSENCE. If this ever fails, the claim that
        # Acrobat arrived inside the image is worthless - and it fails loudly
        # rather than the round trip quietly proving nothing.
        @($script:deploySequence.Step | Where-Object { $_.Type -eq 'InstallApplications' }) | Should -BeNullOrEmpty
    }

    It 'the deploy sequence applies the image the reference build captured' {
        [string] $script:deploySequence.Variable['HDTOSImage'] | Should -BeExactly $script:buildSequenceId
    }
}

Describe 'the reference build ran end to end, through both reboots' -Tag 'E2E' -Skip:$skipRoundTrip {

    It 'started with the boot media first in the firmware order' {
        @($script:buildRun.BootOrder)[0] | Should -BeExactly 'Drive'
    }

    It 'ended by shutting the machine down rather than by timing out' {
        $script:buildRun.EndedCleanly | Should -BeTrue -Because (
            'the payload powers the machine off when the sequence ends, whatever the outcome. ' +
            'A machine still Running is a WinPE prompt nothing launched into, which is this file''s ' +
            'discriminator for a boot image that did not start the payload at all.')
    }

    It 'installed the application in the full OS' {
        $installed = @($script:buildLog.Record |
                Where-Object { $_.PSObject.Properties.Name -contains 'component' -and
                               [string] $_.component -eq 'InstallApplications' })
        $installed | Should -Not -BeNullOrEmpty
    }

    It 'reached the capture step, which only a resumed WinPE leg can do' {
        # THE SYSPREP PROBE'S ANSWER, IN ONE ASSERTION. The capture runs in
        # WinPE, after the reboot that follows sysprep. A machine that came back
        # in Windows running OOBE instead never reaches it - so this passing is
        # the measurement that the armed /bootsequence survived
        # sysprep /generalize.
        $captured = @($script:buildLog.Record |
                Where-Object { $_.PSObject.Properties.Name -contains 'component' -and
                               [string] $_.component -eq 'CaptureImage' })
        $captured | Should -Not -BeNullOrEmpty
    }

    It 'wrote the capture where the sequence said it would' {
        Test-Path -LiteralPath $script:capturePath -PathType Leaf | Should -BeTrue
    }
}

Describe 'the captured image is what it claims to be' -Tag 'E2E' -Skip:$skipRoundTrip {

    It 'is an operating system rather than a folder dism was happy to read' {
        [bool] $script:capturedFact['Ntoskrnl'] | Should -BeTrue
    }

    It 'carries the marker this run stamped, so it is THIS build' {
        [bool] $script:capturedFact['Marker'] | Should -BeTrue
    }

    It 'does not carry HDT''s own working tree, which is the only evidence the exclusion list was applied' {
        # dism does NOT refuse a missing /ConfigFile: - it warns, captures
        # everything and exits zero. \HDT was certainly on the volume: the
        # deployment put it there and BootToWinPE staged half a gigabyte of WinPE
        # into it. Its ABSENCE is the assertion.
        [bool] $script:capturedFact['HdtTree'] | Should -BeFalse
        [bool] $script:capturedFact['PageFile'] | Should -BeFalse
    }

    It 'carries Acrobat, because the reference build installed it before sealing' {
        [bool] $script:capturedFact['Adobe'] | Should -BeTrue
        @($script:capturedFact['Acrobat']) | Should -Not -BeNullOrEmpty
    }

    It 'was really generalized, which the step''s own exit code cannot prove' {
        # sysprep CAN EXIT 0 HAVING DECLINED TO GENERALIZE. These three are the
        # image's own statement about itself, read out of the hive inside it.
        [string] $script:capturedFact['ImageState'] | Should -BeExactly 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
        [string] $script:capturedFact['MachineGuid'] | Should -BeNullOrEmpty
        [long] $script:capturedFact['InstallDate'] | Should -Be 0
    }
}

Describe 'the second machine got the software without installing it' -Tag 'E2E' -Skip:$skipRoundTrip {

    It 'was promoted into the catalog with a RELATIVE source path' {
        # -Copy IS LOAD-BEARING and this is what it buys. A rooted sourcePath
        # does not resolve in WinPE, where the share is a mapped drive and not
        # C:\HDTLab\Share.
        $script:promoted | Should -Not -BeNullOrEmpty
        $osYaml = Join-Path -Path $script:shareRoot -ChildPath ('OperatingSystems\{0}\os.yaml' -f $script:buildSequenceId)
        Test-Path -LiteralPath $osYaml -PathType Leaf | Should -BeTrue

        $entry = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:buildSequenceId
        [System.IO.Path]::IsPathRooted($entry.SourcePath) | Should -BeFalse
        $entry.SourcePath | Should -BeLike 'sources\*'
    }

    It 'ended by shutting the machine down rather than by timing out' {
        $script:deployRun.EndedCleanly | Should -BeTrue
    }

    It 'booted into Windows, which is the one thing a mount cannot prove' {
        # The Tattoo step is the only full-OS work in the deploy sequence, so a
        # run that recorded it reached Windows, autologged on, resumed the
        # sequence and wrote to a live hive. A deployment that never booted
        # cannot fake it.
        $tattoo = @($script:deployLog.Record |
                Where-Object { $_.PSObject.Properties.Name -contains 'component' -and
                               [string] $_.component -eq 'Tattoo' })
        $tattoo | Should -Not -BeNullOrEmpty
    }

    It 'is an operating system' {
        [bool] $script:deployedFact['Ntoskrnl'] | Should -BeTrue
    }

    It 'HAS ACROBAT ON IT, and nothing in its sequence could have put it there' {
        # THE CLAIM THE WHOLE FILE EXISTS FOR. Both halves are asserted: the
        # files on disk and the uninstall entry in the machine's own hive. A
        # directory alone could be a stray copy; an uninstall entry is what the
        # installer wrote.
        @($script:deployedFact['AdobeDir']) | Should -Not -BeNullOrEmpty
        @($script:deployedFact['Acrobat']) | Should -Not -BeNullOrEmpty
    }

    It 'carries the marker, so the image is the one the reference build captured' {
        [bool] $script:deployedFact['Marker'] | Should -BeTrue
    }

    It 'minted its own identity rather than inheriting the reference machine''s' {
        # THE CAPTURED IMAGE HAD NEITHER. specialize runs on first boot and mints
        # both from unattend.xml, so a second machine carrying the reference
        # machine's MachineGuid would mean the generalize never took - and every
        # machine built from the image would collide.
        [string] $script:deployedFact['MachineGuid'] | Should -Not -BeNullOrEmpty
        [string] $script:deployedFact['MachineGuid'] | Should -Not -BeExactly ([string] $script:capturedFact['MachineGuid'])
        [long] $script:deployedFact['InstallDate'] | Should -BeGreaterThan 0
        [string] $script:deployedFact['ImageState'] | Should -BeExactly 'IMAGE_STATE_COMPLETE'
    }

    It 'did not inherit the reference build''s staged WinPE' {
        [bool] $script:deployedFact['StagedWinPe'] | Should -BeFalse
    }
}

Describe 'the lab is as it was found' -Tag 'E2E' -Skip:$skipRoundTrip {

    It 'left every VM outside HDT-* exactly as it found it' {
        $after = & $script:snapshotProtected
        Compare-Object -ReferenceObject $script:protectedBefore -DifferenceObject $after `
            -Property Name, State, Memory, Switch | Should -BeNullOrEmpty
    }

    It 'left no WIM mounted' {
        @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object { [string] $_.Path -eq $script:mountRoot }) | Should -BeNullOrEmpty
    }

    It 'left no hive loaded' {
        Test-Path -LiteralPath 'HKLM:\HDTCAPTUREDSW' | Should -BeFalse
        Test-Path -LiteralPath 'HKLM:\HDTDEPLOYEDSW' | Should -BeFalse
    }

    It 'took both per-machine overrides back off the share' {
        foreach ($run in @($script:buildRun, $script:deployRun)) {
            if ($null -eq $run) { continue }
            Test-Path -LiteralPath $run.OverrideFile | Should -BeFalse
        }
    }

    It 'left the share''s other task sequences alone' {
        # REF-BUILD and REF-DEPLOY-APP are this file's own and are refreshed
        # every run. Nothing else under TaskSequences\ is written, and the ones
        # that have to survive are named here because other tests depend on them.
        foreach ($id in @('PNP-TEST', 'REF-CAPTURE', 'REF-DEPLOY')) {
            Test-Path -LiteralPath (Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}\sequence.yaml' -f $id)) |
                Should -BeTrue
        }
    }

    It 'touched no VM outside HDT-*' {
        # Asserted from the guard rather than from a transcript: every VM this
        # file creates or removes goes through New-/Remove-HDTLabVirtualMachine,
        # and Assert-HDTLabVmName refuses a wildcard and anything not named
        # HDT-*.
        { Assert-HDTLabVmName -Name 'SomeOtherVm' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDTNoDash' } | Should -Throw
        { Assert-HDTLabVmName -Name 'HDT-*' } | Should -Throw
    }
}
