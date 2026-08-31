# THE LAST UNTESTED LINK IN THE REFERENCE-IMAGE LOOP: DEPLOY WHAT HDT CAPTURED.
#
# ReferenceCapture.E2E.Tests.ps1 proves HDT can WRITE a WIM and that the WIM is
# a WIM of the machine it read. It cannot prove the one thing that matters most
# about an image, because no mount can: THAT IT BOOTS. dism will mount a WIM
# whose boot configuration is wrong, whose registry is half-written, or whose
# volume was read while Windows was still writing to it, and report nothing at
# all. The only instrument that answers is a machine.
#
# SO THIS FILE IS THE OTHER END OF THE LOOP. Captures\REF-CAPTURE.wim was
# promoted into the workspace catalog with Import-HDTOperatingSystem, and
# TaskSequences\REF-DEPLOY deploys it the way any other catalog entry is
# deployed - same ApplyImage step, same unattend, same ConfigureBoot. Nothing in
# the engine knows or cares that this image is one of its own, which is the
# claim being tested.
#
# WHAT THE IMAGE ACTUALLY IS, AND THE FILE SAYS IT OUT LOUD BECAUSE IT CHANGES
# WHAT THE ASSERTIONS CAN CLAIM. REF-CAPTURE has SEVEN steps and none of them is
# Sysprep: gather, validate, partition, apply, stamp, capture. So the WIM is a
# Windows 11 LTSC volume that was applied and NEVER BOOTED - not a generalized
# reference image. It has therefore never been through the specialize pass, has
# no computer name of its own and no machine identity of its own. That is not a
# defect in the capture; it is exactly what DESIGN 9.3's blocked third leg
# means, and ReferenceCapture.E2E.Tests.ps1 says so in its own header.
#
# WHICH MAKES THE IDENTITY ASSERTION BELOW A REAL ONE RATHER THAN A GIVEN. An
# image with no identity gets one on first boot, from THIS deployment's
# unattend.xml, and the proof is that the machine's Cryptography\MachineGuid on
# the deployed disk is not the one inside the WIM. If specialize had not run -
# if the machine had come up as a clone of the volume that was captured - those
# two would be equal and the deployment would still look green.
#
# THE MARKER IS WHY WE KNOW WHERE THE MACHINE CAME FROM. Set-ReferenceMarker.ps1
# wrote \ReferenceBuild\marker.txt carrying run-20260831-022805 onto the volume
# REF-CAPTURE captured, so it travels INSIDE the WIM. Finding that exact run id
# on the deployed disk is the difference between "a Windows 11 machine booted"
# and "OUR image booted" - the catalog beside it holds the stock LTSC media, and
# a deployment that quietly applied that instead would be indistinguishable
# without this one string.
#
# \HDT AND \HDT ARE TWO DIFFERENT TREES AND THIS FILE DOES NOT CONFUSE THEM.
# wimscript.ini excluded the REFERENCE build's \HDT from the capture, so nothing
# carrying run-20260831-022805 may appear on the deployed disk. THIS run's own
# \HDT is a different tree with a different run id, and it is allowed to be
# there - the agent puts it there and the teardown may or may not have removed
# it by the time the disk is read. The assertion is on the run id, never on the
# folder.
#
# WHY THE REAL SHARE. Same reason ReferenceCapture gives: the image lives in the
# lab's own workspace, and the whole point is that it is an ordinary entry in an
# ordinary catalog. WHAT THIS FILE WRITES THERE, AND NOTHING ELSE:
# TaskSequences\REF-DEPLOY\ and one Control\machines\<UUID>.yaml keyed to a VM
# that exists only for this run and removed again afterwards. rules.yaml,
# workspace.yaml, Applications\, Drivers\, Scripts\, OperatingSystems\ and every
# other sequence are read and never touched.
#
# NOTHING TYPES AT THE PROMPT. HDTSkipFinalSummary and HDTFinishAction are set in
# the override precisely so no window waits for a hand: the full-OS leg would
# otherwise end on MDT's Finished screen and stand there for ever, which is a
# hang and not a failure.
#
# LAB SAFETY. Every Hyper-V call that ACTS is module-qualified and name-filtered
# to HDT-*. Every VM outside that prefix is enumerated before anything starts and
# asserted identical afterwards, in an AfterAll that runs even when the test
# failed - a set, never a list of names, because a name list rots.

