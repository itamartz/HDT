# M9'S EXIT CRITERION: A MACHINE THAT WAS ALREADY RUNNING WINDOWS, REPLACED
# WITHOUT ANYBODY TOUCHING ITS BOOT MEDIA.
#
# Every other file in this folder starts at a bare disk with an ISO in the DVD
# drive. This one starts at a machine somebody could have been using: Windows
# installed, BitLocker on with a TPM protector, no removable media, and a
# firmware order that names its own disk. Nothing is inserted, nothing is
# pressed, no PXE responder answers. An administrator opens the share and runs
# Scripts\Start-HDTRefresh.cmd, and an hour later the machine is a new
# installation on the same partition table.
#
# 09-VERIFICATION.md, written on 2026-09-07, records four M9 exit criteria as
# open and gives the reason for each: "Every M9 behaviour - the derivation, the
# carried type, the resume exception, the clean, the suspend, the three guards,
# the shipped template - is proven against hand-written fakes and nothing else."
# This file is the instrument those four criteria ask for, and each Describe
# below is named for the one it closes.
#
# ---------------------------------------------------------------------------
# THE SETUP PROBLEM, AND WHAT IT COSTS
# ---------------------------------------------------------------------------
#
# A Refresh needs a machine that is already deployed and already encrypted, and
# there is no way to assert your way to one. The three ways to get one:
#
#   1. DEPLOY IT HERE, in a setup phase, with HDT. Costs ~45 minutes and ~30 GB
#      of the disk before the run under test begins.
#   2. KEEP ONE FROM LAST TIME. Costs nothing per run and is worthless: a
#      starting state nobody watched being built is a starting state nobody can
#      describe, and the first thing this file has to be able to say is what the
#      machine WAS.
#   3. BUILD ONE BY HAND off the host - dism /Apply-Image onto the VHDX, an
#      answer file, bcdboot. Faster, and it invents a second deployment
#      mechanism inside a test to prove the first one works.
#
# THIS FILE TAKES (1), and 09-VERIFICATION asks for exactly that: "A Windows 11
# VM on HDT External, deployed once by HDT so it is a known-good starting
# state". TaskSequences\REFRESH-SEED is that deployment - authored in
# tests/e2e/payload/REFRESH-SEED and as short as a bootable, encrypted Windows
# can be made, because it is the setup and not the experiment.
#
# SO THIS SUITE IS ROUGHLY 100 MINUTES END TO END: ~45 for the seed, ~5 for the
# full-OS leg of the Refresh, ~30 for the WinPE leg, ~15 for the last leg, and
# the rest in restarts. That is long even for this folder - the longest file
# here is 45 minutes - and it is why this one is OPT-IN behind HDT_RUN_REFRESH
# rather than part of ./build.ps1 -Task e2e. It is the shape ApplicationRoundTrip
# already uses for the same reason.
#
# IT IS ALSO THE MOST DISK-HUNGRY FILE HERE: one 80 GB dynamic VHDX that will
# hold a deployed Windows, get encrypted, be emptied, and be written again -
# call it 45-55 GB of real allocation by the end, because BitLocker dirties
# blocks a dynamic disk would otherwise leave unallocated. Check free space
# before scheduling it; the suite refuses to start below 70 GB rather than
# filling somebody's system drive at minute forty.
#
# ---------------------------------------------------------------------------
# HOW A BOOT INTO BITLOCKER RECOVERY IS DETECTED, WHICH IS THE HARD PART
# ---------------------------------------------------------------------------
#
# THE FAILURE THIS FILE EXISTS TO CATCH WRITES NOTHING ANYWHERE. Arming a
# ramdisk boot entry changes what the TPM measured; a machine whose protectors
# were not properly suspended then stops at a firmware recovery screen asking
# for a 48-digit key. It is not a crash and not a hang: the VM is Running, the
# disk is untouched, and no log on any volume gains a line - because the thing
# that would have written one never started.
#
# SO IT CANNOT BE DETECTED BY READING A LOG, AND WAITING FOR THE MACHINE TO
# POWER OFF CANNOT TELL IT FROM ANYTHING ELSE. A timeout at 90 minutes says
# "something went wrong" and is the same answer for a recovery screen, a WinPE
# that never launched its payload, and an apply that stalled.
#
# THE DISCRIMINATOR IS PROGRESS ON THE SHARE, WATCHED WHILE IT HAPPENS. After
# the launcher restarts the machine, one of three things is true within a few
# minutes:
#
#   the WinPE leg started      Logs\<name>-<runid>\ gains records whose phase is
#                              WinPE. Only an engine running in WinPE writes
#                              those, so their existence IS the criterion.
#   the machine came back to   the integration-services heartbeat returns.
#   Windows instead            WinPE never reports one, so a heartbeat here
#                              means the one-shot entry was not consumed.
#   the machine reached        no heartbeat AND no new record, indefinitely,
#   neither                    with the VM still Running. That is the recovery
#                              screen's signature, and the screenshot taken at
#                              the moment the watch gives up is what a human
#                              reads to confirm it.
#
# $script:watchForWinPe below is that watch, and it returns WHICH of the three
# happened rather than a boolean - so the failure message names the state
# instead of reporting a timeout.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE WRITES ON THE REAL SHARE, AND NOTHING ELSE
# ---------------------------------------------------------------------------
#
#   TaskSequences\REFRESH-SEED\    this file's own, refreshed from its payload
#   TaskSequences\REFRESH-E2E\     the SHIPPED refresh.yaml, spliced to a new id
#   Control\machines\<UUID>.yaml   keyed to a VM that exists only for this run
#
# TaskSequences\REFRESH IS NEVER TOUCHED. It was spliced onto this share by
# hand and the rest of that file is somebody's edits (CLAUDE.md rule 8). This
# file deploys a COPY of the shipped template under its own id, for the same
# reason CapturedImageDeployment owns REF-DEPLOY: refreshing a sequence this
# file authored destroys nobody's work.
#
# AND THE COPY IS SPLICED, NEVER RE-SERIALISED. src\Hephaestus\Templates\
# refresh.yaml is read as text and two lines are rewritten - the id and the
# name. Round-tripping it through a YAML parser would drop every comment in it,
# and refresh.yaml is more comment than document on purpose. What runs on the
# machine is therefore the shipped template, which is what the criterion is
# about; a hand-written copy under tests/e2e/payload would drift from it and
# pass anyway.
#
# ---------------------------------------------------------------------------
# HOW THE RUN IS STARTED
# ---------------------------------------------------------------------------
#
# NOTHING IS TYPED AT THE MACHINE, and tests/contract/NoKeystroke.Contract.Tests.ps1
# is what keeps that true of this file as of every other one here. A Refresh has
# no boot image to start it, so the administrator IS the launch mechanism -
# Start-HDTRefresh.cmd, run elevated from the share, which is MDT's
# Scripts\LiteTouch.vbs and is documented as such in Get-HDTRefreshLaunchPlan.
#
# THE HARNESS PLAYS THE ADMINISTRATOR OVER POWERSHELL DIRECT. That is VMBus, not
# a console and not a network: the harness opens a session as the machine's own
# local Administrator and starts the shipped .cmd, exactly as a person standing
# at it would. It is the same channel CLAUDE.md already uses to reach OSDTEST01.
#
# AND THE GUEST IS WHAT PROVES IT. The .cmd sets HDT_LAUNCHED_BY=refresh and
# nothing else in HDT sets that value; Start-HDTDeployment.ps1 records it in
# RESULT.json as launchedBy. A run started any other way - a typed command, a
# boot image, a scheduled task - does not carry it.
#
# RESULT.json IS SNAPSHOTTED WHILE THE RUN GOES, WHICH IS NOT OPTIONAL HERE.
# It lives at Logs\RESULT.json, one file, and every leg overwrites it: leg 2 is
# launched by startnet.cmd and leg 3 by the autologon, so the copy that survives
# to the end does NOT say 'refresh'. The watch below keeps every distinct
# version it sees, and the assertion is on the FIRST one - the leg the
# administrator started.
#
# ---------------------------------------------------------------------------
# THREE PLACES THIS IS EXPECTED TO FAIL FIRST, WRITTEN DOWN BEFORE THE RUN
# ---------------------------------------------------------------------------
#
# A prediction made after the fact is a diagnosis; made before it, it is a test
# of whether the reasoning was right.
#
#   1. THE SUSPEND. 09-VERIFICATION calls it "the criterion most likely to fail
#      on first contact with hardware". New-HDTBitLockerService's Suspend method
#      has never run against a TPM of any kind.
#   2. HDTSystemVolume: S ON THE WinPE LEG. refresh.yaml declares S because
#      uefi-standard lays the ESP out with that letter, and REFRESH-SEED uses
#      that layout so the machine genuinely has one. But drive letters live in
#      the assigning OS's MountedDevices, not on the disk - a freshly booted
#      WinPE assigns its own, and it does not give the ESP a letter at all. If
#      Configure Boot refuses "S: names no volume", the finding is refresh.yaml's
#      and its own comment already half predicts it: "A MACHINE PARTITIONED BY
#      SOMETHING ELSE VERY LIKELY DOES NOT [answer to S]".
#   3. HDTOSVolume: C ON THE WinPE LEG, for the same reason from the other end.
#      C: is the volume Windows ran from; in WinPE the first fixed NTFS volume
#      usually gets C:, which on this single-disk machine is the same one - but
#      "usually" is doing work there, and CleanVolume empties whatever it is
#      handed.
#
# None of the three is worked around here. A harness that pinned the letters
# would ship a template that only works when a test fixes it up.
#
# ---------------------------------------------------------------------------
# LAB SAFETY
# ---------------------------------------------------------------------------
#
# One VM, named HDT-M9-Refresh, Generation 2, files under C:\HDTLab\vms, on
# 'HDT External' because the deployment reads its image off the share over SMB.
# Created and destroyed through New-/Remove-HDTLabVirtualMachine, which stamp
# and refuse. Every VM outside HDT-* is enumerated before anything starts and
# asserted identical afterwards, in an AfterAll that runs even when the test
# failed - a set, never a list of names.

