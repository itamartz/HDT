# DESIGN 9.1 RULE 5, ON HARDWARE. THE GUARD THAT DECIDES WHICH DISK GETS WIPED.
#
# Commit d807c60 fixed this defect: a non-RAW disk whose partitions carry NO
# DRIVE LETTER was cleared by DiskPartition though the sequence never declared
# wipe: true. Rule 5 was evaluated by matching VOLUMES to a disk BY LETTER, and
# IDiskService.GetVolume() reports only volumes that have one - so a disk lifted
# out of another machine produced an empty set on a disk that was full, and
# "carries no data" was the answer HDT gave about somebody's data.
#
# THAT FIX IS PROVEN AGAINST HAND-WRITTEN FAKES AND NOTHING ELSE, and this is
# the single most destructive failure mode in this class of tool. So it gets
# hardware evidence before v1.0.0 is tagged, which is what this file is.
#
# ---------------------------------------------------------------------------
# THE DISK SHAPE IS THE SUBTLE PART, AND GETTING IT WRONG MAKES THIS FILE PASS
# WHILE PROVING THE OLD BEHAVIOUR
# ---------------------------------------------------------------------------
#
# In WinPE, volumes are normally lettered automatically. Removing a letter on
# the host therefore does NOT survive into WinPE on its own: the volume is
# simply lettered again on the other side, rule 5 fires through its $data arm -
# the arm that worked BEFORE d807c60 - and this suite reports a refusal that
# says nothing about the fix.
#
# Two shapes DO survive, and this file builds both of them on one disk:
#
#   an ESP / System partition       no letter by nature. Windows does not letter
#                                   an EFI System partition and neither does
#                                   WinPE.
#   NoDefaultDriveLetter            a GPT basic data partition carrying GPT
#                                   attribute 0x8000000000000000. Set-Partition
#                                   -NoDefaultDriveLetter is the supported way
#                                   to ask for it; diskpart spells the same
#                                   thing 'attributes volume set
#                                   nodefaultdriveletter'. Automount honours it,
#                                   in WinPE as on the host.
#
# Plus the Microsoft Reserved partition Initialize-Disk creates by itself, which
# never carries a letter either. Three partitions, none of them lettered, and a
# real file written into the NTFS one before its letter is taken away - so the
# disk under test is a disk with somebody's data on it, which is the case rule 5
# is about.
#
# THE ANTI-VACUITY ASSERTION IS THEREFORE 'no drive letter' IN THE REFUSAL, and
# it is the one to read first when this file fails. The refusal text has two
# arms and only one of them is the regression:
#
#   'carries existing data on volume D (NTFS)'          the OLD arm. Worked
#                                                       before d807c60. If this
#                                                       is what came back, WinPE
#                                                       lettered the volume and
#                                                       the fixture failed, not
#                                                       the engine.
#   'on partitions HDT cannot read, because a volume    THE NEW ARM. Only
#    with no access path is not one it can list:        d807c60 can produce it.
#    partition 1 (272629760 bytes, System, no drive
#    letter), ...'
#
# ---------------------------------------------------------------------------
# WHAT RUNS, AND WHY IT IS ONE BOOT AND FOUR STEPS
# ---------------------------------------------------------------------------
#
# tests/e2e/payload/DISK-GUARD is this file's sequence and its header carries
# the reasoning. In short: Preflight, Refuse Without Wipe (no wipe key,
# continueOnError so the run carries on), Verify Untouched, Accept With Wipe.
#
# ONE BOOT, BECAUSE THE TWO LEGS MUST SEE THE SAME DISK. The refusal and the
# acceptance differ in exactly one token - wipe: true - and running them in two
# boots would put a rebuilt fixture between them. It also keeps this file at a
# WinPE boot and a minute of disk work rather than the half hour every other
# deployment suite here costs, which is the difference between a regression test
# that gets run and one that does not.
#
# THE NEGATIVE CONTROL IS NOT OPTIONAL. Rule 5 is overridable by DECLARATION,
# and a test that only proves refusal cannot tell "correctly refuses this disk"
# from "refuses every disk" - which is the failure mode a guard fix invites,
# because a wrong refusal reads exactly like the guard working.
#
# 'Verify Untouched' IS THE THIRD QUESTION AND NOTHING ELSE CAN ASK IT. A
# refusal that reported correctly and cleared the disk anyway would pass every
# assertion about the message. So the sequence re-reads the disk through the
# pre-flight AFTER the refusal and BEFORE the wipe: the three unlettered
# partitions must still be there. The host cannot answer this - the VM holds the
# VHDX - and step 4 destroys the evidence a moment later.
#
# ---------------------------------------------------------------------------
# THE SWITCH: 'HDT Lab', AND THAT IS A DELIBERATE DEVIATION WORTH STATING
# ---------------------------------------------------------------------------
#
# CLAUDE.md allows exactly two switches and calls 'HDT External' the normal one,
# because a deployment over SMB needs the LAN. THIS VM NEEDS NO NETWORK AT ALL -
# the engine, the workspace and the sequence all arrive on a content disk - so
# it takes the isolated switch, which CLAUDE.md keeps for exactly that case, and
# Deployment.E2E already uses.
#
# AND THERE IS A SECOND REASON, WHICH IS THE LOAD-BEARING ONE. WDS has been live
# on HDT External since 2026-09-02 and answers EVERY machine on that subnet -
# known and new alike, response delay 0, NoPrompt - into a zero-touch sequence
# that partitions disk 0 with wipe: true on any machine carrying a disk of 60 GB
# or more (SPIKES S27). This suite's VM carries a 64 GB disk whose contents are
# the entire experiment. Putting it on a wire where a fall-through to network
# boot silently wipes the fixture would make a green run and a red run look the
# same. The isolated switch cannot do that: it has no DHCP server, so a client
# there never gets far enough to ask.