BeforeDiscovery {
    $script:shareRoot = 'C:\HDTLab\Share'

    $script:discoveryShare   = Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf
    $script:discoveryCatalog = Test-Path -LiteralPath (Join-Path $script:shareRoot 'OperatingSystems\REF-CAPTURE\os.yaml') -PathType Leaf
    $script:discoveryIso     = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Boot\HDTPE_x64.iso') -PathType Leaf

    $script:skipDeploy = (-not $script:discoveryShare) -or (-not $script:discoveryCatalog) -or (-not $script:discoveryIso)

    if ($script:skipDeploy) {
        Write-Warning ("CapturedImageDeployment.E2E.Tests.ps1 is SKIPPED. It deploys a captured image from the lab share, which needs C:\HDTLab\Share (present: {0}), the REF-CAPTURE catalog entry Import-HDTOperatingSystem writes (present: {1}) and a built boot image at Share\Boot\HDTPE_x64.iso (present: {2})." -f
            $script:discoveryShare, $script:discoveryCatalog, $script:discoveryIso)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:shareRoot     = 'C:\HDTLab\Share'
    $script:sequenceId    = 'REF-DEPLOY'
    $script:osId          = 'REF-CAPTURE'
    $script:computerName  = 'HDT-M7-DEP01'

    # THE RUN THAT BUILT THE IMAGE, AND IT IS A CONSTANT ON PURPOSE. This is the
    # id Set-ReferenceMarker.ps1 stamped into the WIM on 2026-08-31; it is a
    # property of the artefact under test, not of this run, so it is written down
    # rather than discovered. Rebuild the capture and this line changes with it.
    $script:referenceRunId    = 'run-20260831-022805'
    $script:referenceComputer = 'HDT-M7-REF01'

    $script:vmName        = 'HDT-M7-Deploy'
    $script:vmRoot        = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath    = Join-Path -Path $script:vmRoot -ChildPath ('{0}-osdisk.vhdx' -f $script:vmName)
    $script:isoPath       = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:sequenceRoot  = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $script:sequenceId)
    $script:catalogPath   = Join-Path -Path $script:shareRoot -ChildPath ('OperatingSystems\{0}\os.yaml' -f $script:osId)
    $script:artifactRoot  = 'C:\HDTLab\scratch\e2e-refdeploy'
    $script:mountRoot     = 'C:\HDTLab\scratch\e2e-refdeploy-mount'

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

    # -- READING A MACHINE'S IDENTITY OUT OF A SOFTWARE HIVE ---------------
    #
    # ONE READER, TWO SUBJECTS, WHICH IS THE ONLY WAY THE COMPARISON MEANS
    # ANYTHING. It is pointed at the SOFTWARE hive inside the captured WIM and at
    # the SOFTWARE hive on the deployed disk, and the values it returns are
    # compared with each other. Two different readers would be comparing two
    # different questions.
    #
    # MachineGuid IS THE VALUE THAT ANSWERS "IS THIS THE SAME INSTALLATION".
    # Setup writes it in the specialize pass, which is the pass that runs on the
    # first boot of an applied image. A machine that came up as a byte-copy of
    # the captured volume would carry the captured volume's guid.
    #
    # THE HANDLES HAVE TO GO BEFORE THE UNLOAD, or reg refuses - and a hive left
    # loaded holds the mounted WIM or the mounted VHDX open, so the unmount fails
    # too and the failure lands in somebody else's run.
    $script:readIdentity = {
        param([string] $ConfigFolder, [string] $HiveKey)

        $answer = @{ MachineGuid = ''; InstallDate = ''; ProductName = '' }
        $hive = Join-Path -Path $ConfigFolder -ChildPath 'SOFTWARE'

        if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) { return $answer }

        # THE HIVE IS COPIED OUT BEFORE IT IS LOADED, and that is not caution -
        # it is the only way this works at all. reg load OPENS THE HIVE FILE FOR
        # WRITE even when nothing writes to it, so on a WIM mounted /ReadOnly it
        # fails, and the first version of this file read an empty MachineGuid off
        # the captured image and could not say why. Copying is also the honest
        # shape: the subject of this comparison is evidence, and evidence is not
        # opened for write.
        $working = Join-Path -Path $script:artifactRoot -ChildPath ('{0}.hive' -f $HiveKey)
        Copy-Item -LiteralPath $hive -Destination $working -Force

        & reg.exe load ('HKLM\{0}' -f $HiveKey) $working | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
            return $answer
        }

        try {
            $crypto = 'HKLM:\{0}\Microsoft\Cryptography' -f $HiveKey
            if (Test-Path -LiteralPath $crypto) {
                $answer['MachineGuid'] = [string] (Get-ItemProperty -LiteralPath $crypto -Name 'MachineGuid' -ErrorAction SilentlyContinue).MachineGuid
            }

            $current = 'HKLM:\{0}\Microsoft\Windows NT\CurrentVersion' -f $HiveKey
            if (Test-Path -LiteralPath $current) {
                $property = Get-ItemProperty -LiteralPath $current -ErrorAction SilentlyContinue
                $answer['InstallDate'] = [string] $property.InstallDate
                $answer['ProductName'] = [string] $property.ProductName
            }
        } finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload ('HKLM\{0}' -f $HiveKey) | Out-Null
            Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
        }

        return $answer
    }

    $script:overrideFile      = ''
    $script:vmUuid            = ''
    $script:bootOrder         = @()
    $script:runFolder         = ''
    $script:runId             = ''
    $script:record            = @()
    $script:state             = $null
    $script:endedCleanly      = $false
    $script:runSecond         = 0
    $script:capturedWim       = ''
    $script:offlineName       = ''
    $script:capturedIdentity  = @{ MachineGuid = ''; InstallDate = ''; ProductName = '' }
    $script:deployed          = @{
        osRoot       = ''
        ntoskrnl     = $false
        marker       = $false
        markerText   = ''
        hdtTree      = $false
        referenceHdt = $false
        identity     = @{ MachineGuid = ''; InstallDate = ''; ProductName = '' }
    }

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope, and reading $script:skipDeploy here throws
    # under StrictMode - which ./build.ps1 sets and a bare Invoke-Pester does
    # not. Without StrictMode it is $null, 'if (-not $null)' is TRUE, and a
    # deployment runs on a machine that was supposed to skip it.
    $script:canRun = (
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf) -and
        (Test-Path -LiteralPath $script:catalogPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:isoPath -PathType Leaf))

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
        # authored sequence lives in tests/e2e/payload/REF-DEPLOY,
        # New-HDTTaskSequence brings the answer files across from the MODULE's
        # Templates\, and the copy on the share is refreshed from the payload
        # every run. REF-DEPLOY is this file's own sequence: refreshing it
        # destroys nobody's edits, which is exactly why the share's OTHER
        # sequences are never written by this file at all.
        $payloadRoot = Join-Path -Path $PSScriptRoot -ChildPath 'payload/REF-DEPLOY'

        if (-not (Test-Path -LiteralPath $script:sequenceRoot -PathType Container)) {
            New-HDTTaskSequence -Workspace $script:shareRoot -Id $script:sequenceId `
                -Name 'Deploy the image HDT captured' -Template client -Confirm:$false | Out-Null
        }

        Copy-Item -LiteralPath (Join-Path -Path $payloadRoot -ChildPath 'sequence.yaml') `
            -Destination (Join-Path -Path $script:sequenceRoot -ChildPath 'sequence.yaml') -Force

        # -- THE VM, AND THE OVERRIDE THAT NAMES ITS SEQUENCE ---------------
        #
        # THE ORDER MATTERS. The per-machine override is keyed on the machine's
        # UUID (DESIGN 3.1 source 2), so the VM has to exist before the file that
        # selects its sequence can be named, let alone written.

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        if (-not (Test-Path -LiteralPath $script:vmRoot -PathType Container)) {
            New-Item -Path $script:vmRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:osDiskPath) {
            Remove-Item -LiteralPath $script:osDiskPath -Force
        }

        # 100 GB dynamic. REF-DEPLOY validates minDiskGB 60; the extra room costs
        # nothing on a dynamic disk and leaves space for the 1 GB recovery
        # partition the UEFI layout carries.
        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 107374182400 -Dynamic | Out-Null

        # 'HDT External', NOT 'HDT Lab'. This deployment READS A 4.6 GB IMAGE OFF
        # THE SHARE over SMB, and a VM on the isolated switch gets no lease and
        # cannot reach the share at all (SPIKES S6).
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
        # behind this gateway to PNP-TEST, and nothing types a sequence id at a
        # zero-touch machine.
        #
        # HDTComputerName is set for a second reason: rules.yaml's fallback names
        # a machine PC-%HDTSerialNumber%, and a Hyper-V serial is 32 characters -
        # a name over the 15 character NetBIOS limit, which Windows Setup
        # silently discards (SPIKES S9.11).
        #
        # THE LAST TWO LINES ARE WHAT MAKES THIS RUN UNATTENDED TO THE END. The
        # full-OS leg draws MDT's Finished screen and BLOCKS on it, so a run with
        # no hand in front of it would stand there for ever - a hang, which reads
        # as a timeout and diagnoses as anything at all. HDTSkipFinalSummary
        # takes the screen away and HDTFinishAction powers the machine off, which
        # is what turns "did it boot" into a state this file can wait for.
        $script:overrideFile = Join-Path -Path $script:shareRoot -ChildPath ('Control\machines\{0}.yaml' -f $script:vmUuid)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:overrideFile, @"
# Written by tests/e2e/CapturedImageDeployment.E2E.Tests.ps1 for this run's VM,
# and removed by its AfterAll. DESIGN 3.1 source 2, keyed on the machine's UUID.
schemaVersion: 1
variables:
  HDTComputerName: $script:computerName
  HDTTaskSequenceID: $script:sequenceId
  HDTSkipFinalSummary: true
  HDTFinishAction: Shutdown
"@, $utf8NoBom)

        # -- START IT, AND THEN SEND IT NOTHING -----------------------------
        #
        # TWO LEGS AND ONE REBOOT, and the VM state does not distinguish them: it
        # is Running throughout, including across the restart into Windows. So
        # the wait is for the END - HDTFinishAction powers the machine off when
        # the full-OS leg finishes - and the LOG is what says which leg it
        # reached. A startnet.cmd that did not launch the payload leaves a WinPE
        # prompt and this times out, which is the discriminator for the whole
        # file.
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        Start-Sleep -Seconds 150
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refdeploy-01-winpe.png') | Out-Null

        # NO BOOT-ORDER SCAFFOLD. SPIKES S6's fourth finding as an assertion: if
        # ConfigureBoot did its job the firmware now prefers the Windows Boot
        # Manager and the restart reaches Windows; if it did not, this VM boots
        # WinPE again, mints a second run, and repartitions the disk it just
        # imaged - which the FullOS assertions below would catch.
        #
        # 60 minutes: an apply of a 4.6 GB image over SMB, a restart, Windows
        # Setup's specialize and oobeSystem passes, an autologon and a full-OS
        # leg - with room for a slow first boot.
        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 60

        $runStopwatch.Stop()
        $script:runSecond = [int] $runStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refdeploy-02-ended.png') | Out-Null
        Write-Information ("the deployment ended after {0}s (powered off cleanly: {1})" -f
            $script:runSecond, $script:endedCleanly) -InformationAction Continue

        # -- the evidence, off the share ------------------------------------
        #
        # STRAIGHT OFF Share\Logs\<ComputerName>\<RunId>\, because this run had a
        # share the whole way through - both legs of it.
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

                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'), $raw)
            }

            # state.json IS NOT BESIDE THE JSONL, AND THE TWO LEGS ARE WHY.
            #
            # rules.yaml sets HDTSLShareDynamicLogging to Logs\%HDTComputerName%,
            # so the run log is copied to Logs\<name>\<runid>\ - which is the
            # folder above, and it carries the WHOLE run, both legs. The engine's
            # own per-run directory is the FLAT sibling Logs\<name>-<runid>\, and
            # that is where state.json and status.json are written.
            #
            # The first version of this file looked only in the nested folder,
            # found HDT.jsonl there, and reported "no state.json" on a deployment
            # that had succeeded. Both are checked now, flat first, because the
            # flat one is the engine's and the nested one is a copy of part of it.
            foreach ($candidate in @(
                    (Join-Path -Path $script:shareRoot -ChildPath ('Logs\{0}-{1}\state.json' -f $script:computerName, $script:runId)),
                    (Join-Path -Path $script:runFolder -ChildPath 'state.json'))) {

                if ((-not $script:state) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $script:state = ConvertFrom-Json ([System.IO.File]::ReadAllText($candidate))
                }
            }
        }

        # THE OVERRIDE COMES OFF AS SOON AS THE RUN IS OVER, not in the AfterAll.
        # It has done its job - the machine read it at boot - and taking it away
        # here is what lets 'the lab is unharmed' actually OBSERVE the share
        # being clean. In the AfterAll the removal happens after every assertion
        # has run, so the file was still there when the test looked and the suite
        # reported a leak it had already fixed. The AfterAll still removes it,
        # because this line does not run when the wait above throws.
        if ($script:overrideFile -and (Test-Path -LiteralPath $script:overrideFile -PathType Leaf)) {
            Remove-Item -LiteralPath $script:overrideFile -Force -ErrorAction SilentlyContinue
        }

        # -- THE DEPLOYED DISK, READ OFFLINE --------------------------------
        #
        # AFTER THE MACHINE IS OFF, and mounted READ-ONLY: this is evidence, and
        # evidence is not written to. The OS volume is found by looking for
        # Windows\System32 rather than by partition number, because the UEFI
        # layout puts an ESP and a recovery partition on the same disk and the
        # letters Windows hands out to a mounted VHDX are not the ones WinPE
        # used.
        if ($script:endedCleanly) {
            try {
                Mount-DiskImage -ImagePath $script:osDiskPath -StorageType VHDX -Access ReadOnly | Out-Null
                $number = [int] (Get-DiskImage -ImagePath $script:osDiskPath).Number

                # $_.DriveLetter, NOT [string]::IsNullOrWhiteSpace ON IT. A
                # partition with no letter reports DriveLetter as [char] 0, and
                # [string] [char] 0 is a one-character string holding NUL - which
                # is not null and not white space, so the guard passed and the
                # candidate became ' :\'. Join-Path then resolved the drive,
                # threw DriveNotFound, and took the whole container down after a
                # deployment that had already succeeded. [char] 0 IS falsy, which
                # is why Get-HDTLabOfflineComputerName has always written it this
                # way, and every path below is built by -f rather than Join-Path
                # for the reason CLAUDE.md gives: Join-Path resolves the drive.
                $volume = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter })

                $osRoot = ''
                foreach ($partition in $volume) {
                    if (Test-Path -LiteralPath ('{0}:\Windows\System32' -f $partition.DriveLetter) -PathType Container) {
                        $osRoot = '{0}:\' -f $partition.DriveLetter
                        break
                    }
                }

                Write-Information ("the deployed OS volume mounted at '{0}'" -f $osRoot) -InformationAction Continue

                if (-not [string]::IsNullOrWhiteSpace($osRoot)) {
                    $script:deployed['osRoot']   = $osRoot
                    $script:deployed['ntoskrnl'] = Test-Path -LiteralPath (Join-Path $osRoot 'Windows\System32\ntoskrnl.exe') -PathType Leaf
                    $script:deployed['marker']   = Test-Path -LiteralPath (Join-Path $osRoot 'ReferenceBuild\marker.txt') -PathType Leaf

                    if ($script:deployed['marker']) {
                        $script:deployed['markerText'] = [System.IO.File]::ReadAllText((Join-Path $osRoot 'ReferenceBuild\marker.txt'))
                        [System.IO.File]::WriteAllText(
                            (Join-Path -Path $script:artifactRoot -ChildPath 'DEPLOYED-MARKER.txt'),
                            $script:deployed['markerText'])
                    }

                    # THE REFERENCE BUILD'S \HDT, WHICH MUST NOT BE HERE - AND
                    # THIS RUN'S OWN, WHICH MAY BE. The question is never "is
                    # there an \HDT" but "does any \HDT here carry the RUN ID OF
                    # THE BUILD THAT WAS CAPTURED". A tree named for
                    # run-20260831-022805 could only have arrived inside the WIM,
                    # which would mean wimscript.ini's exclusion did not hold.
                    $script:deployed['hdtTree'] = Test-Path -LiteralPath (Join-Path $osRoot 'HDT')

                    if ($script:deployed['hdtTree']) {
                        $stale = @(Get-ChildItem -LiteralPath (Join-Path $osRoot 'HDT') -Recurse -Force -ErrorAction SilentlyContinue |
                                Where-Object { [string] $_.Name -like ('*{0}*' -f $script:referenceRunId) })

                        $script:deployed['referenceHdt'] = ($stale.Count -gt 0)
                    }

                    $script:deployed['identity'] = & $script:readIdentity (Join-Path $osRoot 'Windows\System32\config') 'HDTDEPLOYED'
                }
            } finally {
                Dismount-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue | Out-Null
            }

            # AND THE NAME, THROUGH THE HELPER EVERY OTHER E2E FILE USES, so the
            # answer is produced the same way here as it is there.
            $script:offlineName = Get-HDTLabOfflineComputerName -VhdPath $script:osDiskPath
            Write-Information ("offline computer name: '{0}'" -f $script:offlineName) -InformationAction Continue
        }

        # -- AND THE IMAGE IT CAME FROM, FOR THE COMPARISON -----------------
        #
        # THE SAME READER, POINTED AT THE WIM. Mounted read-only and discarded; a
        # mount left behind needs dism /cleanup-wim before anything on this host
        # can mount again, which is a failure that shows up in somebody else's
        # run.
        if (-not (Test-Path -LiteralPath $script:mountRoot -PathType Container)) {
            New-Item -Path $script:mountRoot -ItemType Directory -Force | Out-Null
        }

        $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:osId
        $script:capturedWim = [string] $catalog.ImagePath

        $mounted = $false
        try {
            & dism.exe /Mount-Wim ('/WimFile:{0}' -f $script:capturedWim) /Index:1 ('/MountDir:{0}' -f $script:mountRoot) /ReadOnly | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('dism /Mount-Wim on {0} exited {1}' -f $script:capturedWim, $LASTEXITCODE) }
            $mounted = $true

            $script:capturedIdentity = & $script:readIdentity (Join-Path $script:mountRoot 'Windows\System32\config') 'HDTCAPTURED'
        } catch {
            Write-Warning ("could not read the captured image's identity: {0}" -f $_.Exception.Message)
        } finally {
            if ($mounted) {
                & dism.exe /Unmount-Wim ('/MountDir:{0}' -f $script:mountRoot) /Discard | Out-Null
            }
        }

        Write-Information ("captured MachineGuid '{0}', deployed MachineGuid '{1}'" -f
            $script:capturedIdentity['MachineGuid'], $script:deployed['identity']['MachineGuid']) -InformationAction Continue
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.

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

    if (Get-Command -Name 'Remove-HDTLabScratchTree' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-refdeploy-mount' -Confirm:$false
    }

    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        if ($env:HDT_KEEP_LAB_VM -eq '1') {
            Hyper-V\Stop-VM -Name 'HDT-M7-Deploy' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M7-Deploy was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M7-Deploy' -Confirm:$false
        }
    }

    # THE CATALOG ENTRY STAYS. It is what this file deploys, it was promoted by
    # hand with Import-HDTOperatingSystem, and removing it would leave the share
    # unable to run REF-DEPLOY again.
}