# THE TWO ANALYZER SUPPRESSIONS THIS FILE NEEDS, AND WHY EACH IS HONEST.
#
# THE PASSWORD IS MINTED HERE, FOR ONE MACHINE, AND DIES WITH IT. A Refresh is
# started by an administrator logged on to the machine, so the harness has to be
# able to log on to it - and the machine's local Administrator password is
# whatever the deployment that built it was told to set. This file generates a
# random one per run, writes it into the per-machine override the run reads, and
# deletes that override afterwards. The alternatives were reading the lab's own
# HDTAdminPassword, which spreads a real credential into a test, and writing one
# down here, which puts it in git.
#
# THE CONVERSION IS THE ONLY WAY TO HAND IT OVER, exactly as
# tests/e2e/payload/AD-DC-2025/Install-LabForest.ps1 says of the same rule:
# Invoke-Command -VMName takes a PSCredential, a PSCredential takes a
# SecureString, and the value exists as a string because the YAML document the
# engine reads is text. It is never written outside C:\HDTLab\Share's override
# file, and one of the assertions below is that it appears in no log the run
# produced - which is the redaction rule tested on a value only this run knows.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Invoke-Command -VMName needs a PSCredential for a password this run generated for a throwaway VM; the value is asserted absent from every log the run wrote.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'The scriptblock parameters carry a per-run VM password and the deployment account secret Get-HDTShareCredential decoded, both as the strings net.exe and the YAML override require.')]
param()

