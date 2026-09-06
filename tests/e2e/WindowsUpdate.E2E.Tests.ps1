# THE WindowsUpdate STEP, AGAINST A REAL WSUS SERVER, ON A REAL MACHINE.
#
# Everything about this step can be made to look right without a server. The
# unit suite drives it against a hand-written fake that returns whatever the
# test asked for; the contract asserts the real Microsoft.Update.Session adapter
# has the same shape as that fake. Neither can answer the only question that
# matters: DOES A MACHINE END UP PATCHED. A search that silently matches
# nothing, a client that quietly asks Microsoft instead of the server it was
# told to ask, an install that reports success and stages nothing - all three
# are green against a fake and all three leave an unpatched machine.
#
# WHAT MAKES THE ANSWER UNAMBIGUOUS IS THE LAB, NOT THIS FILE. The WSUS server
# is deliberately staged so that only a handful of updates are APPROVED and
# every other synced update is DECLINED. A client that comes back patched
# therefore cannot have wandered off to Microsoft Update and found something
# there: the only things on offer anywhere are the ones this lab approved, and
# the step logs which of them it saw.
#
# AND THE IMAGE IS UNPATCHED ON PURPOSE. REF-ACROBAT deploys at build
# 26100.1742, months behind. The measurement is the DIFFERENCE between the build
# the image carries and the build the machine ends on - which is why this file
# reads the starting build off the catalog rather than writing it down, and
# asserts movement rather than a fixed number. A hard-coded target build would
# fail the day the lab approves a newer cumulative, which is the wrong thing to
# be brittle about.
#
# THE REGRESSION THIS FILE EXISTS TO CATCH, BEYOND THE FEATURE ITSELF.
# WindowsUpdate is the LAST step of the sequence and it is RE-ENTRANT: it asks
# for a restart so a second pass can see what the first revealed. On 2026-09-06
# that combination stranded a real deployment. The engine asked "does any step
# AFTER this one run in the full OS?", there was no step after it at all, and
# over an empty set the answer was vacuously false - so no autologon was armed,
# nothing logged on after the reboot, pass 2 never ran, and the run sat at
# RebootPending with both updates already installed and its own log asserting
# something untrue:
#
#   no autologon was armed: every step after 'Windows Update' runs in WinPE
#
# The fix counts a re-entrant step as its own remaining work. 'it armed an
# autologon for the re-entrant last step' below is that fix's guard, and it is
# the assertion most likely to catch a real regression here.
#
# NOTHING TYPES AT THE PROMPT. HDTSkipFinalSummary and HDTFinishAction are set in
# the per-machine override so the full-OS leg powers the machine off instead of
# drawing MDT's Finished screen and blocking on it for ever - a hang, which
# reads as a timeout and diagnoses as anything at all.
#
# LAB SAFETY. Every Hyper-V call that ACTS is module-qualified and name-filtered
# to HDT-*. Every VM outside that prefix is enumerated before anything starts and
# asserted identical afterwards, in an AfterAll that runs even when the test
# failed - a set, never a list of names, because a name list rots.
#
# AND THE ISO IS EJECTED WHEN THE RUN ENDS. A VM holding the boot ISO keeps an
# open handle on it, and Update-HDTBootImage cannot then replace the file: every
# future boot image build on this share fails on the swap until somebody finds
# the machine that is holding it. That is not hypothetical - the lab's own WSUS
# server did exactly this for four days (SPIKES S24).