Describe 'the captured image is an ordinary catalog entry' -Tag 'E2E' -Skip:$skipDeploy {

    # BEFORE ANY VM: the promotion is what the deployment rests on, and it is
    # cheap to check. A catalog whose sourcePath were rooted at C:\ would be
    # unreachable from WinPE, where there is no C:\HDTLab at all - which is the
    # trap -Copy exists to avoid and the reason this is asserted rather than
    # assumed.

    It 'is in the workspace catalog' {
        $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:osId
        [string] $catalog.Id | Should -BeExactly $script:osId
    }

    It 'records a RELATIVE sourcePath, which is the only kind WinPE can resolve' {
        $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:osId
        [System.IO.Path]::IsPathRooted([string] $catalog.SourcePath) | Should -BeFalse -Because (
            "sourcePath is '{0}'. A rooted local path is kept as it is by design, and WinPE has no C:\HDTLab to resolve it against" -f $catalog.SourcePath)
    }

    It 'has exactly one index, read off the WIM rather than typed' {
        $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:osId
        @($catalog.Images).Count | Should -Be 1
        [string] @($catalog.Images)[0].Name | Should -BeExactly 'REF-CAPTURE'
    }
}

Describe 'the deployment ran end to end' -Tag 'E2E' -Skip:$skipDeploy {

    It 'started with the boot media first in the firmware order' {
        @($script:bootOrder)[0] | Should -BeExactly 'Drive'
    }

    It 'ended by powering the machine off rather than by timing out' {
        $script:endedCleanly | Should -BeTrue -Because (
            'the run went {0}s. Open {1}\refdeploy-02-ended.png: a bare X:\Windows\System32> prompt means startnet.cmd did not launch the payload, and a Windows desktop means the full-OS leg is still going' -f
                $script:runSecond, $script:artifactRoot)
    }

    It 'ran the sequence the override named' {
        $script:record | Should -Not -BeNullOrEmpty
        @($script:record | Where-Object { [string] $_.message -like ('*{0}*' -f $script:sequenceId) }).Count |
            Should -BeGreaterThan 0
    }

    It 'applied the CAPTURED image and not the vendor media beside it' {
        # THE CATALOG ID IN THE LOG. Both entries are in the same catalog and
        # both are Windows 11 LTSC; without this line a run that applied
        # Win11-LTSC-2024 would look identical until the marker assertion far
        # below finally caught it.
        @($script:record | Where-Object {
                [string] $_.message -like ('*{0}*' -f $script:osId) -and
                [string] $_.message -like '*.wim*'
            }).Count | Should -BeGreaterThan 0
    }

    It 'reports Succeeded in state.json' {
        $script:state | Should -Not -BeNullOrEmpty
        [string] $script:state.status | Should -BeExactly 'Succeeded'
    }

    It 'never failed a step' {
        $failed = @($script:record | Where-Object { [string] $_.event -eq 'step.fail' } |
                ForEach-Object { [string] $_.message })

        $failed | Should -BeNullOrEmpty -Because ($failed -join ' | ')
    }
}