BeforeDiscovery {
    $script:shareRoot = 'C:\HDTLab\Share'

    # THE LAUNCHER IS A PRECONDITION AND NOT AN ASSUMPTION. New-HDTWorkspace
    # seeds Scripts\ from Templates\Launcher, and it never overwrites an
    # existing share (DESIGN 11.2) - so a share created before the launcher
    # existed does not have one, and this lab's share is exactly that share.
    # Splicing it on is a step somebody has to take, and this says so by name
    # rather than failing later with "the plan could not be read".
    $script:discoveryShare     = Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf
    $script:discoveryLauncher  = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Scripts\Start-HDTRefresh.cmd') -PathType Leaf
    $script:discoveryIso       = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Boot\HDTPE_x64.iso') -PathType Leaf
    $script:discoveryCatalog   = Test-Path -LiteralPath (Join-Path $script:shareRoot 'OperatingSystems\Win11-LTSC-2024\os.yaml') -PathType Leaf
    $script:discoveryCredential = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Control\share-credential.json') -PathType Leaf
    $script:discoveryOptIn     = ($env:HDT_RUN_REFRESH -eq '1')

    $script:skipRefresh = (-not $script:discoveryOptIn) -or (-not $script:discoveryShare) -or
        (-not $script:discoveryLauncher) -or (-not $script:discoveryIso) -or
        (-not $script:discoveryCatalog) -or (-not $script:discoveryCredential)

    if ($script:skipRefresh) {
        Write-Warning ("Refresh.E2E.Tests.ps1 is SKIPPED. It is OPT-IN and takes about 100 minutes and 50 GB: set HDT_RUN_REFRESH=1 (set: {0}). It also needs C:\HDTLab\Share (present: {1}), the full-OS launcher at Share\Scripts\Start-HDTRefresh.cmd, which New-HDTWorkspace seeds and an EXISTING SHARE NEVER ACQUIRES ON ITS OWN (present: {2}), a built boot image at Share\Boot\HDTPE_x64.iso for the seed deployment (present: {3}), the Win11-LTSC-2024 catalog entry refresh.yaml names (present: {4}), and the deployment account's secret at Share\Control\share-credential.json, which Set-HDTShareCredential writes (present: {5})." -f
            $script:discoveryOptIn, $script:discoveryShare, $script:discoveryLauncher,
            $script:discoveryIso, $script:discoveryCatalog, $script:discoveryCredential)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:shareRoot      = 'C:\HDTLab\Share'
    $script:seedSequenceId = 'REFRESH-SEED'
    $script:sequenceId     = 'REFRESH-E2E'
    $script:computerName   = 'HDT-M9-REF01'

    $script:vmName       = 'HDT-M9-Refresh'
    $script:vmRoot       = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath   = Join-Path -Path $script:vmRoot -ChildPath ('{0}-osdisk.vhdx' -f $script:vmName)
    $script:isoPath      = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:launcherPath = Join-Path -Path $script:shareRoot -ChildPath 'Scripts\Start-HDTRefresh.cmd'
    $script:templatePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/refresh.yaml'
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e-refresh'

    # EMPTIED FIRST, BECAUSE YESTERDAY'S EVIDENCE READS EXACTLY LIKE TODAY'S.
    #
    # These files are named by what they are - RESULT-01.json, state-01.json,
    # LAYOUT-BEFORE.json - not by which run wrote them, so a run that captures
    # nothing leaves the previous run's file sitting there looking current. On
    # 2026-09-11 this directory held a RESULT-01.json from 22:12 and a
    # state-01.json from 18:53 while a run at 02:34 was being diagnosed from
    # them. That is the same stale-artifact fault the watch itself had twice,
    # one level out.
    #
    # SAFE TO EMPTY: this is the suite's own directory under C:\HDTLab\scratch,
    # created by this file and removed by it, and every artifact in it is
    # reproduced by the run that is about to start.
    if (Test-Path -LiteralPath $script:artifactRoot -PathType Container) {
        Remove-Item -LiteralPath $script:artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null

    # -- THE PROTECTED SET, RECORDED BEFORE ANYTHING STARTS ----------------
    #
    # Every VM this suite does not own, as a SET and never a list of names - a
    # name list rots, and when it does the comparison silently becomes
    # empty-against-empty and holds while checking nothing (SPIKES S9.14). The
    # unfiltered read inside Get-HDTLabProtectedVm is the one exception
    # PROJECT.md rule 1 allows: you cannot prove you left the other VMs alone
    # without listing them.
    $script:snapshotProtected = { return (Get-HDTLabProtectedVm).Protected }
    $script:protectedBefore = & $script:snapshotProtected

    $script:shareContentBefore = @(
        foreach ($area in 'TaskSequences', 'Captures', 'OperatingSystems', 'Applications') {
            $root = Join-Path -Path $script:shareRoot -ChildPath $area
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                    ForEach-Object { '{0}\{1}' -f $area, $_.Name }
            }
        }
    ) | Sort-Object

    # -- READING A PARTITION TABLE OFF A VHDX THAT IS NOT RUNNING ----------
    #
    # ONE READER, TWO SUBJECTS - the disk before the Refresh and the same disk
    # after it - because two readers would be comparing two different questions.
    # The criterion is "same layout, same identifiers", so what is captured is
    # the identifiers: the disk's own GUID, and each partition's type GUID,
    # unique GUID, offset and size. A Refresh empties the volume by DELETION and
    # touches no partition, so every one of those numbers must survive it.
    #
    # THE OS VOLUME IS ENCRYPTED AND THAT DOES NOT MATTER. BitLocker encrypts
    # the CONTENTS of a volume; the GPT and the partition entries are outside
    # it, so a locked volume reads its layout back exactly as an unlocked one
    # does. Nothing here opens the filesystem.
    #
    # READ-ONLY, BECAUSE THIS IS EVIDENCE. Attaching a VHDX read-write to read
    # it would let Windows write a recovery record or a letter assignment to the
    # very table under comparison.
    $script:readDiskLayout = {
        param([string] $VhdPath)

        $answer = [ordered] @{ Read = $false; Disk = $null; Partition = @() }

        try {
            # -NoDriveLetter, AND IT IS THE HOST'S PEACE AND QUIET.
            #
            # Mounting the guest's VHDX puts ITS volumes on the developer's own
            # machine, and Windows greets a new fixed data drive by offering to
            # BitLocker it. On 2026-09-10 that put a dialog on the user's desktop
            # in the middle of a run - "BitLocker could not be enabled. The data
            # drive specified is not set to automatically unlock on the current
            # computer ... D: was not encrypted." Harmless, because the mount is
            # ReadOnly and the attempt failed, and completely unacceptable as a
            # thing a test suite does to somebody's session.
            #
            # NOTHING HERE WANTS A LETTER ANYWAY. Get-Partition reads offsets,
            # sizes and GUIDs off the disk number; a path is only needed by the
            # OTHER mount below, the one that opens files inside the deployed
            # Windows.
            Mount-DiskImage -ImagePath $VhdPath -StorageType VHDX -Access ReadOnly -NoDriveLetter | Out-Null
            $number = [int] (Get-DiskImage -ImagePath $VhdPath).Number

            $disk = Get-Disk -Number $number -ErrorAction Stop
            $answer['Disk'] = [ordered] @{
                Guid              = [string] $disk.Guid
                PartitionStyle    = [string] $disk.PartitionStyle
                NumberOfPartitions = [int] $disk.NumberOfPartitions
                Size              = [long] $disk.Size
            }

            # Sorted by offset, not by the order the provider happens to
            # enumerate them, so the comparison is of a disk and not of a
            # listing.
            $answer['Partition'] = @(
                Get-Partition -DiskNumber $number -ErrorAction Stop |
                    Sort-Object -Property Offset |
                    ForEach-Object {
                        [ordered] @{
                            PartitionNumber = [int] $_.PartitionNumber
                            Offset          = [long] $_.Offset
                            Size            = [long] $_.Size
                            Type            = [string] $_.Type
                            GptType         = [string] $_.GptType
                            Guid            = [string] $_.Guid
                        }
                    })

            $answer['Read'] = $true
        } catch {
            Write-Warning ("could not read the partition table of '{0}': {1}" -f $VhdPath, $_.Exception.Message)
        } finally {
            Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null
        }

        return $answer
    }

    # -- READING A FILE OFF THE DEPLOYED VOLUME, AFTER THE MACHINE IS OFF ---
    #
    # The OS volume is found by looking for Windows\System32 rather than by
    # partition number: the UEFI layout puts an ESP and a recovery partition on
    # the same disk, and the letters Windows hands a mounted VHDX are not the
    # ones the machine used.
    #
    # $_.DriveLetter AND NOT [string]::IsNullOrWhiteSpace ON IT. A partition
    # with no letter reports DriveLetter as [char] 0, and [string] [char] 0 is a
    # one-character string holding NUL - not null, not white space - so the
    # guard passes and the candidate becomes ' :\'. [char] 0 is falsy, which is
    # what this relies on. Every path below is built with -f rather than
    # Join-Path for the reason CLAUDE.md gives.
    $script:readDeployedFile = {
        param([string] $VhdPath, [string[]] $Relative)

        $answer = @{ OsRoot = ''; File = @{} }
        foreach ($item in @($Relative)) { $answer['File'][$item] = '' }

        try {
            Mount-DiskImage -ImagePath $VhdPath -StorageType VHDX -Access ReadOnly | Out-Null
            $number = [int] (Get-DiskImage -ImagePath $VhdPath).Number

            $candidate = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter })

            foreach ($partition in $candidate) {
                if (Test-Path -LiteralPath ('{0}:\Windows\System32' -f $partition.DriveLetter) -PathType Container) {
                    $answer['OsRoot'] = '{0}:\' -f $partition.DriveLetter
                    break
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($answer['OsRoot'])) {
                foreach ($item in @($Relative)) {
                    $full = '{0}{1}' -f $answer['OsRoot'], $item
                    if (Test-Path -LiteralPath $full -PathType Leaf) {
                        $answer['File'][$item] = [System.IO.File]::ReadAllText($full)
                    }
                }
            }
        } catch {
            Write-Warning ("could not read the deployed volume on '{0}': {1}" -f $VhdPath, $_.Exception.Message)
        } finally {
            Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null
        }

        return $answer
    }

    # -- THE WATCH THAT TELLS A RECOVERY SCREEN FROM A DEPLOYMENT -----------
    #
    # See the header. This returns WHICH of three things happened after the
    # launcher restarted the machine, never a boolean, because the whole value
    # of it is in naming the state:
    #
    #   'WinPE'     records whose phase is WinPE appeared on the share. Only an
    #               engine running inside WinPE writes one, so this IS the
    #               criterion "the boot after the arm reached WinPE".
    #   'FullOS'    the integration-services heartbeat came back without any
    #               WinPE record ever appearing. WinPE carries no integration
    #               services and never reports one, so the machine booted
    #               Windows again - the one-shot entry was not consumed.
    #   'Neither'   no heartbeat and no record, with the VM still Running, until
    #               the deadline. That is what a firmware recovery prompt looks
    #               like from outside, and it is the state this file was written
    #               to be able to report.
    #   'Off'       the machine powered itself off, which at this point means
    #               the run ended before it ever reached the second leg.
    #
    # IT ALSO KEEPS EVERY DISTINCT RESULT.json IT SEES, because Logs\RESULT.json
    # is one file that all three legs overwrite and the one the administrator
    # started is the FIRST.
    # $Since IS WHAT MAKES ANY OF THIS AN OBSERVATION RATHER THAN A COINCIDENCE.
    #
    # THE SEED DEPLOYMENT IS THIS FILE'S OWN, IT USES THIS COMPUTER NAME, AND IT
    # RAN IN WinPE. So by the time the launcher is armed the share already holds
    # a folder full of records whose phase is WinPE - written by the setup, not
    # by the run under test. Reading the newest folder and looking for a WinPE
    # record therefore answered "yes" on the first iteration, in ZERO seconds,
    # every time.
    #
    # THAT IS EXACTLY THE FALSE PASS 09-VERIFICATION WARNED ABOUT. On
    # 2026-09-10 this watch reported "WinPE after 0s (176 WinPE records)" for a
    # machine that had never left the full OS - the launcher had died on a
    # module import before the engine started - and the three assertions
    # downstream all went green on the seed's evidence. A recovery prompt would
    # have passed identically, which is the one outcome this file exists to
    # catch.
    #
    # SO NOTHING THAT EXISTED BEFORE THE ARM COUNTS. Not a folder, not a
    # RESULT.json. Logs\RESULT.json is a single file every leg of every run
    # overwrites, and the one on this share was ten days old and belonged to a
    # different machine running a different sequence - it was being captured as
    # this run's first result.
    $script:watchForWinPe = {
        param([string] $Name, [string] $LogRoot, [string] $ComputerName, [int] $Minute, [string] $ArtifactRoot,
            [datetime] $Since)

        $deadline = (Get-Date).AddMinutes($Minute)
        $resultPath = Join-Path -Path $LogRoot -ChildPath 'RESULT.json'

        $answer = [ordered] @{
            Outcome    = 'Neither'
            RunFolder  = ''
            WinPeCount = 0
            Result     = New-Object -TypeName System.Collections.ArrayList
            State      = New-Object -TypeName System.Collections.ArrayList
            Seconds    = 0
        }

        $seenResult = ''
        $seenState = ''
        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        while ((Get-Date) -lt $deadline) {

            # -- RESULT.json, every version of it --------------------------
            # WRITTEN SINCE THE ARM, OR IT IS SOMEBODY ELSE'S. See $Since above:
            # this is one file, shared by every run this share has ever hosted.
            $resultIsOurs = $false
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                try { $resultIsOurs = ((Get-Item -LiteralPath $resultPath).LastWriteTimeUtc -gt $Since) }
                catch { $resultIsOurs = $false }
            }

            if ($resultIsOurs) {
                $text = ''
                try { $text = [System.IO.File]::ReadAllText($resultPath) } catch { $text = '' }

                if ((-not [string]::IsNullOrWhiteSpace($text)) -and ($text -ne $seenResult)) {
                    $seenResult = $text
                    [void] $answer['Result'].Add($text)
                    [System.IO.File]::WriteAllText(
                        (Join-Path -Path $ArtifactRoot -ChildPath ('RESULT-{0:d2}.json' -f $answer['Result'].Count)), $text)
                }
            }

            # -- the run folder this launch produced ------------------------
            #
            # Copy-HDTLog writes Logs\<ComputerName>-<RunId>\. Newest wins: the
            # share may hold folders from earlier runs of this same file, and
            # the one being written now is the one whose LastWriteTime moves.
            # BOTH LAYOUTS, AND ONLY FOLDERS CREATED SINCE THE ARM.
            #
            # The engine logs LIVE to Logs\<name>\run-<id>\ and copies the same
            # run back to Logs\<name>-<id>\ when the leg ENDS. This watched only
            # the copy-back, which is the one that does not exist yet while the
            # leg it is waiting for is running - so the only folder it could
            # ever find was the seed's, finished minutes earlier. The live one
            # is where a WinPE record appears WHILE WinPE is up, which is the
            # signal this function is named for.
            $candidate = @(Get-ChildItem -LiteralPath $LogRoot -Directory -Filter ('{0}-*' -f $ComputerName) -ErrorAction SilentlyContinue)

            $liveRoot = Join-Path -Path $LogRoot -ChildPath $ComputerName
            if (Test-Path -LiteralPath $liveRoot -PathType Container) {
                $candidate += @(Get-ChildItem -LiteralPath $liveRoot -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)
            }

            $folder = @($candidate |
                    Where-Object { $_.CreationTimeUtc -gt $Since } |
                    Sort-Object LastWriteTime -Descending)

            if ($folder.Count -ge 1) {
                $answer['RunFolder'] = [string] $folder[0].FullName

                $statePath = Join-Path -Path $folder[0].FullName -ChildPath 'state.json'
                if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                    $text = ''
                    try { $text = [System.IO.File]::ReadAllText($statePath) } catch { $text = '' }

                    if ((-not [string]::IsNullOrWhiteSpace($text)) -and ($text -ne $seenState)) {
                        $seenState = $text
                        [void] $answer['State'].Add($text)
                        [System.IO.File]::WriteAllText(
                            (Join-Path -Path $ArtifactRoot -ChildPath ('state-{0:d2}.json' -f $answer['State'].Count)), $text)
                    }
                }

                $jsonlPath = Join-Path -Path $folder[0].FullName -ChildPath 'HDT.jsonl'
                if (Test-Path -LiteralPath $jsonlPath -PathType Leaf) {
                    $raw = ''
                    try { $raw = [System.IO.File]::ReadAllText($jsonlPath) } catch { $raw = '' }

                    $winpe = @(($raw -split "`r?`n") | Where-Object { $_ -like '*"phase":"WinPE"*' -or $_ -like '*"phase": "WinPE"*' })
                    $answer['WinPeCount'] = $winpe.Count

                    if ($winpe.Count -gt 0) {
                        $answer['Outcome'] = 'WinPE'
                        break
                    }
                }
            }

            # -- and what the machine itself is doing -----------------------
            $vm = @(Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue)

            if ($vm.Count -eq 1) {
                if ([string] $vm[0].State -eq 'Off') {
                    $answer['Outcome'] = 'Off'
                    break
                }

                $status = ''
                try {
                    $service = @(Hyper-V\Get-VMIntegrationService -VMName $Name -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -eq 'Heartbeat' })
                    if ($service.Count -eq 1 -and $null -ne $service[0].PrimaryStatusDescription) {
                        $status = [string] $service[0].PrimaryStatusDescription
                    }
                } catch {
                    $status = ''
                }

                # A HEARTBEAT ONLY COUNTS AFTER THE MACHINE HAS ACTUALLY LEFT.
                # Leg 1 runs in the full OS and reports one the whole time it is
                # staging the WinPE, so a naive read here would announce 'FullOS'
                # a second after the launch. The gate is that the heartbeat has
                # been ABSENT at least once - which is the restart - before its
                # return means anything.
                if ($status -like 'Ok*') {
                    if ($answer['Outcome'] -eq 'Restarted') { $answer['Outcome'] = 'FullOS'; break }
                } else {
                    if ($answer['Outcome'] -eq 'Neither') { $answer['Outcome'] = 'Restarted' }
                }
            }

            Start-Sleep -Seconds 10
        }

        $watch.Stop()
        $answer['Seconds'] = [int] $watch.Elapsed.TotalSeconds

        # 'Restarted' is an interior state and never an answer: reaching the
        # deadline in it means the machine went away and never came back, which
        # is exactly the mute failure this watch exists to name.
        if ($answer['Outcome'] -eq 'Restarted') { $answer['Outcome'] = 'Neither' }

        return $answer
    }

    # -- everything the assertions read, declared before it can be set ------
    $script:overrideFile     = ''
    $script:vmUuid           = ''
    $script:adminPassword    = ''
    $script:freeGb           = 0
    $script:seededCleanly    = $false
    $script:seedSecond       = 0
    $script:layoutBefore     = $null
    $script:layoutAfter      = $null
    $script:bitLockerBefore  = ''
    $script:protectionBefore = ''
    $script:tpmBefore        = ''
    $script:bootedForRefresh = $false
    $script:dvdCount         = -1
    $script:bootOrder        = @()
    $script:launchOutput     = ''
    $script:launchStarted    = $false
    $script:watch            = $null
    $script:refreshEnded     = $false
    $script:refreshSecond    = 0
    $script:record           = @()
    $script:rawJsonl         = ''
    $script:resultFirst      = $null
    $script:stateDocument    = @()
    $script:deployed         = @{ OsRoot = ''; File = @{} }
    $script:offlineName      = ''
    $script:sequenceText     = ''

    # RECOMPUTED HERE, NOT READ FROM BeforeDiscovery. Pester's discovery and run
    # phases do not share a scope, and reading $script:skipRefresh here throws
    # under StrictMode - which ./build.ps1 sets and a bare Invoke-Pester does
    # not. Without StrictMode it is worse: the read is $null, 'if (-not $null)'
    # is TRUE, and a 100 minute deployment runs on a machine that was supposed
    # to skip it (SPIKES S9.15).
    $script:canRun = (
        ($env:HDT_RUN_REFRESH -eq '1') -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf) -and
        (Test-Path -LiteralPath $script:launcherPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:isoPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'OperatingSystems\Win11-LTSC-2024\os.yaml') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'Control\share-credential.json') -PathType Leaf))

    if ($script:canRun) {

        # -- rule 4: the memory budget, before anything is started ----------
        Assert-HDTLabMemoryBudget -MemoryByte 4294967296 -Name $script:vmName

        # -- AND THE DISK, WHICH IS THIS FILE'S OWN LIMIT -------------------
        #
        # An 80 GB dynamic VHDX that gets deployed, encrypted, emptied and
        # deployed again will really allocate 45-55 GB, because encryption
        # dirties blocks a dynamic disk would otherwise never touch. Running out
        # at minute forty leaves a half-written machine and a full system drive;
        # refusing here costs nothing.
        $script:freeGb = [int] ([math]::Floor(
                (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB))

        if ($script:freeGb -lt 70) {
            throw ("this suite needs about 55 GB for one VM that is deployed twice, and C: has {0} GB free. Free some space or run it when the lab is quieter; a run that fills the system drive part way through leaves a half-written machine behind." -f $script:freeGb)
        }

        # -- THE TWO SEQUENCES ----------------------------------------------
        #
        # BOTH ARE THIS FILE'S OWN IDS, and TaskSequences\REFRESH is left alone
        # (see the header). New-HDTTaskSequence is what creates the folder and
        # brings the answer files across from the MODULE's Templates\; the
        # sequence.yaml it writes is then replaced, which is CapturedImageDeployment's
        # pattern for the same reason - the folder is scaffolding, the document
        # is the subject.

        $seedRoot = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $script:seedSequenceId)
        if (-not (Test-Path -LiteralPath $seedRoot -PathType Container)) {
            New-HDTTaskSequence -Workspace $script:shareRoot -Id $script:seedSequenceId `
                -Name 'Seed a machine for the Refresh e2e' -Template client -Confirm:$false | Out-Null
        }

        Copy-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath ('payload/{0}/sequence.yaml' -f $script:seedSequenceId)) `
            -Destination (Join-Path -Path $seedRoot -ChildPath 'sequence.yaml') -Force

        $refreshRoot = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $script:sequenceId)
        if (-not (Test-Path -LiteralPath $refreshRoot -PathType Container)) {
            New-HDTTaskSequence -Workspace $script:shareRoot -Id $script:sequenceId `
                -Name 'The shipped Refresh, under a test id' -Template refresh -Confirm:$false | Out-Null
        }

        # THE SHIPPED TEMPLATE, SPLICED AND NOT RE-SERIALISED. Two lines change:
        # the id, so this does not collide with the REFRESH sequence somebody
        # already has on this share, and the name, so a log naming it is
        # unambiguous. Everything else - every step, every comment, every
        # variable default including HDTSystemVolume: S - is the product's.
        # Round-tripping through a YAML parser would drop the comments, and
        # refresh.yaml is more comment than document on purpose.
        $templateText = [System.IO.File]::ReadAllText($script:templatePath)
        $script:sequenceText = $templateText `
            -replace '(?m)^id:\s*REFRESH\s*$', ('id: {0}' -f $script:sequenceId) `
            -replace '(?m)^name:\s*Standard Refresh Task Sequence\s*$', 'name: Standard Refresh Task Sequence (e2e)'

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path -Path $refreshRoot -ChildPath 'sequence.yaml'), $script:sequenceText, $utf8NoBom)

        # -- THE MACHINE ----------------------------------------------------

        Remove-HDTLabVirtualMachine -Name $script:vmName -Confirm:$false

        if (-not (Test-Path -LiteralPath $script:vmRoot -PathType Container)) {
            New-Item -Path $script:vmRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:osDiskPath) {
            Remove-Item -LiteralPath $script:osDiskPath -Force
        }

        # 80 GB dynamic. REFRESH-SEED validates minDiskGB 60, and refresh.yaml's
        # own imageSizeMB check wants the volume to be at least the image plus
        # 150 MB plus 3 GB - it measures the SIZE of the volume rather than the
        # space free on it, which is MDT's reasoning and the only one that works
        # on a machine somebody has been using.
        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 85899345920 -Dynamic | Out-Null

        # 'HDT External': the seed reads a 4.6 GB image off the share over SMB
        # and the Refresh reads it again, and a VM on the isolated switch gets
        # no lease and cannot reach a share on the host at all (SPIKES S6).
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT External' -VhdPath @($script:osDiskPath) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

        # -- THE VIRTUAL TPM, WHICH IS WHAT MAKES ANY OF THIS MEAN ANYTHING --
        #
        # A Refresh of an unencrypted machine passes the transport and proves
        # nothing about the suspend - 09-VERIFICATION calls a green run on one
        # "actively misleading". BitLocker with a TPM protector is the case
        # where an armed ramdisk boot entry changes the measurements, so it is
        # the case the criterion is about, and it needs a TPM.
        #
        # A LOCAL KEY PROTECTOR, NOT A GUARDED FABRIC. Set-VMKeyProtector
        # -NewLocalKeyProtector is the standalone-host form; the vTPM's state is
        # then sealed to this host, which is correct for a machine that exists
        # for one afternoon.
        #
        # NAME-FILTERED AND MODULE-QUALIFIED like every other Hyper-V call here.
        # PowerCLI shadows several of these cmdlets on this host (SPIKES S8).
        Hyper-V\Set-VMKeyProtector -VMName $script:vmName -NewLocalKeyProtector
        Hyper-V\Enable-VMTPM -VMName $script:vmName

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

        # -- THE PASSWORD THIS RUN'S MACHINE WILL ANSWER TO ------------------
        #
        # MINTED HERE, FOR THIS MACHINE, AND GONE WITH IT. The harness has to be
        # able to log in later - it plays the administrator who runs the
        # launcher - and the alternatives were both worse: reading the lab
        # share's own HDTAdminPassword would spread a real credential into a
        # test, and writing one down here would put it in git.
        #
        # IT IS ALSO AN ASSERTION LATER. Nothing in any log may contain it, which
        # is the redaction rule tested on a value that only this run knows.
        $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
        $random = New-Object -TypeName System.Random
        $script:adminPassword = 'Hdt9!' + (-join (1..14 | ForEach-Object { $alphabet[$random.Next(0, $alphabet.Length)] }))

        # -- THE PER-MACHINE OVERRIDE - DESIGN 3.1'S SECOND SOURCE ----------
        #
        # It beats rules.yaml, which is the whole reason this file never edits
        # the share's rules: the lab's rules pin every machine behind this
        # gateway to PNP-TEST, and nothing types a sequence id at a zero-touch
        # machine.
        #
        # HDTComputerName is set because rules.yaml's fallback names a machine
        # PC-%HDTSerialNumber% and a Hyper-V serial is 32 characters - over the
        # 15 character NetBIOS limit, which Windows Setup silently discards
        # (SPIKES S9.11).
        #
        # THE LAST TWO LINES ARE WHAT MAKES THE RUN UNATTENDED TO THE END. A
        # full-OS leg draws MDT's Finished screen and BLOCKS on it, so a run with
        # no hand in front of it would stand there for ever - a hang, which reads
        # as a timeout and diagnoses as anything at all.
        $script:writeOverride = {
            param([string] $Path, [string] $SequenceId, [string] $ComputerName, [string] $Password, [string] $Extra)

            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, @"
# Written by tests/e2e/Refresh.E2E.Tests.ps1 for this run's VM, and removed by
# its AfterAll. DESIGN 3.1 source 2, keyed on the machine's UUID.
schemaVersion: 1
variables:
  HDTComputerName: $ComputerName
  HDTTaskSequenceID: $SequenceId
  HDTAdminPassword: '$Password'
  HDTSkipFinalSummary: true
  HDTFinishAction: Shutdown
$Extra
"@, $utf8)
        }

        $script:overrideFile = Join-Path -Path $script:shareRoot -ChildPath ('Control\machines\{0}.yaml' -f $script:vmUuid)

        & $script:writeOverride $script:overrideFile $script:seedSequenceId $script:computerName $script:adminPassword ''

        # -- LEG ZERO: BUILD THE MACHINE THE REFRESH WILL REPLACE ------------
        #
        # Not evidence. Everything asserted about this deployment is asserted
        # about the STATE it left, and the only reason it is here rather than in
        # a fixture is that a starting state nobody watched being built is one
        # nobody can describe.
        $seedStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        Start-Sleep -Seconds 150
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refresh-01-seed-winpe.png') | Out-Null

        # -- THE DISC COMES OUT NOW, NOT AFTER THE SEED ----------------------
        #
        # BITLOCKER REFUSES A TPM PROTECTOR WHILE BOOTABLE MEDIA IS PRESENT:
        #
        #   BitLocker Drive Encryption detected bootable media (CD or DVD) in
        #   the computer. Remove the media and restart the computer before
        #   configuring BitLocker. (HRESULT: 0x80310030)
        #
        # Watched on 2026-09-10. The seed's own EnableBitLocker runs in its
        # FULL-OS leg, and the ISO it booted from was still in the drive - so
        # the step added a recovery password protector to C:, failed on the Tpm
        # one, and left the machine unencrypted. Removing the drive AFTER the
        # seed finished, which is where that code still lives, is far too late:
        # the step it has to be gone for has already run.
        #
        # EJECTING NOW IS SAFE BECAUSE WinPE IS ALREADY IN RAM. The machine
        # booted the ISO 150 seconds ago, boot.wim is on X:, the engine and
        # powershell-yaml are baked into it, and every file the sequence reads
        # after this comes off the share over SMB. Nothing reads the disc again.
        #
        # THE DRIVE AND NOT JUST THE DISC, AND IT COMES OUT NOW.
        #
        # Ejecting the media was enough for BitLocker but left the drive itself,
        # and removing THAT later - once the seed had powered off - failed with
        # "InvalidParameter, VirtualizationException", so the Refresh started
        # with a DVD drive still attached and the "no removable media at all"
        # criterion failed on a technicality (2026-09-10, "DVD drives attached
        # for the Refresh: 1").
        #
        # A GENERATION 2 VM TAKES SCSI HOT-REMOVE, so the whole drive can go
        # while the machine is up - and WinPE has been in RAM since it booted,
        # with every file it still needs coming off the share, so there is
        # nothing left for the drive to serve.
        # HOT-REMOVE FIRST, EJECT IF HYPER-V WILL NOT. Taking the drive out
        # satisfies both the BitLocker precondition and the "no removable media
        # at all" criterion in one go, and a Generation 2 VM normally allows it
        # while running. NORMALLY: on 2026-09-11 one run in four had Hyper-V
        # answer "unable to find a virtual machine with name HDT-M9-Refresh" to
        # this very call, on a machine that plainly existed - and that killed the
        # whole twenty-minute suite at the setup stage.
        #
        # EJECTING THE DISC IS ENOUGH FOR THE PART THAT MATTERS HERE. BitLocker
        # objects to bootable MEDIA, not to an empty drive, so the fallback still
        # lets the seed encrypt; the drive itself is removed again after the seed
        # powers off, where the criterion is asserted.
        foreach ($drive in @(Hyper-V\Get-VMDvdDrive -VMName $script:vmName -ErrorAction SilentlyContinue)) {
            try {
                Hyper-V\Remove-VMDvdDrive -VMDvdDrive $drive -ErrorAction Stop
            } catch {
                Write-Warning ("could not hot-remove the DVD drive ({0}); ejecting the disc instead, which is all BitLocker needs" -f
                    $_.Exception.Message)

                Hyper-V\Set-VMDvdDrive -VMDvdDrive $drive -Path $null -ErrorAction SilentlyContinue
            }
        }

        Write-Information ("the seed's disc was taken out while WinPE was up, so BitLocker will accept a TPM protector " +
            "in the full-OS leg (0x80310030 otherwise)") -InformationAction Continue

        $script:seededCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 90

        $seedStopwatch.Stop()
        $script:seedSecond = [int] $seedStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refresh-02-seed-ended.png') | Out-Null
        Write-Information ("the seed deployment ended after {0}s (powered off cleanly: {1})" -f
            $script:seedSecond, $script:seededCleanly) -InformationAction Continue

        if ($script:seededCleanly) {

            # -- THE PARTITION TABLE, BEFORE ----------------------------------
            #
            # Read while the machine is off and before anything else touches it.
            # This is the "before" half of the criterion, and it is CAPTURED
            # rather than expected: a Refresh must leave the table it found, and
            # asserting a shape somebody wrote down here would pass a run that
            # repartitioned into the same shape with new GUIDs.
            $script:layoutBefore = & $script:readDiskLayout $script:osDiskPath

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAYOUT-BEFORE.json'),
                ($script:layoutBefore | ConvertTo-Json -Depth 6))

            # -- NO BOOT MEDIA. THE CRITERION, MADE PHYSICAL ------------------
            #
            # The seed needed the ISO; the Refresh must not have it. Taking the
            # DVD drive away entirely rather than ejecting the disc is the
            # strongest form of "no boot media, no PXE, no F12" - there is
            # nothing left in the machine to boot from but its own disk, so a
            # run that starts at all started from the running Windows.
            foreach ($drive in @(Hyper-V\Get-VMDvdDrive -VMName $script:vmName -ErrorAction SilentlyContinue)) {
                Hyper-V\Remove-VMDvdDrive -VMDvdDrive $drive
            }

            $script:dvdCount = @(Hyper-V\Get-VMDvdDrive -VMName $script:vmName -ErrorAction SilentlyContinue).Count
            $script:bootOrder = @((Hyper-V\Get-VMFirmware -VMName $script:vmName).BootOrder |
                    ForEach-Object { [string] $_.BootType })

            Write-Information ("DVD drives attached for the Refresh: {0}; firmware boot order: {1}" -f
                $script:dvdCount, ($script:bootOrder -join ', ')) -InformationAction Continue

            # -- THE OVERRIDE, REPOINTED AT THE SHIPPED REFRESH ---------------
            #
            # HDTJoinDomain IS EMPTIED ON PURPOSE. refresh.yaml's State Restore
            # joins %HDTJoinDomain% and this share's fallback rule names the
            # lab's own domain - a machine that is not always up, and a failed
            # join with retry: 2 would fail the sequence for a reason that has
            # nothing to do with a Refresh. A workgroup is what MDT's own
            # Client.xml falls back to and it exercises the same step.
            #
            # HDTEnableBitLocker IS TRUE, and that is not tidiness. refresh.yaml
            # warns in as many words that "a share that leaves HDTEnableBitLocker
            # false will refresh an encrypted laptop into an unencrypted one" -
            # the suspend at the top of the run turned the old protectors off and
            # then the volume they protected was deleted. Turning it back on is
            # the only thing that makes the end state match the start state, and
            # the step's own wait: false means it costs seconds rather than
            # minutes here.
            & $script:writeOverride $script:overrideFile $script:sequenceId $script:computerName $script:adminPassword @'
  HDTJoinDomain: ''
  HDTJoinWorkgroup: WORKGROUP
  HDTEnableBitLocker: true
  HDTBitLockerProtector: tpm
  HDTBitLockerEscrow: none
  HDTBitLockerPin: ''
  HDTBitLockerStartupKey: ''
'@

            # -- START IT AS A MACHINE SOMEBODY IS USING ----------------------
            #
            # No media, no keystroke, no PXE. It boots its own Windows off its
            # own disk, unlocked by the TPM, and sits at a logon screen.
            Hyper-V\Start-VM -Name $script:vmName

            $script:bootedForRefresh = Wait-HDTLabVmState -Name $script:vmName -Heartbeat -TimeoutMinute 25 -SettleMinute 2

            Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refresh-03-running-windows.png') | Out-Null
            Write-Information ("the seeded machine came back up (heartbeat: {0})" -f $script:bootedForRefresh) -InformationAction Continue
        }

        if ($script:bootedForRefresh) {

            # -- THE ADMINISTRATOR'S HANDS -----------------------------------
            #
            # PowerShell Direct is VMBus: no console, no network, no keystroke.
            # It is the harness standing in for the person who would walk up to
            # this machine, open the share and run the launcher - and it is the
            # same channel CLAUDE.md uses to reach OSDTEST01.
            $secure = ConvertTo-SecureString -String $script:adminPassword -AsPlainText -Force
            $guestCredential = New-Object -TypeName System.Management.Automation.PSCredential `
                -ArgumentList ('.\Administrator', $secure)

            # -- WHAT THE MACHINE WAS, ASKED OF THE MACHINE ------------------
            #
            # manage-bde IS THE INSTRUMENT AND NOT Get-BitLockerVolume, because
            # the criterion is about protection status and manage-bde prints the
            # protectors, the percentage and the status in the one form an
            # administrator would read on a machine they cannot touch. It is
            # captured verbatim and kept.
            try {
                $before = Invoke-Command -VMName $script:vmName -Credential $guestCredential -ScriptBlock {
                    $answer = @{ Status = ''; Protection = ''; Tpm = ''; Partition = '' }

                    $answer['Status'] = (& "$env:SystemRoot\System32\manage-bde.exe" -status C: 2>&1 | Out-String)

                    try {
                        $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
                        $answer['Protection'] = [string] $volume.ProtectionStatus
                    } catch {
                        $answer['Protection'] = 'unreadable: ' + $_.Exception.Message
                    }

                    try {
                        $answer['Tpm'] = (Get-Tpm -ErrorAction Stop | Out-String)
                    } catch {
                        $answer['Tpm'] = 'unreadable: ' + $_.Exception.Message
                    }

                    $answer['Partition'] = (Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue |
                            Select-Object PartitionNumber, DriveLetter, Offset, Size, Type, Guid | Out-String)

                    return $answer
                } -ErrorAction Stop

                $script:bitLockerBefore  = [string] $before['Status']
                $script:protectionBefore = [string] $before['Protection']
                $script:tpmBefore        = [string] $before['Tpm']

                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $script:artifactRoot -ChildPath 'MANAGE-BDE-BEFORE.txt'),
                    ($script:bitLockerBefore + "`r`n" + $script:tpmBefore + "`r`n" + [string] $before['Partition']))
            } catch {
                Write-Warning ("could not read the machine's BitLocker state before the run: {0}" -f $_.Exception.Message)
            }

            # -- AND THE LAUNCH ITSELF ---------------------------------------
            #
            # THE SHARE IS AUTHENTICATED FIRST, BECAUSE THAT IS WHAT AN
            # ADMINISTRATOR HAS ALREADY DONE. Get-HDTRefreshLaunchPlan writes a
            # bootstrap document with provider Local and no credential, and its
            # own help gives the reason: "An administrator who opened the share
            # and ran the launcher has already authenticated; their session
            # holds the connection". This connects that session. Legs two and
            # three need nothing from here - the WinPE staged onto this
            # machine's disk carries the boot image's own embedded credential,
            # which is how every other suite in this folder reaches the share.
            #
            # THE CREDENTIAL COMES OFF THE SHARE, NOT OUT OF THIS FILE.
            # Get-HDTShareCredential decodes the secret Set-HDTShareCredential
            # wrote to Control\share-credential.json, on the host, as the user
            # who wrote it. Nothing here knows what it is.
            #
            # THE OUTPUT LANDS IN C:\HDT\, WHICH IS THE ONE FOLDER THAT SURVIVES.
            # CleanVolume empties the volume and deliberately keeps <volume>\HDT
            # because the run's own state and logs are there. A launcher refusal
            # written anywhere else would be deleted by the run it was
            # explaining.
            $shareCredential = Get-HDTShareCredential -WorkspaceRoot $script:shareRoot
            $deployRoot = [string] (Import-HDTWorkspaceDocument -Path (Join-Path $script:shareRoot 'workspace.yaml')).DeployRoot

            Write-Information ("launching the shipped launcher from '{0}' as '{1}'" -f
                $deployRoot, $shareCredential.UserName) -InformationAction Continue

            # THE LINE BETWEEN THE SETUP'S EVIDENCE AND THE RUN'S, taken before
            # anything is started so nothing the seed left can fall on this side
            # of it. Everything the watch will accept has to be newer than this.
            # A second of slack costs nothing and a clock that ticks between two
            # statements is not a thing worth losing a two-hour run to.
            $script:armMoment = [datetime]::UtcNow.AddSeconds(-1)

            try {
                Invoke-Command -VMName $script:vmName -Credential $guestCredential -ArgumentList @(
                    $deployRoot, [string] $shareCredential.UserName, [string] $shareCredential.Password, $script:sequenceId
                ) -ScriptBlock {
                    param([string] $Share, [string] $User, [string] $Password, [string] $SequenceId)

                    New-Item -ItemType Directory -Path 'C:\HDT' -Force | Out-Null

                    # The connection belongs to this logon session, and the
                    # process started below runs in it, so the launcher reaches
                    # the share the way the administrator who opened it does.
                    & "$env:SystemRoot\System32\net.exe" use $Share /user:$User $Password 2>&1 | Out-Null

                    $launcher = '{0}\Scripts\Start-HDTRefresh.cmd' -f $Share

                    # DETACHED, BECAUSE THE MACHINE IS ABOUT TO RESTART. The
                    # launcher hands over to Start-HDTDeployment.ps1, which
                    # reboots into the staged WinPE; waiting for it would mean
                    # waiting for a process that is killed by the restart it
                    # caused.
                    #
                    # -WorkingDirectory 'C:\' because cmd refuses a UNC path as a
                    # current directory - %~dp0 inside the .cmd still resolves to
                    # the share, which is how it finds its own .ps1.
                    Start-Process -FilePath $launcher `
                        -ArgumentList @('-SequenceId', $SequenceId) `
                        -WorkingDirectory 'C:\' `
                        -RedirectStandardOutput 'C:\HDT\refresh-launch.out' `
                        -RedirectStandardError 'C:\HDT\refresh-launch.err' `
                        -WindowStyle Hidden
                } -ErrorAction Stop

                $script:launchStarted = $true
            } catch {
                Write-Warning ("the launcher could not be started on the guest: {0}" -f $_.Exception.Message)
            }
        }

        if ($script:launchStarted) {

            # -- THE WATCH. See the header ------------------------------------
            #
            # 30 minutes from the launch: the full-OS leg gathers, validates,
            # suspends the protectors, copies ~500 MB of boot image onto this
            # machine's own disk and restarts. A WinPE record inside that window
            # is the criterion; nothing inside it is the failure this file was
            # written to be able to name.
            $refreshStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            $script:watch = & $script:watchForWinPe $script:vmName `
                (Join-Path -Path $script:shareRoot -ChildPath 'Logs') $script:computerName 30 $script:artifactRoot `
                $script:armMoment

            Write-Information ("the watch after the arm returned '{0}' after {1}s ({2} WinPE records)" -f
                $script:watch['Outcome'], $script:watch['Seconds'], $script:watch['WinPeCount']) -InformationAction Continue

            # THE PICTURE OF THE STATE, TAKEN AT THE MOMENT IT WAS DECIDED. On a
            # recovery prompt this is the only human-readable evidence there
            # will ever be: nothing was written to any volume, so there is
            # nothing else to read. Diagnosis, never assertion - no test reads a
            # pixel (SPIKES S4).
            Save-HDTLabVmScreen -Name $script:vmName `
                -Path (Join-Path -Path $script:artifactRoot -ChildPath ('refresh-04-after-arm-{0}.png' -f $script:watch['Outcome'])) | Out-Null

            # 90 minutes: an apply of a 4.6 GB image over SMB onto a volume that
            # had to be emptied first, a restart, Setup's specialize and
            # oobeSystem passes, an autologon and a third leg.
            $script:refreshEnded = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 90

            $refreshStopwatch.Stop()
            $script:refreshSecond = [int] $refreshStopwatch.Elapsed.TotalSeconds

            Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'refresh-05-ended.png') | Out-Null
            Write-Information ("the Refresh ended after {0}s (powered off cleanly: {1})" -f
                $script:refreshSecond, $script:refreshEnded) -InformationAction Continue

            # -- the evidence, off the share ----------------------------------
            $logRoot = Join-Path -Path $script:shareRoot -ChildPath 'Logs'

            # THE COPY-BACK IS NOT FINISHED WHEN THE MACHINE SAYS IT IS.
            #
            # Copy-HDTLog writes the run's folder to the share and the machine
            # then powers off, and the host sees 'Off' the moment the VM stops -
            # which can be before the last file has landed over SMB. Read then
            # and state.json is simply absent: on 2026-09-11 a run whose own log
            # showed leg 3 reporting REFRESH was scored "kept 0 state.json
            # versions", and SEVEN assertions failed about behaviour the machine
            # had plainly performed. The evidence existed; the harness had
            # looked a second early.
            #
            # SO IT WAITS FOR THE FILE, BRIEFLY AND BOUNDED. A minute is far
            # longer than an SMB copy of a few hundred kilobytes needs, and a
            # run that never produces one fails the assertions that care rather
            # than hanging here.
            $runFolder = @()
            $evidenceDeadline = (Get-Date).AddSeconds(60)

            while ((Get-Date) -lt $evidenceDeadline) {
                $runFolder = @(Get-ChildItem -LiteralPath $logRoot -Directory -Filter ('{0}-*' -f $script:computerName) -ErrorAction SilentlyContinue |
                        Where-Object { $_.CreationTimeUtc -gt $script:armMoment } |
                        Sort-Object LastWriteTime -Descending)

                if ($runFolder.Count -ge 1 -and
                    (Test-Path -LiteralPath (Join-Path -Path $runFolder[0].FullName -ChildPath 'state.json') -PathType Leaf)) {

                    break
                }

                Start-Sleep -Seconds 2
            }

            Write-Information ("evidence folder: {0}" -f $(if ($runFolder.Count -ge 1) { $runFolder[0].Name } else { '(none)' })) `
                -InformationAction Continue

            if ($runFolder.Count -ge 1) {
                $jsonlPath = Join-Path -Path $runFolder[0].FullName -ChildPath 'HDT.jsonl'
                if (Test-Path -LiteralPath $jsonlPath -PathType Leaf) {
                    $script:rawJsonl = [System.IO.File]::ReadAllText($jsonlPath)
                    $script:record = @(($script:rawJsonl -split "`r?`n") |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            ForEach-Object { ConvertFrom-Json $_ })

                    [System.IO.File]::WriteAllText(
                        (Join-Path -Path $script:artifactRoot -ChildPath 'HDT.jsonl'), $script:rawJsonl)
                }

                # THE LAST STATE DOCUMENT, ADDED TO THE ONES THE WATCH SAW. The
                # watch stopped at the first WinPE record, so the third leg's is
                # only here.
                $statePath = Join-Path -Path $runFolder[0].FullName -ChildPath 'state.json'
                if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                    [void] $script:watch['State'].Add([System.IO.File]::ReadAllText($statePath))
                }
            }

            # RESULT.json ONE LAST TIME, for the same reason.
            $resultPath = Join-Path -Path $logRoot -ChildPath 'RESULT.json'
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                [void] $script:watch['Result'].Add([System.IO.File]::ReadAllText($resultPath))
            }

            # THE FIRST ONE IS THE ADMINISTRATOR'S LEG. Every leg overwrites this
            # file; only the first was started by Start-HDTRefresh.cmd.
            if ($script:watch['Result'].Count -ge 1) {
                $script:resultFirst = ConvertFrom-Json ([string] $script:watch['Result'][0])
            }

            $script:stateDocument = @(@($script:watch['State']) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { ConvertFrom-Json $_ })

            Write-Information ("kept {0} RESULT.json versions and {1} state.json versions; first launchedBy '{2}'" -f
                $script:watch['Result'].Count, @($script:stateDocument).Count,
                $(if ($null -ne $script:resultFirst) { [string] $script:resultFirst.launchedBy } else { '<absent>' })) -InformationAction Continue
        }

        # THE OVERRIDE COMES OFF AS SOON AS THE RUN IS OVER, not in the AfterAll.
        # It has done its job - the machine read it at boot - and taking it away
        # here is what lets 'the lab is unharmed' actually OBSERVE the share
        # being clean. The AfterAll still removes it, because this line does not
        # run when something above throws.
        if ($script:overrideFile -and (Test-Path -LiteralPath $script:overrideFile -PathType Leaf)) {
            Remove-Item -LiteralPath $script:overrideFile -Force -ErrorAction SilentlyContinue
        }

        # -- THE DISK AFTER, READ THE SAME WAY IT WAS READ BEFORE -------------
        if ($script:refreshEnded) {
            $script:layoutAfter = & $script:readDiskLayout $script:osDiskPath

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAYOUT-AFTER.json'),
                ($script:layoutAfter | ConvertTo-Json -Depth 6))

            # \HDT SURVIVED THE CLEAN BY DESIGN, which is what makes the
            # launcher's own output readable at all after the volume it was
            # written to was emptied.
            $script:deployed = & $script:readDeployedFile $script:osDiskPath @(
                'HDT\refresh-launch.out', 'HDT\refresh-launch.err', 'HDT\bootstrap.json')

            $script:launchOutput = [string] $script:deployed['File']['HDT\refresh-launch.out'] + "`r`n" +
                [string] $script:deployed['File']['HDT\refresh-launch.err']

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:artifactRoot -ChildPath 'LAUNCHER.out'), $script:launchOutput)

            if (-not [string]::IsNullOrWhiteSpace([string] $script:deployed['File']['HDT\bootstrap.json'])) {
                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $script:artifactRoot -ChildPath 'bootstrap.json'),
                    [string] $script:deployed['File']['HDT\bootstrap.json'])
            }

            $script:offlineName = Get-HDTLabOfflineComputerName -VhdPath $script:osDiskPath
            Write-Information ("offline computer name after the Refresh: '{0}'" -f $script:offlineName) -InformationAction Continue
        }
    }
}