BeforeDiscovery {
    $script:shareRoot = 'C:\HDTLab\Share'

    $script:discoveryShare   = Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf
    $script:discoveryCatalog = Test-Path -LiteralPath (Join-Path $script:shareRoot 'OperatingSystems\REF-ACROBAT\os.yaml') -PathType Leaf
    $script:discoveryIso     = Test-Path -LiteralPath (Join-Path $script:shareRoot 'Boot\HDTPE_x64.iso') -PathType Leaf

    # THE SERVER HAS TO BE THERE, AND THE PREDICATE IS EVALUATED AT DISCOVERY -
    # never Set-ItResult inside an It, which SlowSuiteSkip.Contract enforces and
    # SPIKES S9.15 explains.
    #
    # ITS ADDRESS COMES FROM rules.yaml AND IS NOT WRITTEN DOWN HERE. The lab's
    # HDTWSUSServer is a lease like every other address in this lab; reading it
    # is how this file stays correct when the lease moves, and writing it into a
    # test is how the next person inherits a number that has quietly changed.
    $script:discoveryServer = ''
    $rulesPath = Join-Path $script:shareRoot 'rules.yaml'

    if (Test-Path -LiteralPath $rulesPath -PathType Leaf) {
        $line = @(Select-String -LiteralPath $rulesPath -Pattern '^\s*HDTWSUSServer\s*:' -ErrorAction SilentlyContinue)
        if ($line.Count -ge 1) {
            $script:discoveryServer = ([string] $line[0].Line -replace '^\s*HDTWSUSServer\s*:\s*', '').Trim().Trim("'", '"')
        }
    }

    $script:discoveryReachable = $false
    if (-not [string]::IsNullOrWhiteSpace($script:discoveryServer)) {
        try {
            $uri = [uri] $script:discoveryServer
            $probe = New-Object System.Net.Sockets.TcpClient
            $script:discoveryReachable = $probe.ConnectAsync($uri.Host, $uri.Port).Wait(4000)
            $probe.Close()
        } catch {
            $script:discoveryReachable = $false
        }
    }

    $script:skipUpdate = (-not $script:discoveryShare) -or (-not $script:discoveryCatalog) -or
        (-not $script:discoveryIso) -or (-not $script:discoveryReachable)

    if ($script:skipUpdate) {
        Write-Warning ("WindowsUpdate.E2E.Tests.ps1 is SKIPPED. It deploys a machine and patches it from the lab's WSUS, which needs C:\HDTLab\Share (present: {0}), the REF-ACROBAT catalog entry (present: {1}), a built boot image at Share\Boot\HDTPE_x64.iso (present: {2}), and HDTWSUSServer in rules.yaml answering on its port (address: '{3}', reachable: {4})." -f
            $script:discoveryShare, $script:discoveryCatalog, $script:discoveryIso,
            $script:discoveryServer, $script:discoveryReachable)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:shareRoot    = 'C:\HDTLab\Share'
    $script:sequenceId   = 'WSUS-UPDATE'
    $script:osId         = 'REF-ACROBAT'
    $script:computerName = 'HDT-M8-WSUS01'

    $script:vmName       = 'HDT-M8-Wsus'
    $script:vmRoot       = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:osDiskPath   = Join-Path -Path $script:vmRoot -ChildPath ('{0}-osdisk.vhdx' -f $script:vmName)
    $script:isoPath      = Join-Path -Path $script:shareRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:sequenceRoot = Join-Path -Path $script:shareRoot -ChildPath ('TaskSequences\{0}' -f $script:sequenceId)
    $script:catalogPath  = Join-Path -Path $script:shareRoot -ChildPath ('OperatingSystems\{0}\os.yaml' -f $script:osId)
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e-wsusupdate'

    if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
        New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
    }

    # -- THE PROTECTED SET, RECORDED BEFORE ANYTHING STARTS ----------------
    #
    # EVERY VM THIS SUITE DOES NOT OWN, as a set rather than a list of names - a
    # name list rots, and when it does the comparison silently becomes
    # empty-against-empty and holds while checking nothing (SPIKES S9.14). The
    # unfiltered Get-VM here is READ-ONLY and is the one exception PROJECT.md
    # rule 1 allows: you cannot prove you left the other VMs alone without
    # listing them.
    #
    # THE LAB'S OWN SERVERS ARE IN THIS SET. HDT-WSUS-01 matches HDT-* and this
    # repository did not create it; it is infrastructure, and this file must
    # leave it exactly as it found it while talking to it over HTTP throughout.
    $script:vmBefore = @(Hyper-V\Get-VM |
            Where-Object { [string] $_.Name -ne $script:vmName } |
            ForEach-Object {
                [pscustomobject] @{
                    Name   = [string] $_.Name
                    State  = [string] $_.State
                    Memory = [long] $_.MemoryStartup
                    Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                ForEach-Object { [string] $_.SwitchName }) -join ',')
                }
            } | Sort-Object Name)

    $script:record        = @()
    $script:state         = $null
    $script:logText       = ''
    $script:runId         = ''
    $script:runFolder     = ''
    $script:overrideFile  = ''
    $script:vmUuid        = ''
    $script:endedCleanly  = $false
    $script:runSecond     = 0
    $script:imageBuild    = ''
    $script:deployedBuild = ''

    # THE BUILD THE IMAGE CARRIES, READ OFF THE CATALOG RATHER THAN WRITTEN
    # DOWN. It is a property of the artefact under test, and recapturing the
    # reference image changes it. Asserting movement from THIS number is what
    # keeps the file honest when the lab re-approves.
    if (Test-Path -LiteralPath $script:catalogPath -PathType Leaf) {
        $catalog = Get-HDTOperatingSystem -WorkspaceRoot $script:shareRoot -Id $script:osId -ErrorAction SilentlyContinue
        if ($null -ne $catalog) {
            # Images, plural - the catalog carries one entry per index, and a
            # WIM may hold several. The default index is the one deployed.
            $first = @($catalog.Images | Where-Object { [int] $_.Index -eq [int] $catalog.DefaultIndex })
            if ($first.Count -eq 0) { $first = @($catalog.Images) }

            if ($first.Count -ge 1 -and $null -ne $first[0].PSObject.Properties['Version']) {
                $script:imageBuild = [string] $first[0].Version
            }
        }
    }

    $script:canRun = (
        (Test-Path -LiteralPath (Join-Path $script:shareRoot 'workspace.yaml') -PathType Leaf) -and
        (Test-Path -LiteralPath $script:catalogPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:isoPath -PathType Leaf))

    if ($script:canRun) {

        # -- rule 4: the memory budget, before anything is started ----------
        #
        # ONE PLACE, AND THIS ASKS IT. The total, the cap and the rule about
        # which VMs count all live in Get-HDTLabMemoryBudget /
        # Get-HDTLabMemoryUse. The budget counts only VMs the harness STAMPED,
        # so the lab's WSUS and WDS servers - which between them held the whole
        # of the old 12 GB cap - do not eat it.
        Assert-HDTLabMemoryBudget -MemoryByte 4294967296 -Name $script:vmName

        # -- THE SEQUENCE, SEEDED FROM THIS REPOSITORY ----------------------
        #
        # ONE PLACE OF TRUTH AND THE SHARE HOLDS A COPY (CLAUDE.md rule 8).
        # WSUS-UPDATE is this file's own sequence, so refreshing it every run
        # destroys nobody's edits - which is exactly why the share's OTHER
        # sequences are never written by this file at all.
        $payloadRoot = Join-Path -Path $PSScriptRoot -ChildPath 'payload/WSUS-UPDATE'

        if (-not (Test-Path -LiteralPath $script:sequenceRoot -PathType Container)) {
            New-HDTTaskSequence -Workspace $script:shareRoot -Id $script:sequenceId `
                -Name 'Deploy the reference image and patch it from WSUS' -Template client -Confirm:$false | Out-Null
        }

        Copy-Item -LiteralPath (Join-Path -Path $payloadRoot -ChildPath 'sequence.yaml') `
            -Destination (Join-Path -Path $script:sequenceRoot -ChildPath 'sequence.yaml') -Force

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

        # 100 GB dynamic. The sequence validates minDiskGB 60, and a cumulative
        # update of this size needs real room to stage and install - the servicing
        # stack keeps the superseded payload until it is cleaned up.
        Hyper-V\New-VHD -Path $script:osDiskPath -SizeBytes 107374182400 -Dynamic | Out-Null

        # 'HDT External', NOT 'HDT Lab'. This machine reads an image off the
        # share over SMB AND talks to the WSUS server over HTTP; a VM on the
        # isolated switch gets no lease and can reach neither (SPIKES S6).
        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 4294967296 -ProcessorCount 2 `
            -SwitchName 'HDT External' -VhdPath @($script:osDiskPath) `
            -IsoPath $script:isoPath -Confirm:$false | Out-Null

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

        # THE PER-MACHINE OVERRIDE - DESIGN 3.1's SECOND SOURCE, WHICH BEATS
        # rules.yaml BELOW IT. That precedence is the whole reason this file
        # never edits the share's rules: the lab's rules.yaml pins every machine
        # behind this gateway to PNP-TEST, and nothing types a sequence id at a
        # zero-touch machine.
        #
        # IT DOES NOT SET HDTWSUSServer. That comes from rules.yaml's fallback,
        # deliberately: the step reading a variable the SHARE supplies is part of
        # what is being tested, and an override that supplied it here would prove
        # only that this file can write a file.
        #
        # HDTComputerName is set because rules.yaml's fallback names a machine
        # PC-%HDTSerialNumber%, and a Hyper-V serial is 32 characters - a name
        # over the 15 character NetBIOS limit, which Windows Setup silently
        # discards and replaces with one of its own (SPIKES S9.11). A renamed
        # machine would still patch, but nothing afterwards could tell which
        # WSUS client record belonged to it.
        $script:overrideFile = Join-Path -Path $script:shareRoot -ChildPath ('Control\machines\{0}.yaml' -f $script:vmUuid)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:overrideFile, @"
# Written by tests/e2e/WindowsUpdate.E2E.Tests.ps1 for this run's VM, and
# removed by its AfterAll. DESIGN 3.1 source 2, keyed on the machine's UUID.
schemaVersion: 1
variables:
  HDTComputerName: $script:computerName
  HDTTaskSequenceID: $script:sequenceId
  HDTSkipFinalSummary: true
  HDTFinishAction: Shutdown
"@, $utf8NoBom)

        # -- START IT, AND THEN SEND IT NOTHING -----------------------------
        #
        # THREE LEGS AND TWO REBOOTS, which is one more than an ordinary
        # deployment: WinPE, then the full OS for Tattoo and the first update
        # pass, then the full OS AGAIN after the update's own restart so the
        # step can run its second pass. The VM is Running throughout all of it,
        # so the wait is for the END - HDTFinishAction powers the machine off
        # when the last leg finishes - and the LOG is what says which legs it
        # reached.
        #
        # 120 MINUTES, and the cumulative update is why. An apply of a 6.5 GB
        # image over SMB is minutes; downloading and installing a cumulative
        # update of the size WSUS holds for a whole product is most of an hour
        # on its own, and it happens twice over if a second pass finds anything.
        $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Hyper-V\Start-VM -Name $script:vmName

        Start-Sleep -Seconds 150
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'wsus-01-winpe.png') | Out-Null

        $script:endedCleanly = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 120

        $runStopwatch.Stop()
        $script:runSecond = [int] $runStopwatch.Elapsed.TotalSeconds

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'wsus-02-ended.png') | Out-Null
        Write-Information ("the deployment ended after {0}s (powered off cleanly: {1})" -f
            $script:runSecond, $script:endedCleanly) -InformationAction Continue

        # -- the evidence, off the share ------------------------------------
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

            # THE CMTrace LOG AS WELL AS THE JSONL. The update step's per-update
            # narration - which server, which KB, which pass, how long - is
            # written as log lines, and reading them is how this file can assert
            # WHAT the step did rather than only that it finished.
            $textPath = Join-Path -Path $script:runFolder -ChildPath 'HDT.log'
            if (Test-Path -LiteralPath $textPath) {
                $script:logText = [System.IO.File]::ReadAllText($textPath)
            }

            # state.json IS NOT BESIDE THE JSONL, AND THE LEGS ARE WHY.
            # HDTSLShareDynamicLogging copies the run log to Logs\<name>\<runid>\;
            # the engine's own per-run directory is the FLAT sibling
            # Logs\<name>-<runid>\, and that is where state.json is written.
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
        # being clean. The AfterAll still removes it, because this line does not
        # run when the wait above throws.
        if ($script:overrideFile -and (Test-Path -LiteralPath $script:overrideFile -PathType Leaf)) {
            Remove-Item -LiteralPath $script:overrideFile -Force -ErrorAction SilentlyContinue
        }

        # -- THE BUILD THE MACHINE ENDED ON, READ OFF ITS OWN DISK ----------
        #
        # AFTER THE MACHINE IS OFF. The UBR is the fourth part of the version
        # and is what a cumulative update moves; CurrentBuildNumber alone does
        # not change and would report success for a machine that installed
        # nothing at all.
        #
        # THE HIVE IS COPIED OUT BEFORE IT IS LOADED. reg load OPENS THE HIVE
        # FILE FOR WRITE even when nothing writes to it, so loading it in place
        # on evidence is both fragile and dishonest.
        if (Test-Path -LiteralPath $script:osDiskPath) {
            $mounted = $null
            try {
                $mounted = Mount-DiskImage -ImagePath $script:osDiskPath -PassThru -ErrorAction Stop
                $letters = @(Get-Disk -Number $mounted.Number | Get-Partition |
                        Where-Object { $_.DriveLetter } | ForEach-Object { [string] $_.DriveLetter })

                foreach ($letter in $letters) {
                    $config = ('{0}:\Windows\System32\config' -f $letter)
                    if (-not (Test-Path -LiteralPath (Join-Path $config 'SOFTWARE') -PathType Leaf)) { continue }

                    $working = Join-Path -Path $script:artifactRoot -ChildPath 'DEPLOYED.hive'
                    Copy-Item -LiteralPath (Join-Path $config 'SOFTWARE') -Destination $working -Force

                    & reg.exe load 'HKLM\HDTDEPLOYED' $working | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        try {
                            $cv = 'HKLM:\HDTDEPLOYED\Microsoft\Windows NT\CurrentVersion'
                            if (Test-Path -LiteralPath $cv) {
                                $p = Get-ItemProperty -LiteralPath $cv -ErrorAction SilentlyContinue
                                $script:deployedBuild = '{0}.{1}' -f [string] $p.CurrentBuildNumber, [string] $p.UBR
                            }
                        } finally {
                            [gc]::Collect()
                            [gc]::WaitForPendingFinalizers()
                            & reg.exe unload 'HKLM\HDTDEPLOYED' | Out-Null
                            Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
                        }
                    }
                    break
                }
            } catch {
                Write-Warning ("could not read the deployed build off the VHDX: {0}" -f $_.Exception.Message)
            } finally {
                if ($null -ne $mounted) {
                    Dismount-DiskImage -ImagePath $script:osDiskPath -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        Write-Information ("image build {0} -> deployed build {1}" -f
            $script:imageBuild, $script:deployedBuild) -InformationAction Continue
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
            # EJECT THE ISO EVEN WHEN THE VM IS KEPT. A machine left holding the
            # boot ISO fails every future Update-HDTBootImage on the swap, and
            # the person it fails for will not be looking at this VM (SPIKES S24).
            Hyper-V\Stop-VM -Name 'HDT-M8-Wsus' -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
            $dvd = @(Hyper-V\Get-VMDvdDrive -VMName 'HDT-M8-Wsus' -ErrorAction SilentlyContinue)
            foreach ($drive in $dvd) {
                Hyper-V\Set-VMDvdDrive -VMName 'HDT-M8-Wsus' `
                    -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation `
                    -Path '' -ErrorAction SilentlyContinue
            }
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M8-Wsus was left in place, powered off, with its ISO ejected."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M8-Wsus' -Confirm:$false
        }
    }

    # THE SEQUENCE AND THE CATALOG ENTRY STAY. WSUS-UPDATE is this file's own
    # and is refreshed from the payload every run; REF-ACROBAT is what it
    # deploys and was promoted by hand.
}