Describe 'it booted into Windows' -Tag 'E2E' -Skip:$skipDeploy {

    # THE ASSERTION A MOUNT CANNOT MAKE, and the reason this file exists. Every
    # record below was written by an engine running INSIDE the deployed
    # installation: a machine that did not boot cannot produce one.

    It 'has records from the FullOS phase' {
        @($script:record | Where-Object { [string] $_.phase -eq 'FullOS' }).Count |
            Should -BeGreaterThan 0 -Because (
                'every record in this run is from WinPE, so the restart never reached Windows. Open {0}\refdeploy-02-ended.png' -f $script:artifactRoot)
    }

    It 'resumed the sequence on the far side of the restart' {
        # LEG 2. The resume leg is launched by autologon inside Windows, so a
        # record naming it is proof of a booted OS, a logged-on session and a
        # reachable share all at once.
        @($script:record | Where-Object { [string] $_.message -like '*leg 2*' }).Count |
            Should -BeGreaterThan 0
    }

    It 'completed the Tattoo step, which only a live registry can take' {
        @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Tattoo*'
            }).Count | Should -BeGreaterThan 0
    }
}

Describe 'the machine it built' -Tag 'E2E' -Skip:$skipDeploy {

    It 'has an operating system on it, not just a folder' {
        [bool] $script:deployed['ntoskrnl'] | Should -BeTrue
    }

    It 'carries the reference build''s marker' {
        [bool] $script:deployed['marker'] | Should -BeTrue -Because (
            'the marker travels inside the WIM. Its absence means the volume did not come from Captures\REF-CAPTURE.wim')
    }

    It 'carries the run id of the build that was captured, which is the whole point' {
        # THE SINGLE MOST VALUABLE ASSERTION IN THIS FILE. Win11-LTSC-2024 sits
        # in the same catalog and would deploy to a machine that looks exactly
        # like this one. This string exists on no medium but ours.
        [string] $script:deployed['markerText'] | Should -BeLike ('*{0}*' -f $script:referenceRunId) -Because (
            'the marker says: {0}' -f ([string] $script:deployed['markerText'] -replace "`r?`n", ' / '))
    }

    It 'was named by THIS deployment''s unattend' {
        [string] $script:offlineName | Should -BeExactly $script:computerName
    }

    It 'is not the machine that was captured' {
        # THE IMAGE HAD NEVER BEEN BOOTED, so it has no name of its own - which
        # is why the name alone is not the evidence here and the guid below is.
        # This line still earns its place: a machine that had somehow come up as
        # the reference build would answer to the reference build's name.
        [string] $script:offlineName | Should -Not -BeExactly $script:referenceComputer
    }

    It 'came from an image that had no machine identity of its own' {
        # MEASURED, NOT ASSUMED, and it is the half of the pair that makes the
        # next assertion mean something.
        #
        # The captured volume was applied by dism and never started, so Setup's
        # specialize pass has never run on it. Its SOFTWARE hive HAS the
        # Microsoft\Cryptography key - it comes with the media - and that key has
        # NO MachineGuid value at all, with InstallDate still 0. An image in that
        # state cannot hand a machine an identity, so any identity the deployed
        # disk carries was minted on this machine's own first boot.
        [string] $script:capturedIdentity['MachineGuid'] | Should -BeNullOrEmpty -Because (
            'the captured volume was never booted, so nothing has written one yet')
        [string] $script:capturedIdentity['InstallDate'] | Should -BeIn @('', '0') -Because (
            'InstallDate is stamped by specialize, which has never run on this image')
    }

    It 'was given a NEW machine identity by the specialize pass' {
        # THE REAL "not the machine that was captured" ASSERTION, and the one
        # that proves the deployment produced an INSTALLATION rather than a
        # byte-copy of a volume. Cryptography\MachineGuid is written by Setup in
        # specialize, on the first boot of an applied image; a machine that had
        # simply inherited the captured volume would carry what the assertion
        # above just showed is not there - nothing.
        $captured = [string] $script:capturedIdentity['MachineGuid']
        $deployed = [string] $script:deployed['identity']['MachineGuid']

        $deployed | Should -Not -BeNullOrEmpty -Because 'specialize did not run, so this machine has no identity of its own'
        $deployed | Should -Match '^[0-9a-fA-F-]{36}$' -Because ("MachineGuid read back as '{0}'" -f $deployed)
        $deployed | Should -Not -BeExactly $captured -Because (
            'captured {0}, deployed {1}' -f $captured, $deployed)

        # AND THE CLOCK STARTED. InstallDate is 0 in the image and a real epoch
        # second on the machine, which is the same event seen from a second
        # value - so a MachineGuid that had somehow arrived any other way could
        # not carry this one with it.
        [long] $script:deployed['identity']['InstallDate'] | Should -BeGreaterThan 0
    }

    It 'does NOT carry the reference build''s own working tree' {
        # NOT "has no \HDT". This deployment puts its own \HDT on the volume and
        # is entitled to; the question is whether the REFERENCE build's tree came
        # across inside the WIM, and the run id is what tells them apart.
        # wimscript.ini excluded it, and dism does not refuse a missing
        # /ConfigFile: - it warns and captures everything, exit code zero.
        [bool] $script:deployed['referenceHdt'] | Should -BeFalse -Because (
            'a tree named for {0} on this disk could only have arrived inside the image' -f $script:referenceRunId)
    }
}