AfterAll {
    # RUNS ON FAILURE TOO.

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

    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        if ($env:HDT_KEEP_LAB_VM -eq '1') {
            Hyper-V\Stop-VM -Name 'HDT-M9-Refresh' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M9-Refresh was left in place, powered off."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M9-Refresh' -Confirm:$false
        }
    }

    # THE TWO SEQUENCES STAY ON THE SHARE. They are this file's own ids, they
    # are rewritten from source on every run, and deleting them would mean
    # building a delete target under C:\HDTLab\Share - which CLAUDE.md forbids
    # and which nothing here needs.
}

Describe 'the machine the Refresh started on' -Tag 'E2E' -Skip:$skipRefresh {

    # THE STARTING STATE IS NOT EVIDENCE OF ANYTHING HDT DID - it is the subject
    # of the experiment, and these assertions exist so that a green run below
    # cannot be a run against the wrong machine. 09-VERIFICATION's sharpest
    # sentence is about exactly this: "refreshing an unencrypted machine would
    # pass the transport and prove nothing at all about the suspend".

    It 'was deployed by HDT and powered itself off' {
        $script:seededCleanly | Should -BeTrue -Because (
            'the seed deployment went {0}s. Open {1}\refresh-02-seed-ended.png' -f
                $script:seedSecond, $script:artifactRoot)
    }

    It 'came back up on its own, with no media in the machine' {
        $script:bootedForRefresh | Should -BeTrue -Because (
            'it booted its own disk, unlocked by the TPM, with the DVD drive already removed. Open {0}\refresh-03-running-windows.png' -f $script:artifactRoot)
    }

    It 'had a TPM the Refresh could suspend against' {
        # A vTPM that is present and OWNED. Suspend-BitLocker against a machine
        # with no TPM would succeed at doing nothing, and the criterion would
        # then be measuring an empty operation.
        $script:tpmBefore | Should -Match 'TpmPresent\s*:\s*True'
        $script:tpmBefore | Should -Match 'TpmReady\s*:\s*True'
    }

    It 'was BitLocker-encrypted with protection ON before anything started' {
        # THE ONE ASSERTION THAT MAKES THE WHOLE FILE MEAN SOMETHING. Read from
        # the machine itself with manage-bde, which is what an administrator
        # would read.
        $script:protectionBefore | Should -BeExactly 'On' -Because (
            "manage-bde said: {0}" -f ($script:bitLockerBefore -replace "`r?`n", ' / '))
    }

    It 'was protected by the TPM, which is the protector that measures the boot path' {
        # A recovery password alone would unlock through a changed boot path
        # without complaint, and the criterion would be untestable. It is the TPM
        # protector that turns a badly suspended volume into a recovery prompt.
        $script:bitLockerBefore | Should -Match '(?s)Key Protectors.*TPM'
    }

    It 'was fully encrypted rather than still encrypting' {
        # REFRESH-SEED runs EnableBitLocker with wait: true for this line. A
        # percentage read mid-pass is a race, and the run it would invalidate
        # costs an hour and a half.
        $script:bitLockerBefore | Should -Match 'Percentage Encrypted:\s*100'
    }
}