Describe 'the deployment ran end to end' -Tag 'E2E' -Skip:$skipUpdate {

    It 'ended by powering the machine off rather than by timing out' {
        $script:endedCleanly | Should -BeTrue -Because 'HDTFinishAction Shutdown ends the run; a timeout here means it stopped somewhere with nobody to answer it'
    }

    It 'ran the sequence the override named' {
        @($script:record).Count | Should -BeGreaterThan 0
        $script:runId | Should -Not -BeNullOrEmpty
    }

    It 'reports Succeeded in state.json' {
        # NOT RebootPending. That distinction is the whole of the 2026-09-06
        # defect: a run whose last step asked to come back and never did ends
        # RebootPending with its work apparently done.
        $script:state | Should -Not -BeNullOrEmpty
        [string] $script:state.status | Should -Be 'Succeeded'
    }

    It 'never failed a step' {
        $failed = @($script:record | Where-Object { [string] $_.event -eq 'step.complete' -and [string] $_.status -eq 'Failed' })
        $failed.Count | Should -Be 0 -Because ("these steps failed: {0}" -f (($failed | ForEach-Object { [string] $_.step }) -join ', '))
    }
}

Describe 'the WindowsUpdate step talked to the lab server' -Tag 'E2E' -Skip:$skipUpdate {

    It 'pointed the update client at the server the step named' {
        # THE CLIENT IS POINTED, NOT ASKED NICELY. The adapter writes WUServer,
        # WUStatusServer and UseWUServer, restarts the service, and sets
        # ServerSelection to ssManagedServer - without that last one the
        # registry values govern nothing and the scan quietly goes to Microsoft.
        $script:logText | Should -Match 'the update client is pointed at the server this step names'
    }

    It 'named the address rules.yaml supplied rather than one of its own' {
        $configured = ''
        $line = @(Select-String -LiteralPath (Join-Path $script:shareRoot 'rules.yaml') -Pattern '^\s*HDTWSUSServer\s*:' -ErrorAction SilentlyContinue)
        if ($line.Count -ge 1) {
            $configured = ([string] $line[0].Line -replace '^\s*HDTWSUSServer\s*:\s*', '').Trim().Trim("'", '"')
        }

        $configured | Should -Not -BeNullOrEmpty
        $script:logText | Should -Match ([regex]::Escape($configured))
    }

    It 'searched, and said what the search returned' {
        # THE SEARCH IS REPORTED WHETHER OR NOT IT FOUND ANYTHING, which is what
        # lets a zero-update run be diagnosed as a staging problem rather than
        # looking like a broken step.
        $script:logText | Should -Match 'pass 1 of at most \d+: the search returned \d+ update'
    }

    It 'installed every update the server offered it' {
        $offered = ([regex]::Matches($script:logText, 'the search returned (\d+) update')) |
            Select-Object -First 1

        $offered | Should -Not -BeNullOrEmpty
        $count = [int] $offered.Groups[1].Value

        if ($count -eq 0) {
            # NOT A PASS DRESSED UP AS ONE. The step behaved correctly, but the
            # thing this file exists to measure did not happen, and saying so is
            # the honest outcome.
            throw "the WSUS server offered this machine 0 updates, so nothing was patched and this file measured nothing. That is a lab-staging problem, not a step defect: approve an update that applies to the image REF-ACROBAT carries ($script:imageBuild) and run again."
        }

        $installed = @([regex]::Matches($script:logText, "pass \d+: \d+ of \d+: installed (KB\d+)"))
        $installed.Count | Should -Be $count -Because 'every applicable update the search returned should have been installed'
    }

    It 'reached a pass that found nothing left to do, within maxPasses' {
        # THE POINT OF MULTIPLE PASSES. A single-pass Windows Update step is the
        # classic MDT mistake that leaves machines partly patched, because
        # installing one update supersedes or reveals another. The step is only
        # finished when a pass comes back empty.
        $script:logText | Should -Match 'the search returned 0 update'
    }
}