BeforeDiscovery {
    # THE ADK, because this file builds the boot image it runs. No install.wim
    # is needed and none is staged: nothing here applies an image.
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

    # HYPER-V AND ELEVATION, WHICH THE OTHER SUITES HERE LEAVE TO build.ps1 -
    # and that is the deviation, stated. ./build.ps1 -Task e2e throws on an
    # unelevated session before Pester is ever started, so the files it runs
    # never have to ask. A bare Invoke-Pester on a developer's machine does not,
    # and on THIS project's laptop the ADK is installed - so an ADK-only guard
    # would run the whole thing unelevated and fail rather than skip. A suite
    # that needs a hypervisor says it needs a hypervisor.
    $script:discoveryHyperV = $null -ne (Get-Module -Name 'Hyper-V' -ListAvailable)
    $script:discoveryElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $script:skipDiskGuard = (-not $script:discoveryAdk) -or (-not $script:discoveryHyperV) -or (-not $script:discoveryElevated)

    if ($script:skipDiskGuard) {
        Write-Warning ("DiskGuard.E2E.Tests.ps1 is SKIPPED. It builds a boot image, builds a disk whose partitions carry no drive letter, and boots a Generation 2 VM at it - so it needs the Windows ADK with the Windows PE add-on (currently resolvable: {0}), the Hyper-V PowerShell module (present: {1}) and an elevated session (elevated: {2})." -f
            $script:discoveryAdk, $script:discoveryHyperV, $script:discoveryElevated)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:vmName = 'HDT-DiskGuard'
    $script:vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:targetPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-DiskGuard-target.vhdx'
    $script:contentPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-DiskGuard-content.vhdx'
    $script:sequenceId = 'DISK-GUARD'

    # This suite's own build root, so it cannot overwrite the artifacts another
    # E2E file built. Removed in the AfterAll.
    $script:buildRoot = 'C:\HDTLab\scratch\e2e-diskguard'
    $script:buildWorkspace = Join-Path -Path $script:buildRoot -ChildPath 'Share'
    $script:buildScratch = Join-Path -Path $script:buildRoot -ChildPath 'work'
    $script:launcherStaging = Join-Path -Path $script:buildRoot -ChildPath 'stage'

    # KEPT, because every assertion below rests on it and the VM that produced
    # it is destroyed by the AfterAll.
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e-diskguard-artifacts'

    # The marker written into the NTFS volume before its letter is taken away.
    # A disk with a file on it is the case rule 5 is about; an empty formatted
    # volume would be too.
    $script:markerName = 'HDT-DO-NOT-WIPE.txt'
    $script:markerLabel = 'HDTKEEPME'

    # THE PROTECTED PAIR, RECORDED BEFORE ANYTHING STARTS. Every VM this suite
    # does not own, as a SET and never a list of names - a name list rots, and
    # this project has already had one protect nothing for weeks after the two
    # machines it named were retired.
    $script:snapshotProtected = {
        return (Get-HDTLabProtectedVm).Protected
    }

    $script:protectedBefore = & $script:snapshotProtected

    # -- the fixture builder, on the host -----------------------------------
    #
    # THREE PARTITIONS, NOT ONE OF THEM LETTERED, ON A GPT DISK.
    #
    #   1  Reserved  the MSR. Initialize-Disk -PartitionStyle GPT creates it
    #                itself and HDT never creates one (PSD's PSDPartition.ps1
    #                does, which is how SPIKES S6 ended up with a duplicate).
    #   2  System    the ESP. Created as basic data, lettered, formatted FAT32,
    #                unlettered, THEN retyped to the EFI System GUID - a
    #                partition created directly as an ESP cannot readily be
    #                given a letter to format through, which is the same recipe
    #                Invoke-HDTDiskPartitionStep uses.
    #   3  Basic     NTFS, ~63.7 GB, a real file written into it, then
    #                NoDefaultDriveLetter set and the access path removed.
    #
    # -AssignDriveLetter AND READ IT BACK rather than naming one: a hard-coded
    # letter is a collision with whatever else this host has mounted, and the
    # failure is 'the letter is already in use' three minutes into a build.
    $script:newUnletteredDisk = {
        param([string] $Path)

        $shape = @{ Partition = @(); Marker = ''; Style = ''; Wrote = $false }

        Hyper-V\New-VHD -Path $Path -SizeBytes 68719476736 -Dynamic | Out-Null

        try {
            Mount-DiskImage -ImagePath $Path -StorageType VHDX -Access ReadWrite | Out-Null
            $number = [int] (Get-DiskImage -ImagePath $Path).Number

            # THE LAST GUARD BETWEEN THIS AND THE DEVELOPER'S OWN DISK, and the
            # same one New-HDTLabContentDisk uses. Everything below formats a
            # disk NUMBER that came out of Get-DiskImage; if that lookup ever
            # returned the wrong row - a mount that silently failed, a race with
            # another mount - this would initialise and format whichever disk is
            # in front of it. IsBoot or IsSystem means it is the machine, and
            # the answer is no whatever this code believes it mounted.
            $diskRow = @(Get-Disk | Where-Object { $_.Number -eq $number })
            Assert-HDTLabScratchDisk -Disk $(if ($diskRow.Count -eq 1) { $diskRow[0] } else { $null })

            Initialize-Disk -Number $number -PartitionStyle GPT -Confirm:$false | Out-Null

            # -- the ESP ----------------------------------------------------
            $esp = New-Partition -DiskNumber $number -Size 260MB -AssignDriveLetter
            $espLetter = [string] $esp.DriveLetter

            # SAID OUT LOUD RATHER THAN LEFT TO Format-Volume. An empty letter
            # here reaches Format-Volume as -DriveLetter '' and comes back as a
            # parameter binding error four frames down, in a BeforeAll, which is
            # reported as a mystery against every test in the file.
            if ([string]::IsNullOrWhiteSpace($espLetter)) {
                throw "the ESP partition came back with no drive letter, so it cannot be formatted through one."
            }

            Format-Volume -DriveLetter $espLetter -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Force -Confirm:$false | Out-Null

            Remove-PartitionAccessPath -DiskNumber $number -PartitionNumber ([int] $esp.PartitionNumber) `
                -AccessPath ('{0}:\' -f $espLetter) -ErrorAction Stop

            # RETYPED AFTER THE LETTER IS GONE. The GUID is the EFI System
            # partition's, and Windows will not letter one afterwards.
            Set-Partition -DiskNumber $number -PartitionNumber ([int] $esp.PartitionNumber) `
                -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -ErrorAction Stop

            # -- the data partition, which is the one with somebody's data ---
            $data = New-Partition -DiskNumber $number -UseMaximumSize -AssignDriveLetter
            $dataLetter = [string] $data.DriveLetter

            if ([string]::IsNullOrWhiteSpace($dataLetter)) {
                throw "the data partition came back with no drive letter, so the marker file cannot be written into it."
            }

            Format-Volume -DriveLetter $dataLetter -FileSystem NTFS -NewFileSystemLabel $script:markerLabel -Force -Confirm:$false | Out-Null

            $markerPath = [System.IO.Path]::Combine(('{0}:\' -f $dataLetter), $script:markerName)
            [System.IO.File]::WriteAllText($markerPath,
                ("Written by tests/e2e/DiskGuard.E2E.Tests.ps1 at {0:yyyy-MM-dd HH:mm:ss}. If HDT wiped this disk without wipe: true, DESIGN 9.1 rule 5 has regressed." -f (Get-Date)))

            $shape['Wrote'] = Test-Path -LiteralPath $markerPath -PathType Leaf
            $shape['Marker'] = $markerPath

            # THE ATTRIBUTE THAT SURVIVES INTO WinPE. GPT 0x8000000000000000.
            # Set first, access path removed second: automount honours the
            # attribute, so the letter does not come back on the next mount -
            # here or on the other side of the boot.
            Set-Partition -DiskNumber $number -PartitionNumber ([int] $data.PartitionNumber) `
                -NoDefaultDriveLetter $true -ErrorAction Stop

            Remove-PartitionAccessPath -DiskNumber $number -PartitionNumber ([int] $data.PartitionNumber) `
                -AccessPath ('{0}:\' -f $dataLetter) -ErrorAction Stop
        } finally {
            Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        }

        # READ BACK ON A FRESH MOUNT, which is the only reading worth anything:
        # the question is whether the shape survives being attached somewhere
        # else, and a disk that is lettered again here would be lettered again
        # in WinPE too.
        try {
            Mount-DiskImage -ImagePath $Path -StorageType VHDX -Access ReadOnly | Out-Null
            $number = [int] (Get-DiskImage -ImagePath $Path).Number

            $shape['Style'] = [string] (Get-Disk -Number $number).PartitionStyle
            $shape['Partition'] = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Select-Object PartitionNumber, Size, Type, GptType, DriveLetter, NoDefaultDriveLetter, Offset)
        } finally {
            Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        }

        return $shape
    }

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

    $script:shapeBefore = @{ Partition = @(); Marker = ''; Style = ''; Wrote = $false }
    $script:shapeAfter = @()
    $script:result = $null
    $script:record = @()
    $script:rawJsonl = ''
    $script:state = $null
    $script:launcherLog = ''
    $script:endedCleanly = $false
    $script:runSecond = 0

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope: reading $script:skipDiskGuard here throws
    # under StrictMode - which ./build.ps1 sets and a bare Invoke-Pester does
    # not - and without StrictMode it is worse, because 'if (-not $null)' is
    # TRUE and the whole thing runs on a machine that was supposed to skip it
    # (SPIKES S9.15).
    $script:canRun = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($script:canRun) {
        $script:canRun = $null -ne (Get-Module -Name 'Hyper-V' -ListAvailable)
    }

    if ($script:canRun) {
        try {
            [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
            [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        } catch {
            $script:canRun = $false
        }
    }

    if ($script:canRun) {

        # EMPTIED FIRST, BECAUSE YESTERDAY'S EVIDENCE READS EXACTLY LIKE
        # TODAY'S. These files are named by what they are, not by which run
        # wrote them, so a run that harvests nothing leaves the last run's
        # RESULT.json sitting there looking current. Safe to empty: this is
        # this suite's own directory under C:\HDTLab\scratch, and everything in
        # it is reproduced by the run about to start.
        if (Test-Path -LiteralPath $script:artifactRoot -PathType Container) {
            Remove-Item -LiteralPath $script:artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null

        # -- the budget, before anything is started -------------------------
        Assert-HDTLabMemoryBudget -MemoryByte 4294967296 -Name $script:vmName

        # -- the boot image, built by the product ---------------------------

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

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        # THE LAUNCHER IS Deployment.E2E's, UNCHANGED, AND THE SEQUENCE ID IS AN
        # ARGUMENT. It builds the real adapters, resolves variables and calls
        # Invoke-HDTTaskSequence exactly once - which is all this file needs -
        # and tests/unit/StartHDTLabDeploymentPayload.Tests.ps1 already holds it
        # to naming no Storage cmdlet, no DISM cmdlet and no native boot tool.
        # A launcher of this file's own would be a second copy of that, and a
        # second thing to keep honest.
        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'workspace.yaml'), @"
# Written by tests/e2e/DiskGuard.E2E.Tests.ps1.
#
# entryCommand names the SEQUENCE as well as the launcher, which is how one
# payload serves two suites. X: is the WinPE RAM disk and its letter is fixed,
# so nothing has to be scanned for and nothing has to be typed.
schemaVersion: 1
id: HDT-LAB-DISKGUARD
name: HDT disk-safety guard workspace
deployRoot: \Share
logLevel: Debug
bootImage:
  name: HDTPE_diskguard_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  extraContent:
    - source: $script:launcherStaging
      destination: \HDT
  entryCommand: powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTLabDeployment.ps1 -SequenceId $script:sequenceId
"@, $utf8NoBom)

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", $utf8NoBom)

        $bootStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $script:build = Update-HDTBootImage -WorkspaceRoot $script:buildWorkspace `
            -ScratchPath $script:buildScratch -Confirm:$false

        $bootStopwatch.Stop()
        $script:isoPath = [string] $script:build.IsoPath

        Write-Information ("boot image built in {0}s: {1}" -f
            [int] $bootStopwatch.Elapsed.TotalSeconds, $script:isoPath) -InformationAction Continue

        # -- the fixture, and the VM around it ------------------------------

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        if (Test-Path -LiteralPath $script:targetPath) {
            Remove-Item -LiteralPath $script:targetPath -Force
        }

        if (-not (Test-Path -LiteralPath $script:vmRoot -PathType Container)) {
            New-Item -Path $script:vmRoot -ItemType Directory -Force | Out-Null
        }

        $script:shapeBefore = & $script:newUnletteredDisk $script:targetPath

        foreach ($row in @($script:shapeBefore['Partition'])) {
            Write-Information ("fixture: partition {0} {1} bytes, {2}, letter '{3}', nodefaultdriveletter {4}" -f
                $row.PartitionNumber, $row.Size, $row.Type, [string] $row.DriveLetter, $row.NoDefaultDriveLetter) -InformationAction Continue
        }

        [System.IO.File]::WriteAllText(
            (Join-Path -Path $script:artifactRoot -ChildPath 'FIXTURE-BEFORE.json'),
            (ConvertTo-Json -InputObject @($script:shapeBefore['Partition']) -Depth 4), $utf8NoBom)

        # Attached first, so the target is certainly disk 0 and diskNumber: 0 in
        # the sequence names it. The content disk goes on afterwards.
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT Lab' -VhdPath @($script:targetPath) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

        $yamlModule = @(Get-Module -Name 'powershell-yaml' -ListAvailable | Sort-Object Version -Descending)[0]

        # NO install.wim AND NO OperatingSystems TREE. Nothing here applies an
        # image, so the content disk is the engine, the parser and one sequence:
        # under a gigabyte, and seconds rather than minutes to stage.
        New-HDTLabContentDisk -Path $script:contentPath -SizeByte 2147483648 -Confirm:$false -Source @{
            'HDT\Modules\Hephaestus'                          = (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus')
            'HDT\Modules\powershell-yaml'                     = [string] $yamlModule.ModuleBase
            ('Share\TaskSequences\{0}' -f $script:sequenceId) = (Join-Path -Path $script:repoRoot -ChildPath ('tests/e2e/payload/{0}' -f $script:sequenceId))
        } | Out-Null

        # rules.yaml IS WRITTEN HERE RATHER THAN COPIED FROM samples/. The
        # sample's fallback names a machine from its serial number, and a
        # Hyper-V serial is 32 characters - which is a 35-character computer
        # name, the log folder named after it, and nothing gained. This run
        # needs one variable and states it.
        try {
            Mount-DiskImage -ImagePath $script:contentPath -StorageType VHDX -Access ReadWrite | Out-Null

            $contentNumber = [int] (Get-DiskImage -ImagePath $script:contentPath).Number
            $contentLetter = @(Get-Partition -DiskNumber $contentNumber -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } | ForEach-Object { [string] $_.DriveLetter })

            if ($contentLetter.Count -lt 1) {
                throw "the content disk came back with no drive letter, so rules.yaml could not be written onto it."
            }

            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine(('{0}:\Share' -f $contentLetter[0]), 'rules.yaml'), @"
# Written by tests/e2e/DiskGuard.E2E.Tests.ps1.
#
# One variable, because this run needs one. The sample workspace's fallback
# names a machine PC-%HDTSerialNumber%, and a Hyper-V serial is 32 characters
# long - which buys a 35-character log folder and nothing else.
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: HDT-DG-01
"@, $utf8NoBom)
        } finally {
            Dismount-DiskImage -ImagePath $script:contentPath -ErrorAction SilentlyContinue | Out-Null
        }

        Hyper-V\Add-VMHardDiskDrive -VMName $script:vmName -Path $script:contentPath

        # -- boot it, and let startnet.cmd do the rest ----------------------
        #
        # NOTHING IS SENT TO THIS MACHINE. The screenshots are diagnosis, not a
        # moment the harness has to hit: a bare X:\Windows\System32> prompt in
        # one means startnet.cmd launched nothing.

        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        Start-Sleep -Seconds 120
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'diskguard-01-winpe.png') | Out-Null

        # The launcher shuts the machine down when the sequence ends, whatever
        # the outcome - so this is how the harness knows, rather than guessing
        # at a duration. Fifteen minutes is generous for a boot and two
        # partition operations; it is a timeout, not an expectation.
        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 15

        $runStopwatch.Stop()
        $script:runSecond = [int] $runStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'diskguard-02-ended.png') | Out-Null
        Write-Information ("the WinPE leg ended after {0}s (clean shutdown: {1})" -f $script:runSecond, $script:endedCleanly) -InformationAction Continue

        # -- read the evidence off the content disk -------------------------

        $harvest = & $script:readContent {
            param([string] $Drive)

            $logRoot = '{0}\Share\Logs' -f $Drive
            $answer = @{ Result = $null; Jsonl = ''; State = $null; Launcher = '' }

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

            if (-not [string]::IsNullOrWhiteSpace($script:rawJsonl)) {
                $script:record = @(($script:rawJsonl -split "`r?`n") |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ConvertFrom-Json $_ })
            }
        }

        Write-Information ("RESULT.json status: {0}" -f $(if ($null -ne $script:result) { [string] $script:result.status } else { '<absent>' })) -InformationAction Continue

        # PERSIST WHAT THE ASSERTIONS REST ON. All of it was read into memory
        # off a content disk the AfterAll destroys, so a claim about the refusal
        # could otherwise only be re-checked by re-running the whole thing.
        if ($null -ne $script:result) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'RESULT.json'),
                ($script:result | ConvertTo-Json -Depth 12), $utf8NoBom)
        }
        if ($null -ne $script:state) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'state.json'),
                ($script:state | ConvertTo-Json -Depth 12), $utf8NoBom)
        }
        if (-not [string]::IsNullOrWhiteSpace($script:rawJsonl)) {
            # Verbatim, not re-serialised: the record shape is one of the things
            # a later reader needs to check.
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'),
                $script:rawJsonl, $utf8NoBom)
        }
        if (-not [string]::IsNullOrWhiteSpace($script:launcherLog)) {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAUNCHER.log'),
                $script:launcherLog, $utf8NoBom)
        }

        # -- and the disk the last step left behind -------------------------
        #
        # The negative control's other half, read off the metal rather than out
        # of a log: a disk that was accepted for wiping is a disk that now
        # carries the layout HDT authored, and no longer carries the fixture.
        try {
            Mount-DiskImage -ImagePath $script:targetPath -StorageType VHDX -Access ReadOnly | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $script:targetPath).Number
            $script:shapeAfter = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Select-Object PartitionNumber, Size, Type, GptType, DriveLetter, Offset)

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'FIXTURE-AFTER.json'),
                (ConvertTo-Json -InputObject @($script:shapeAfter) -Depth 4), $utf8NoBom)
        } finally {
            Dismount-DiskImage -ImagePath $script:targetPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.
    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        try {
            foreach ($path in @($script:contentPath, $script:targetPath)) {
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
            Hyper-V\Stop-VM -Name 'HDT-DiskGuard' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-DiskGuard was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-DiskGuard' -Confirm:$false
        }
    }

    # THE BUILD ROOT GOES BACK: a staged WinPE tree, a mounted image, a WIM and
    # an ISO, about two gigabytes. AFTER the VM, because its DVD drive holds the
    # ISO inside this root open - and NOT when the operator asked to keep the
    # VM, since a kept VM whose ISO has been deleted is not a machine anybody
    # can debug.
    #
    # C:\HDTLab\scratch\e2e-diskguard-artifacts deliberately STAYS. It holds
    # FIXTURE-BEFORE.json, FIXTURE-AFTER.json, RESULT.json, HDT.jsonl,
    # state.json, LAUNCHER.log and the screenshots - which is everything a
    # human needs to read when this fails, off a VM that no longer exists.
    if ($env:HDT_KEEP_LAB_VM -ne '1' -and (Get-Command -Name 'Remove-HDTLabScratchTree' -ErrorAction SilentlyContinue)) {
        Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\e2e-diskguard' -Confirm:$false
    }
}

Describe 'the disk this run built for the engine to refuse' -Tag 'E2E' -Skip:$skipDiskGuard {

    # THE FIXTURE IS ASSERTED BEFORE THE BEHAVIOUR IS. Every claim below rests
    # on this disk being the shape rule 5 is about, and the ways it can quietly
    # not be - a RAW disk, a lettered volume, an empty one - each turn the whole
    # suite green while proving nothing.

    It 'is a GPT disk, because rule 5 is inert on a RAW one' {
        [string] $script:shapeBefore['Style'] | Should -BeExactly 'GPT' -Because (
            'a disk with no partition table carries no partitions, so neither arm of rule 5 can fill and the guard is not exercised at all')
    }

    It 'has three partitions' {
        @($script:shapeBefore['Partition']).Count | Should -Be 3 -Because (
            'the MSR Initialize-Disk creates, the ESP, and the NTFS volume carrying the marker')
    }

    It 'carries a Reserved, a System and a Basic partition' {
        $type = @($script:shapeBefore['Partition'] | ForEach-Object { [string] $_.Type })

        $type | Should -Contain 'Reserved'
        $type | Should -Contain 'System'
        $type | Should -Contain 'Basic'
    }

    It 'wrote a real file into the NTFS volume' {
        # A formatted volume with somebody's data on it is the case rule 5 is
        # about. An empty one would be too, but this leaves no doubt.
        $script:shapeBefore['Wrote'] | Should -BeTrue -Because ([string] $script:shapeBefore['Marker'])
    }

    It 'left not one partition carrying a drive letter' {
        # THE FIXTURE'S WHOLE POINT. A lettered volume is read by GetVolume,
        # lands in rule 5's $data arm - which worked before d807c60 - and this
        # suite then proves the old behaviour while looking green.
        $lettered = @($script:shapeBefore['Partition'] |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.DriveLetter) } |
                ForEach-Object { '{0}:{1}' -f $_.PartitionNumber, $_.DriveLetter })

        $lettered | Should -BeNullOrEmpty -Because ($lettered -join ', ')
    }

    It 'set NoDefaultDriveLetter on the data partition, which is what survives into WinPE' {
        # Removing a letter does not survive: automount would hand one back on
        # the other side. GPT attribute 0x8000000000000000 is what does.
        $basic = @($script:shapeBefore['Partition'] | Where-Object { [string] $_.Type -eq 'Basic' })

        $basic.Count | Should -Be 1
        [bool] $basic[0].NoDefaultDriveLetter | Should -BeTrue
    }
}

Describe 'the engine refused to wipe it' -Tag 'E2E' -Skip:$skipDiskGuard {

    It 'ended by shutting the machine down rather than by timing out' {
        $script:endedCleanly | Should -BeTrue -Because ('the WinPE leg ran for {0}s' -f $script:runSecond)
    }

    It 'wrote a RESULT.json' {
        $script:result | Should -Not -BeNullOrEmpty -Because $script:launcherLog
    }

    It 'was started by startnet.cmd, not by anything typed at the prompt' {
        [string] $script:result.launchedBy | Should -BeExactly 'startnet' -Because (
            'open {0}\diskguard-01-winpe.png if this fails - a bare X:\Windows\System32> prompt means startnet.cmd launched nothing' -f $script:artifactRoot)
    }

    It 'ran the sequence this file is about' {
        [string] $script:result.sequenceId | Should -BeExactly 'DISK-GUARD'
    }

    It 'saw the unlettered partitions in WinPE rather than reporting an empty disk' {
        # THE ANTI-VACUITY ASSERTION, AND THE ONE TO READ FIRST WHEN THIS FILE
        # FAILS. It is also the second half of d807c60: the pre-flight printed
        # 'no volumes' against a disk of four unlettered partitions, which is
        # HDT telling an administrator the disk is empty - the exact sentence
        # rule 5 exists to stop it saying.
        #
        # If this fails and the refusal below passes, WinPE lettered the volumes
        # and the FIXTURE is wrong: rule 5 refused through its old $data arm and
        # the regression is not covered.
        $diskRow = @($script:record |
                Where-Object { [string] $_.component -eq 'Validate' } |
                Where-Object { $null -ne $_.PSObject.Properties['data'] -and $null -ne $_.data } |
                Where-Object { $null -ne $_.data.PSObject.Properties['check'] -and [string] $_.data.check -eq 'disk 0' })

        $diskRow.Count | Should -BeGreaterThan 0 -Because 'the pre-flight writes one row per disk it considered'

        [string] $diskRow[0].data.observed | Should -Match 'no drive letter' -Because (
            'the row reports what the disk carries, and every partition on it is one HDT cannot read: {0}' -f [string] $diskRow[0].data.observed)

        [string] $diskRow[0].data.observed | Should -Not -Match 'no volumes' -Because (
            'a disk of three unlettered partitions is not an empty disk')
    }

    It 'failed the step that did not declare wipe: true' {
        [string] $script:result.failedStep | Should -BeExactly 'Refuse Without Wipe' -Because (
            'this is the one place in this repository where a failed step is the expected outcome: {0}' -f [string] $script:result.message)
    }

    It 'refused with the target-disk guard, naming the partitions it could not read' {
        # THE ASSERTION THIS FILE EXISTS FOR. Asserted on the wording rather
        # than on a non-zero exit, because a run that failed for some unrelated
        # reason would also fail - and a test that passes because something else
        # broke is worthless.
        #
        # This sentence is built in exactly one place, Get-HDTTargetDiskAssessment's
        # rule 5, and Select-HDTTargetDisk raises it as HDTUnsafeTargetError.
        $message = [string] $script:result.message

        $message | Should -Match 'disk 0' -Because $message
        $message | Should -Match 'carries existing data' -Because $message
        $message | Should -Match 'the step did not declare that it may be replaced' -Because $message
    }

    It 'refused through the arm only d807c60 can reach, not through one that worked before it' {
        # THE REGRESSION ITSELF. Rule 5 has two arms:
        #
        #   $data    'carries existing data on volume D (NTFS)' - a partition
        #            whose volume HDT read. This arm worked before d807c60.
        #   $opaque  'on partitions HDT cannot read, because a volume with no
        #            access path is not one it can list: partition 1 (272629760
        #            bytes, System, no drive letter), ...' - only the fix
        #            produces this.
        #
        # A refusal through the FIRST arm means the fixture's letters came back
        # in WinPE and the defect is still uncovered, so this asserts the second
        # arm is present AND the first is absent.
        $message = [string] $script:result.message

        $message | Should -Match 'partitions HDT cannot read' -Because $message
        $message | Should -Match 'no drive letter' -Because $message
        $message | Should -Not -Match 'on volume ' -Because (
            'a lettered volume would mean WinPE lettered the fixture and rule 5 refused through the arm that already worked: {0}' -f $message)
    }

    It 'wrote a step.fail record carrying the same refusal' {
        # THE LOG AND RESULT.json ARE TWO WITNESSES TO ONE EVENT, and they are
        # written by different code on different paths. A disagreement between
        # them is worth knowing about.
        $failed = @($script:record | Where-Object { [string] $_.event -eq 'step.fail' })

        $failed.Count | Should -BeGreaterThan 0
        ($failed | ForEach-Object { [string] $_.message }) -join ' ' |
            Should -Match 'partitions HDT cannot read'
    }

    It 'wrote nothing at all: the disk was still intact when the next step looked' {
        # THE THIRD QUESTION, AND NOTHING OUTSIDE THE RUN CAN ASK IT. A refusal
        # that reported correctly and cleared the disk anyway passes every
        # assertion above. 'Verify Untouched' is a second pre-flight, run AFTER
        # the refusal and BEFORE the wipe, and its disk row must still describe
        # the three unlettered partitions.
        $diskRow = @($script:record |
                Where-Object { [string] $_.component -eq 'Validate' } |
                Where-Object { $null -ne $_.PSObject.Properties['data'] -and $null -ne $_.data } |
                Where-Object { $null -ne $_.data.PSObject.Properties['check'] -and [string] $_.data.check -eq 'disk 0' })

        $diskRow.Count | Should -Be 2 -Because (
            'the sequence runs the pre-flight twice: once before the refusal and once after it')

        [string] $diskRow[1].data.observed | Should -Match 'no drive letter' -Because (
            'after the refusal the disk still carried the partitions it refused to replace: {0}' -f [string] $diskRow[1].data.observed)
    }
}

Describe 'and accepted the same disk when the sequence declared wipe: true' -Tag 'E2E' -Skip:$skipDiskGuard {

    # THE NEGATIVE CONTROL. Rule 5 is overridable by DECLARATION and by nothing
    # else - not by naming the disk - so a guard that refused this disk under
    # every sequence would be as wrong as one that wiped it under none. Without
    # this Describe the file above cannot tell the two apart.

    It 'completed the step that declared wipe: true' {
        $status = @($script:state.step | ForEach-Object { [string] $_.status })

        $status | Should -Be @(
            'Completed',   # 1 Preflight
            'Failed',      # 2 Refuse Without Wipe   <- the proof
            'Completed',   # 3 Verify Untouched
            'Completed')   # 4 Accept With Wipe      <- the control
    }

    It 'reported the run as Succeeded, because the one failure was tolerated' {
        # continueOnError on the refusing step is what lets step 4 run at all.
        [string] $script:result.status | Should -BeExactly 'Succeeded' -Because (
            'failed at step "{0}": {1}' -f [string] $script:result.failedStep, [string] $script:result.message)
    }

    It 'left the layout HDT authored on the disk, and not the fixture' {
        # OFF THE METAL RATHER THAN OUT OF A LOG. uefi-standard is ESP, Windows
        # and Recovery - three partitions, as Deployment.E2E records, because
        # Initialize-Disk creates no MSR inside WinPE even though it does on the
        # host (SPIKES S9.10).
        @($script:shapeAfter).Count | Should -Be 3 -Because (
            'the accepted step cleared the disk and wrote uefi-standard onto it')

        @($script:shapeAfter | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }).Count |
            Should -Be 1 -Because 'an EFI System partition the deployment created'
    }

    It 'carries the three roles uefi-standard declares, and not the fixture''s' {
        # ASSERTED ON THE GPT TYPES RATHER THAN ON DRIVE LETTERS, and the
        # difference matters on somebody else's machine: whether a mounted VHDX
        # gets a letter is the HOST's automount policy, not a fact about HDT, so
        # an assertion resting on one would be green here and red on a runner
        # with automount off - a failure that says nothing about the engine.
        #
        # A type set is host-independent, and it is also the sharper claim. The
        # RECOVERY partition is the one to look at: uefi-standard declares one
        # and the fixture had none, so it can only have arrived by HDT wiping
        # this disk and writing its own layout onto it.
        $type = @($script:shapeAfter | Sort-Object PartitionNumber | ForEach-Object { [string] $_.GptType })

        $type | Should -Be @(
            '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System
            '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'   # Basic data - Windows
            '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')  # Windows Recovery
    }

    It 'no longer carries the Microsoft Reserved partition the fixture had' {
        # THE FIXTURE'S OWN FINGERPRINT, GONE. Initialize-Disk creates an MSR on
        # the HOST - which is how the fixture acquired one - and does NOT inside
        # WinPE (SPIKES S9.10), and HDT never creates one itself. So a Reserved
        # partition here would mean this is still the disk that was refused.
        @($script:shapeAfter | Where-Object { [string] $_.Type -eq 'Reserved' }) |
            Should -BeNullOrEmpty -Because 'the fixture carried an MSR and the layout HDT writes does not'
    }
}

Describe 'the lab it ran in' -Tag 'E2E' -Skip:$skipDiskGuard {

    It 'could enumerate Hyper-V at all' {
        # The danger was never an empty protected list, it was an UNREADABLE
        # one: on a dedicated CI runner the only VMs are the ones this suite
        # creates, so an empty set is correct there and a count guard fails for
        # being correctly set up.
        (Get-HDTLabProtectedVm).Readable | Should -BeTrue -Because (
            'Hyper-V could not be enumerated, so the snapshot this suite compares against is meaningless rather than empty')
    }

    It 'left every VM it does not own exactly as it found it' {
        $after = & $script:snapshotProtected

        ($after | ConvertTo-Json -Depth 3) |
            Should -BeExactly ($script:protectedBefore | ConvertTo-Json -Depth 3)
    }

    It 'left the machine IT created powered off' {
        # THIS SUITE'S OWN VM, NOT EVERY HDT-* ON THE HOST. The lab's own WSUS
        # and WDS servers match the prefix and are supposed to be up; neither is
        # this file's business. A name the AfterAll has already removed returns
        # nothing here, which is the pass.
        $running = @(Hyper-V\Get-VM -Name $script:vmName -ErrorAction SilentlyContinue |
                Where-Object { $_.State -ne 'Off' } | ForEach-Object { [string] $_.Name })

        $running | Should -BeNullOrEmpty -Because ($running -join ', ')
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