Describe 'it was started from the running OS, with no boot media' -Tag 'E2E' -Skip:$skipRefresh {

    # ROADMAP M9's FIRST EXIT CRITERION: "a real machine already running Windows,
    # deployed without touching its boot media - no ISO, no PXE, no F12".

    It 'had no DVD drive at all when the run started' {
        # THE CRITERION MADE PHYSICAL. Not "the ISO was ejected" - there was
        # nothing in the machine to boot from but its own disk.
        $script:dvdCount | Should -Be 0
    }

    It 'was on the LAN switch, with no removable media to boot from' {
        # 'HDT External' is where PROJECT.md rule 3 puts PXE/WDS, so the lab's
        # HDT-WDS-01 IS on this segment and answers with NoPrompt. What makes
        # this a disk boot is the firmware boot order and the absent DVD
        # asserted above, not the absence of a responder.
        [string] (Hyper-V\Get-VMNetworkAdapter -VMName $script:vmName -ErrorAction SilentlyContinue |
                Select-Object -First 1).SwitchName | Should -BeExactly 'HDT External'
    }

    It 'wrote a RESULT.json for the leg the administrator started' {
        $script:resultFirst | Should -Not -BeNullOrEmpty -Because (
            'no RESULT.json appeared on the share at all, so the launcher never handed over. {0}\LAUNCHER.out has whatever it said' -f $script:artifactRoot)
    }

    It 'records launchedBy as refresh, which only the shipped launcher sets' {
        # THE GUEST SAYING WHO STARTED IT. Start-HDTRefresh.cmd sets
        # HDT_LAUNCHED_BY=refresh and nothing else in HDT sets that value;
        # Start-HDTDeployment.ps1 copies it into RESULT.json. A run started by a
        # boot image says 'startnet'; a hand-typed one says nothing at all.
        #
        # AND IT IS THE FIRST SNAPSHOT, NOT THE LAST. Logs\RESULT.json is one
        # file that all three legs overwrite - leg two is launched by
        # startnet.cmd - so the copy left at the end does not say this.
        [string] $script:resultFirst.launchedBy | Should -BeExactly 'refresh'
    }

    It 'resolved the share from the launcher''s own location rather than a written-down path' {
        # Get-HDTRefreshLaunchPlan derives the share from $PSScriptRoot: the
        # administrator reached \\server\Share\Scripts\ to run it, so that path
        # demonstrably works from this machine right now. The bootstrap document
        # it wrote is on the volume, kept by CleanVolume, and says so.
        $bootstrap = [string] $script:deployed['File']['HDT\bootstrap.json']

        $bootstrap | Should -Not -BeNullOrEmpty -Because 'the launcher writes it before it hands over'
        $bootstrap | Should -BeLike '*"provider":*"Local"*' -Because (
            'the session that launched it is already authenticated, which is why the plan chooses Local over Smb')
    }

    It 'derived REFRESH rather than being told it' {
        # The launcher passes no phase, no type and no -Phase to anything: a run
        # that could be told what it is could talk its way past the guard that
        # only a REFRESH unlocks (DESIGN 3.2).
        [string] $script:resultFirst.deploymentType | Should -BeExactly 'REFRESH'
    }
}