Describe 'the re-entrant last step came back' -Tag 'E2E' -Skip:$skipUpdate {

    # THE GUARD FOR THE 2026-09-06 DEFECT. See the file header: WindowsUpdate is
    # the last step and it is re-entrant, and the engine used to treat "no steps
    # after it" as "nothing needs a Windows session".

    It 'armed an autologon for the re-entrant last step' {
        $script:logText | Should -Not -Match 'no autologon was armed'
        $script:logText | Should -Match 'Autologon armed'
    }

    It 'ran a second pass in the full OS after the update restart' {
        # THE ONE ASSERTION A FAKE CANNOT MAKE. Pass 2 exists only if a machine
        # rebooted, logged itself on, and resumed the step it was in the middle
        # of.
        $script:logText | Should -Match 'pass 2'
    }

    It 'resumed into the full OS rather than back into WinPE' {
        $resumed = @($script:record | Where-Object { [string] $_.phase -eq 'FullOS' })
        $resumed.Count | Should -BeGreaterThan 0
    }
}

Describe 'the machine it patched' -Tag 'E2E' -Skip:$skipUpdate {

    It 'reads its build off its own disk' {
        $script:deployedBuild | Should -Not -BeNullOrEmpty -Because 'the SOFTWARE hive on the deployed volume is where the answer is'
    }

    It 'ended on a HIGHER build than the image it was deployed from' {
        # MOVEMENT, NOT A FIXED NUMBER. Hard-coding the target build would fail
        # the day the lab approves a newer cumulative, which is the wrong thing
        # to be brittle about; what must always hold is that the machine ended
        # ahead of the image.
        $script:imageBuild | Should -Not -BeNullOrEmpty

        $imageUbr = [int] (([string] $script:imageBuild -split '\.')[-1])
        $deployedUbr = [int] (([string] $script:deployedBuild -split '\.')[-1])

        $deployedUbr | Should -BeGreaterThan $imageUbr -Because ("the image carries {0} and the patched machine reports {1}; an equal UBR means nothing was installed" -f
            $script:imageBuild, $script:deployedBuild)
    }
}