Describe 'the lab is unharmed' -Tag 'E2E' {

    It 'could see the host''s virtual machines at all' {
        # THE VACUITY GUARD, POINTED AT SOMETHING THAT IS TRUE HERE.
        #
        # The comparison below is empty-against-empty on THIS host, because on
        # 2026-08-31 it carried no VM outside HDT-* - and an assertion that the
        # protected set is non-empty is therefore one that can never pass, which
        # is a red mark that teaches nobody anything. What actually has to be
        # ruled out is the OTHER reason a snapshot comes back empty: an
        # enumeration that returned nothing because it could not read Hyper-V at
        # all. So the guard is on the unfiltered read, which this file makes
        # exactly once and only to prove it left the others alone.
        #
        # The moment a non-HDT VM exists on this host, the comparison below
        # starts carrying real content without a line of this file changing.
        @(Hyper-V\Get-VM -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0 -Because (
            'Get-VM answered with nothing at all, so the snapshot below is empty ' +
            'because Hyper-V could not be read rather than because the host has ' +
            'no VM outside HDT-*')
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
        @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object { [string] $_.Path -eq $script:mountRoot }) | Should -BeNullOrEmpty
    }

    It 'left the share''s other task sequences alone' {
        # REF-DEPLOY is this file's own and is refreshed every run. Nothing else
        # under TaskSequences\ is written, and the two that have to survive are
        # named here because other tests depend on them.
        Test-Path -LiteralPath (Join-Path -Path $script:shareRoot -ChildPath 'TaskSequences\PNP-TEST\sequence.yaml') |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $script:shareRoot -ChildPath 'TaskSequences\REF-CAPTURE\sequence.yaml') |
            Should -BeTrue
    }

    It 'left the captured WIM where the capture put it' {
        Test-Path -LiteralPath (Join-Path -Path $script:shareRoot -ChildPath 'Captures\REF-CAPTURE.wim') -PathType Leaf |
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