Describe 'the boot after arming reached WinPE, not recovery' -Tag 'E2E' -Skip:$skipRefresh {

    # ROADMAP M9's SECOND EXIT CRITERION, and 09-VERIFICATION's "criterion most
    # likely to fail on first contact with hardware". A machine whose protectors
    # were not properly suspended stops at a firmware recovery prompt and writes
    # NOTHING - so this is asserted from the watch that ran while it happened,
    # not from a log that a recovery screen would never have produced.

    It 'did not stop at a screen that writes nothing anywhere' {
        $script:watch['Outcome'] | Should -Not -BeExactly 'Neither' -Because (
            ("the machine restarted and then produced no heartbeat and no log record for {0}s while staying Running. That is what a BitLocker recovery prompt looks like from outside, and it is what a botched SuspendBitLocker produces. " +
             "Open {1}\refresh-04-after-arm-Neither.png - a blue firmware screen asking for a 48-digit recovery key confirms it, and {1}\MANAGE-BDE-BEFORE.txt says what the protectors were.") -f
                $script:watch['Seconds'], $script:artifactRoot)
    }

    It 'did not simply boot Windows again, which would mean the arm was not consumed' {
        # THE OTHER FAILURE THIS WATCH CAN SEE. WinPE carries no integration
        # services and never reports a heartbeat; full Windows does. A heartbeat
        # after the restart therefore means bcdedit /bootsequence did not take -
        # a different defect from the recovery one, with a different fix, and
        # indistinguishable from it in any log.
        $script:watch['Outcome'] | Should -Not -BeExactly 'FullOS' -Because (
            'the machine came back to Windows instead of the staged WinPE, so the one-shot boot entry was not consumed. Open {0}\refresh-04-after-arm-FullOS.png' -f $script:artifactRoot)
    }

    It 'reached WinPE, and the WinPE leg''s own records are the proof' {
        # THE CRITERION ITSELF. Only an engine running inside WinPE writes a
        # record whose phase is WinPE, and a machine sitting at a recovery
        # prompt has not started one.
        $script:watch['Outcome'] | Should -BeExactly 'WinPE'
        [int] $script:watch['WinPeCount'] | Should -BeGreaterThan 0
    }

    It 'suspended BitLocker before it armed anything, which is the order that matters' {
        # MDT runs "Disable BDE Protectors" immediately before it stages the
        # transport (Client.xml:85-90) and refresh.yaml keeps that position. The
        # ordered list is asserted against fakes in
        # tests/unit/RefreshTemplate.EndToEnd.Tests.ps1; this is the same claim
        # about a run that happened.
        $suspend = @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Suspend BitLocker*' })

        $arm = @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Boot into WinPE*' })

        $suspend.Count | Should -BeGreaterThan 0
        $arm.Count | Should -BeGreaterThan 0

        [datetime] $suspend[0].timestamp | Should -BeLessOrEqual ([datetime] $arm[0].timestamp) -Because (
            'arming a ramdisk boot entry changes what the TPM measured, so a suspend after it is a suspend that came too late')
    }

    It 'ended by powering the machine off rather than by timing out' {
        $script:refreshEnded | Should -BeTrue -Because (
            'the Refresh went {0}s. Open {1}\refresh-05-ended.png' -f $script:refreshSecond, $script:artifactRoot)
    }
}