Describe 'the lab is unharmed' -Tag 'E2E' -Skip:$skipUpdate {

    It 'left every VM it does not own exactly as it found them' {
        $after = @(Hyper-V\Get-VM |
                Where-Object { [string] $_.Name -ne $script:vmName } |
                ForEach-Object {
                    [pscustomobject] @{
                        Name   = [string] $_.Name
                        State  = [string] $_.State
                        Memory = [long] $_.MemoryStartup
                        Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                    ForEach-Object { [string] $_.SwitchName }) -join ',')
                    }
                } | Sort-Object Name)

        # NOT empty-against-empty. A snapshot with nothing in it would compare
        # equal to another empty one and hold while checking nothing.
        @($script:vmBefore).Count | Should -BeGreaterThan 0 -Because 'the lab runs at least the WSUS server this file talks to'

        ($after | ConvertTo-Json -Depth 3) | Should -Be ($script:vmBefore | ConvertTo-Json -Depth 3)
    }

    It 'left the WSUS server running, having only ever read from it' {
        $wsus = @($script:vmBefore | Where-Object { [string] $_.State -eq 'Running' })
        $wsus.Count | Should -BeGreaterThan 0
    }

    It 'took its per-machine override back off the share' {
        $script:overrideFile | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:overrideFile -PathType Leaf | Should -BeFalse
    }
}