Describe 'the partition table is the one it started with' -Tag 'E2E' -Skip:$skipRefresh {

    # ROADMAP M9's THIRD EXIT CRITERION. A Refresh empties the volume by
    # DELETION - DISM overlays a volume, it does not empty one - and the reason
    # the criterion asks for a before-and-after read rather than a shape is that
    # "a Refresh that quietly repartitioned looks identical from the finished
    # desktop while having destroyed the staged WinPE it needed to return
    # through" (09-VERIFICATION).

    It 'could be read on both sides, so the comparison is a comparison' {
        # THE ANTI-VACUITY GUARD. Two unreadable disks compare equal while
        # checking nothing (SPIKES S9.14).
        [bool] $script:layoutBefore['Read'] | Should -BeTrue
        [bool] $script:layoutAfter['Read'] | Should -BeTrue
        @($script:layoutBefore['Partition']).Count | Should -BeGreaterThan 1
    }

    It 'is the same disk, by its own GUID' {
        [string] $script:layoutAfter['Disk']['Guid'] |
            Should -BeExactly ([string] $script:layoutBefore['Disk']['Guid'])
    }

    It 'has the same partitions, at the same offsets, with the same identifiers' {
        # CAPTURED AND COMPARED, NEVER EXPECTED. The unique GUID of each
        # partition is what a repartition cannot preserve: a run that rebuilt
        # the same three partitions at the same offsets would mint new ones, and
        # the machine would still boot.
        ($script:layoutAfter['Partition'] | ConvertTo-Json -Depth 5) |
            Should -BeExactly ($script:layoutBefore['Partition'] | ConvertTo-Json -Depth 5) -Because (
                'compare {0}\LAYOUT-BEFORE.json with {0}\LAYOUT-AFTER.json' -f $script:artifactRoot)
    }

    It 'ran no partition step at all' {
        # THE OTHER HALF, FROM THE LOG. refresh.yaml contains no DiskPartition
        # step and the resume guard refuses one on a resumed leg for EVERY
        # deployment type without exception (Get-HDTResumeForbiddenStepType), so
        # neither the sequence nor the engine should have produced one.
        $partitioned = @($script:record | Where-Object {
                [string] $_.message -like '*DiskPartition*' -and [string] $_.event -like 'step.*' })

        $partitioned | Should -BeNullOrEmpty -Because (
            ($partitioned | ForEach-Object { [string] $_.message }) -join ' | ')
    }
}

Describe 'every leg recorded a derived REFRESH' -Tag 'E2E' -Skip:$skipRefresh {

    # ROADMAP M9's FOURTH EXIT CRITERION: "every leg's state document recorded a
    # DERIVED REFRESH, the WinPE one included". A leg that re-derived would say
    # NEWCOMPUTER - its system drive is X: exactly as a bare-metal first leg's
    # is - and would then be refused the ApplyImage that the whole run exists to
    # perform.

    It 'kept more than one state document, so "every leg" is more than one leg' {
        @($script:stateDocument).Count | Should -BeGreaterThan 1 -Because (
            'the watch keeps every distinct version of state.json it sees while the run goes')
    }

    It 'records REFRESH in every one of them' {
        $wrong = @($script:stateDocument | Where-Object { [string] $_.deploymentType -ne 'REFRESH' } |
                ForEach-Object { [string] $_.deploymentType })

        $wrong | Should -BeNullOrEmpty -Because (
            'these legs recorded something else: {0}. The state documents are in {1}\state-*.json' -f
                ($wrong -join ', '), $script:artifactRoot)
    }

    It 'derived it on the full-OS leg, from the phase' {
        # Get-HDTMachineFact records the provenance and Invoke-HDTGatherStep logs
        # it as "HDTDeploymentType = 'REFRESH' (Gather), from engine.Phase". The
        # share runs at logLevel Debug, which is where var.resolve records live.
        @($script:record | Where-Object {
                [string] $_.message -like '*HDTDeploymentType*' -and
                [string] $_.message -like '*engine.Phase*'
            }).Count | Should -BeGreaterThan 0 -Because (
                'the first leg is the one that decides, and it decides from the phase - not from anything on the disk')
    }

    It 'carried it into the WinPE leg from the checkpoint rather than re-deriving it' {
        # "from state.deploymentType" is the other half, and the sentence beside
        # it exists because an administrator reading a leg whose SystemDrive is
        # X: beside the word REFRESH needs to be told which leg decided it.
        @($script:record | Where-Object {
                [string] $_.message -like '*HDTDeploymentType*' -and
                [string] $_.message -like '*state.deploymentType*'
            }).Count | Should -BeGreaterThan 0
    }

    It 'let the resumed leg apply an image, which only a REFRESH may do' {
        # THE EXCEPTION THE CARRIED TYPE BUYS. ApplyImage is forbidden on a
        # resumed leg for every other deployment type, because a capture's would
        # destroy the machine it is capturing; a Refresh's is the step the leg
        # exists to run (Get-HDTResumePermittedStepType).
        #
        # AND A KNOWN OPEN QUESTION SITS EXACTLY HERE, ASSERTED AS THE CODE
        # BEHAVES AND NOT AS EITHER DOCUMENT DESCRIBES IT.
        # 09-VERIFICATION's first gap: DESIGN 3.2 and ROADMAP M9 both say the
        # exception keys on a value "which nothing on the disk can forge", and
        # Invoke-HDTTaskSequence.ps1:589-591 reads $state.deploymentType - the
        # state document, beside the same stepIndex the guard exists to
        # disbelieve - and hands it to the guard at :653. So a forged document
        # asserting REFRESH DOES unlock ApplyImage on a resumed leg.
        # Get-HDTResumePermittedStepType.ps1:21-52 argues the case honestly and
        # bounds the cost, and this file takes no position: it asserts what a
        # real run does. Whether the documents or the code should move is a
        # decision for a human, and it is recorded as gap 1 of that report.
        @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and
                [string] $_.message -like '*Install Operating System*'
            }).Count | Should -BeGreaterThan 0
    }
}

Describe 'the machine it left behind' -Tag 'E2E' -Skip:$skipRefresh {

    It 'is a new installation and not the old one' {
        [string] $script:deployed['OsRoot'] | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath ('{0}Windows\System32\ntoskrnl.exe' -f $script:deployed['OsRoot']) -PathType Leaf |
            Should -BeTrue -ErrorAction SilentlyContinue
    }

    It 'answers to the name this run gave it' {
        [string] $script:offlineName | Should -BeExactly $script:computerName
    }

    It 'emptied the volume by deletion and kept its own working folder' {
        # CleanVolume walks the root and deletes, keeping <volume>\HDT because
        # the run's state, its staged boot image and its logs are on the volume
        # it is emptying. The launcher's own output is in there, which is how it
        # is readable at all after the volume that held it was emptied.
        @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Clean the OS volume*'
            }).Count | Should -BeGreaterThan 0

        [string] $script:deployed['File']['HDT\bootstrap.json'] | Should -Not -BeNullOrEmpty
    }

    It 'finished the whole sequence without failing a step' {
        $failed = @($script:record | Where-Object { [string] $_.event -eq 'step.fail' } |
                ForEach-Object { [string] $_.message })

        $failed | Should -BeNullOrEmpty -Because ($failed -join ' | ')
    }

    It 'reached the third leg, inside the installation it had just applied' {
        # Tattoo writes to a live registry, so a run that reached it reached
        # Windows, autologged on and resumed - on the machine it built.
        @($script:record | Where-Object {
                [string] $_.event -eq 'step.complete' -and [string] $_.message -like '*Tattoo*'
            }).Count | Should -BeGreaterThan 0
    }

    It 'kept this machine''s password out of every log' {
        # A VALUE ONLY THIS RUN KNOWS, which is what makes the redaction rule
        # testable at all: a password from a document could have been absent
        # from the log because nothing ever read it.
        $script:adminPassword | Should -Not -BeNullOrEmpty
        $script:rawJsonl | Should -Not -BeLike ('*{0}*' -f $script:adminPassword)
        $script:launchOutput | Should -Not -BeLike ('*{0}*' -f $script:adminPassword)
    }
}

Describe 'the lab is unharmed' -Tag 'E2E' {

    It 'could read Hyper-V, so the comparison below is a comparison' {
        # THE ANTI-VACUOUS GUARD, ASKED THE RIGHT WAY. Comparing an empty
        # snapshot with an empty snapshot passes while checking nothing (SPIKES
        # S9.14). What must be proven is that the snapshot could be TAKEN - not
        # that it had rows, which is false of a dedicated CI runner whose only
        # VMs are the ones a suite creates.
        (Get-HDTLabProtectedVm).Readable | Should -BeTrue -Because (
            'Hyper-V could not be enumerated, so the snapshot this suite compares against is meaningless rather than empty')
    }

    It 'left every VM it does not own exactly as it found it' {
        $after = & $script:snapshotProtected

        ($after | ConvertTo-Json -Depth 3) |
            Should -BeExactly ($script:protectedBefore | ConvertTo-Json -Depth 3)
    }

    It 'left the machine IT created powered off' {
        # THIS SUITE'S OWN VM, NOT EVERY HDT-* ON THE HOST, and the difference
        # is the whole assertion. It used to ask whether every VM matching the
        # prefix was off, which is a claim about the lab rather than about this
        # file - and on 2026-09-07 it failed for the sole reason that the lab
        # was in use: HDT-WSUS-01 and HDT-WDS-01 are the lab's own servers, and
        # HDT-M6-DC01 is a domain controller another suite built, STAMPED, kept
        # on purpose with HDT_KEEP_LAB_VM and running a deployment at the time.
        # None of the three is this suite's business and all three are supposed
        # to be up. It passed on other days by luck.
        #
        # A suite can only be responsible for the machine it made, and a name
        # that has already been removed by the AfterAll returns nothing here -
        # which is the pass, and is what "left it powered off" means once the
        # teardown has also taken it away.
        $running = @(Hyper-V\Get-VM -Name $script:vmName -ErrorAction SilentlyContinue |
                Where-Object { $_.State -ne 'Off' } | ForEach-Object { [string] $_.Name })

        $running | Should -BeNullOrEmpty -Because ($running -join ', ')
    }

    It 'left no VHDX attached to the host' {
        if ($script:osDiskPath -and (Test-Path -LiteralPath $script:osDiskPath)) {
            $image = Get-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue
            if ($null -ne $image) { [bool] $image.Attached | Should -BeFalse }
        }
    }

    It 'removed nothing the share already held' {
        # THE CLAIM THAT SURVIVES LEAVING THIS LAPTOP. Nothing that was on the
        # share when this started may be missing when it ends. A before/after
        # SET says something about this suite; naming the sequences somebody
        # else's share happens to hold says something about the author's lab.
        $after = @(
            foreach ($area in 'TaskSequences', 'Captures', 'OperatingSystems', 'Applications') {
                $root = Join-Path -Path $script:shareRoot -ChildPath $area
                if (Test-Path -LiteralPath $root -PathType Container) {
                    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                        ForEach-Object { '{0}\{1}' -f $area, $_.Name }
                }
            }
        ) | Sort-Object

        $missing = @($script:shareContentBefore | Where-Object { $after -notcontains $_ })

        $missing | Should -BeNullOrEmpty -Because (
            'these were on the share when the run started and are gone now: ' + ($missing -join ', '))
    }

    It 'never wrote to the Refresh sequence somebody already has' {
        # TaskSequences\REFRESH was spliced onto this share by hand and the rest
        # of that file is somebody's edits (CLAUDE.md rule 8). This file deploys
        # a copy of the shipped template under its own id and leaves that one
        # alone.
        $script:sequenceId | Should -Not -BeExactly 'REFRESH'
        $script:seedSequenceId | Should -Not -BeExactly 'REFRESH'
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
