# THE ENGINE'S FIRST RUN INSIDE WinPE, and it runs BEFORE the deployment on
# purpose.
#
# Everything phase 04 built is asserted against fakes, on a developer machine,
# under pwsh 7. This file boots a Generation 2 VM on the isolated 'HDT Lab'
# switch from a boot image IT BUILDS, and reads back what the probe found.
#
# NOTHING TYPES AT THE PROMPT, and that is a property of the whole tests/e2e
# folder now, enforced by tests/contract/NoKeystroke.Contract.Tests.ps1.
#
# This file used to send a 'for %d in (C D E F G) do @if exist ...' line to the
# VM's keyboard, because the hand-built SPIKES S1/S3 image ran a startnet.cmd
# that launched nothing and the probe sat on a data disk whose letter WinPE
# chooses. Both halves of that are gone: Update-HDTBootImage builds the image
# here, workspace.yaml's extraContent stages the probe INSIDE it, and
# entryCommand points startnet.cmd at it. Content staged into the image lands
# under X:, the RAM disk, whose letter is fixed - so there is nothing to scan
# for and nothing to type.
#
# WHAT THE PROBE STILL READS OFF THE CONTENT DISK is deliberate: the engine and
# powershell-yaml stay on the data disk, and the probe prepends that disk's
# HDT\Modules to PSModulePath before importing. So 'loads it from the staged
# copy on the content disk' still means what it says even though the image now
# carries its own copy of both.
#
# WHY BEFORE THE DEPLOYMENT. If powershell-yaml does not load inside WinPE, the
# engine cannot read a sequence, and every failure of the deployment would be a
# mystery on top of that one. Five minutes here turns a mystery into a sentence.
#
# THE VM IS GIVEN EXACTLY ONE SMALL DISK - the content disk itself - so there is
# nothing attached that could be mistaken for a deployment target. The probe
# reads and never writes to a disk.
#
# It also closes the repository's last derived fixture: gen2-vm-raw-disk.json
# has been derived from SPIKES S6's notes rather than captured, because until
# now there was no HDT test VM to capture from.

BeforeDiscovery {
    # THE ADK, not a pre-built ISO on a scratch path. This file builds its own
    # image now, so what it needs is the toolchain that builds one.
    $script:skipSmoke = $true
    try {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:skipSmoke = $false
    } catch {
        $script:skipSmoke = $true
    }

    if ($script:skipSmoke) {
        Write-Warning 'WinPeSmoke.E2E.Tests.ps1 is SKIPPED. It builds its own diagnostic boot image, which needs the Windows ADK with the Windows PE add-on.'
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:vmName = 'HDT-M3-Smoke'
    $script:vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:contentPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M3-Smoke-content.vhdx'
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e'

    # The image this file builds, kept apart from the deployment image's build
    # root so the two cannot overwrite one another's artifacts.
    $script:buildRoot = 'C:\HDTLab\scratch\e2e-probeimage'
    $script:buildWorkspace = Join-Path -Path $script:buildRoot -ChildPath 'Share'
    $script:buildScratch = Join-Path -Path $script:buildRoot -ChildPath 'work'
    $script:probeStaging = Join-Path -Path $script:buildRoot -ChildPath 'stage'
    $script:isoPath = ''

    # -- the two protected VMs, recorded BEFORE anything starts ------------
    #
    # MemoryStartup, NOT MemoryStartupBytes: that is New-VM's parameter name,
    # not the property Get-VM returns. Without StrictMode the missing property
    # is $null, [long] $null is 0, and this comparison held 0 against 0 - the
    # assertion protecting the user's lab was passing while comparing nothing
    # (helpers README 12). Only ./build.ps1 -Task e2e sets StrictMode; a bare
    # Invoke-Pester does not, which is why it hid.

    # EVERY VM THIS SUITE DOES NOT OWN, not two names. CM01 and DC01 were
    # deleted from this host, which turned a two-name snapshot into an empty
    # array - and comparing empty with empty afterwards held while checking
    # nothing (the shape of SPIKES S9.14). Reading every non-HDT-* VM covers
    # whatever is built next without anyone remembering to add its name.
    $script:protectedBefore = @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject] @{
                    Name = [string] $_.Name; State = [string] $_.State
                    Memory = [long] $_.MemoryStartup
                    Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                ForEach-Object { [string] $_.SwitchName }) -join ',')
                }
            })

    $script:probe = $null
    $script:probeRaw = ''
    $script:startedOk = $false

    # 05-06: set when the probe had to call wpeutil itself because
    # New-HDTPowerService did not end the machine. Its ABSENCE is the assertion.
    $script:fellBack = $true
    $script:fallbackText = ''

    # Recomputed here rather than read from BeforeDiscovery: the two phases do
    # not share a scope, and reading it throws under the StrictMode ./build.ps1
    # sets. See the same note in Deployment.E2E.Tests.ps1.
    $script:canSmoke = $false
    try {
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:canSmoke = $true
    } catch {
        $script:canSmoke = $false
    }

    if ($script:canSmoke) {
        # -- the diagnostic boot image, built by the product -----------------
        #
        # extraContent stages a DIRECTORY (Copy-HDTContentTree walks children),
        # so the probe is copied into a staging folder of its own rather than
        # pointing extraContent at tests/e2e/payload and dragging the deployment
        # payload in beside it.

        foreach ($folder in @($script:buildWorkspace,
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Boot'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Control'),
                (Join-Path -Path $script:buildWorkspace -ChildPath 'Logs'),
                $script:probeStaging,
                $script:artifactRoot)) {

            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
            }
        }

        Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/payload/Start-HDTLabProbe.ps1') `
            -Destination (Join-Path -Path $script:probeStaging -ChildPath 'Start-HDTLabProbe.ps1') -Force

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'workspace.yaml'), @"
# Written by tests/e2e/WinPeSmoke.E2E.Tests.ps1.
#
# THE DIAGNOSTIC IMAGE OF DESIGN 5.1. entryCommand replaces the deployment
# payload with the probe, and extraContent is what puts the probe where
# entryCommand says it is. X: is the WinPE RAM disk and its letter is fixed,
# which is the whole reason no drive scan is needed here any more.
schemaVersion: 1
id: HDT-LAB-PROBE
name: HDT WinPE probe workspace
deployRoot: \Share
logLevel: Debug
bootImage:
  name: HDTPE_probe_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  extraContent:
    - source: $script:probeStaging
      destination: \HDT
  entryCommand: powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTLabProbe.ps1
"@, $utf8NoBom)

        [System.IO.File]::WriteAllText((Join-Path -Path $script:buildWorkspace -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", $utf8NoBom)

        $buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $script:build = Update-HDTBootImage -WorkspaceRoot $script:buildWorkspace `
            -ScratchPath $script:buildScratch -Confirm:$false

        $buildStopwatch.Stop()
        $script:isoPath = [string] $script:build.IsoPath

        Write-Information ("probe boot image built in {0}s: {1}" -f
            [int] $buildStopwatch.Elapsed.TotalSeconds, $script:isoPath) -InformationAction Continue

        # -- a small content disk: the module, the parser, the workspace ----
        #
        # The probe is NOT staged here any more - it is in the image. The engine
        # and the parser stay, because the probe prepends this disk's HDT\Modules
        # to PSModulePath and the assertion below is about loading them FROM HERE.

        $yamlModule = @(Get-Module -Name 'powershell-yaml' -ListAvailable |
                Sort-Object Version -Descending)[0]

        $script:yamlSource = [string] $yamlModule.ModuleBase
        Write-Information ("staging powershell-yaml {0} from {1}" -f $yamlModule.Version, $script:yamlSource) -InformationAction Continue

        New-HDTLabContentDisk -Path $script:contentPath -SizeByte 2147483648 -Confirm:$false -Source @{
            'HDT\Modules\Hephaestus'                             = (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus')
            'HDT\Modules\powershell-yaml'                        = $script:yamlSource
            'Share\rules.yaml'                                   = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/rules.yaml')
            'Share\Scripts'                                      = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/Scripts')
            'Share\TaskSequences\DEMO-M3'                        = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences/DEMO-M3')
            'Share\OperatingSystems\Win11-LTSC-2024\os.yaml'     = (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/OperatingSystems/Win11-LTSC-2024/os.yaml')
        } | Out-Null

        # -- the VM, through the guarded helper ----------------------------

        Remove-HDTLabVirtualMachine -Name $script:vmName -KeepFile -Confirm:$false

        New-HDTLabVirtualMachine -Name $script:vmName -MemoryByte 2147483648 -ProcessorCount 2 `
            -SwitchName 'HDT Lab' -VhdPath @($script:contentPath) -IsoPath $script:isoPath -Confirm:$false | Out-Null

        Hyper-V\Start-VM -Name $script:vmName

        # NOTHING IS SENT TO THIS MACHINE. startnet.cmd launches the probe, so
        # the wait below is the whole interaction: the probe shuts the machine
        # down when it has written its answer, and a machine still running at
        # the timeout means startnet.cmd did not launch it.
        $script:startedOk = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 15

        # Taken AFTER the wait rather than at a fixed 150 s, because there is no
        # longer a moment we have to type into. On the failure path this is a
        # picture of the prompt the probe never left.
        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'smoke-winpe.png') | Out-Null

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'smoke-final.png') | Out-Null

        # -- read the answer off the disk ----------------------------------

        try {
            Mount-DiskImage -ImagePath $script:contentPath -StorageType VHDX -Access ReadOnly | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $script:contentPath).Number
            $letter = @(Get-Partition -DiskNumber $number | Where-Object { $_.DriveLetter } |
                    ForEach-Object { [string] $_.DriveLetter })

            if ($letter.Count -ge 1) {
                # THE MARKER, READ FIRST. It is written only by the probe's
                # fallback, immediately before it calls wpeutil itself, so its
                # presence means New-HDTPowerService did not end the machine.
                $fallbackPath = '{0}:\FALLBACK.txt' -f $letter[0]
                $script:fellBack = Test-Path -LiteralPath $fallbackPath -PathType Leaf
                if ($script:fellBack) {
                    $script:fallbackText = [System.IO.File]::ReadAllText($fallbackPath)
                }

                $probePath = '{0}:\PROBE.json' -f $letter[0]
                if (Test-Path -LiteralPath $probePath) {
                    $script:probeRaw = [System.IO.File]::ReadAllText($probePath)
                    $script:probe = ConvertFrom-Json $script:probeRaw

                    # COPIED OFF THE DISK BEFORE THE VM IS DESTROYED. The
                    # AfterAll removes the VM and its VHDXs, and the first run
                    # of this file lost the capture that way - which was the
                    # whole reason the probe was written. The artifact is what
                    # tests/fixtures/disk/gen2-vm-raw-disk.json is regenerated
                    # from, and what SPIKES S9 quotes.
                    if (-not (Test-Path -LiteralPath $script:artifactRoot -PathType Container)) {
                        New-Item -Path $script:artifactRoot -ItemType Directory -Force | Out-Null
                    }

                    [System.IO.File]::WriteAllText(
                        (Join-Path -Path $script:artifactRoot -ChildPath 'PROBE.json'), $script:probeRaw)
                }
            }
        } finally {
            Dismount-DiskImage -ImagePath $script:contentPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

AfterAll {
    # Runs on failure too. Rule 6: powered off and removed unless the operator
    # asked to keep it.
    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        if ($env:HDT_KEEP_LAB_VM -eq '1') {
            Write-Warning "HDT_KEEP_LAB_VM=1: HDT-M3-Smoke was left in place. Remove it with Remove-HDTLabVirtualMachine -Name 'HDT-M3-Smoke'."
        } else {
            Remove-HDTLabVirtualMachine -Name 'HDT-M3-Smoke' -Confirm:$false
        }
    }
}

Describe 'the engine inside WinPE' -Tag 'E2E' -Skip:$skipSmoke {

    Context 'the probe ran at all' {

        It 'shut the machine down when it finished' {
            $script:startedOk | Should -BeTrue -Because 'the probe ends with wpeutil shutdown; a machine still running means it never got that far'
        }

        It 'wrote PROBE.json to the content disk' {
            $script:probe | Should -Not -BeNullOrEmpty
        }

        It 'was started by startnet.cmd, not by anything typed at the prompt' {
            # THE ASSERTION THAT MAKES THIS FILE'S HEADER TRUE, and it is the
            # guest's own answer rather than a property of the harness source.
            # HDT_LAUNCHED_BY is set by the image's startnet.cmd - written from
            # workspace.yaml's entryCommand - and by nothing else.
            [string] $script:probe.launchedBy | Should -BeExactly 'startnet' -Because (
                'the probe runs because Update-HDTBootImage pointed startnet.cmd at it; open {0}\smoke-winpe.png if this fails - a bare X:\Windows\System32> prompt means startnet.cmd did not launch it' -f $script:artifactRoot)
        }
    }

    Context 'what WinPE turned out to have' {

        It 'runs Windows PowerShell 5.1' {
            # SPIKES S1 recorded 5.1.26100.1 by hand. This is the same claim,
            # made by code.
            [string] $script:probe.psVersion | Should -BeLike '5.1.*'
            [string] $script:probe.psEdition | Should -BeExactly 'Desktop'
        }

        It 'found the content disk' {
            [string] $script:probe.contentRoot | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the dependency the whole engine rests on' {

        It 'loads powershell-yaml inside WinPE' {
            # THE MOST IMPORTANT ASSERTION IN THIS FILE. ConvertFrom-HDTYaml
            # goes through this module, so a WinPE that cannot load it cannot
            # read a sequence at all - and ROADMAP M3's exit criterion is "a VM
            # boots into Windows FROM A SEQUENCE RUN".
            $script:probe.yamlLoaded | Should -BeTrue -Because ([string] $script:probe.yamlError)
        }

        It 'loads it from the staged copy on the content disk' {
            # Staged, not installed. There is no PowerShellGet in WinPE.
            [string] $script:probe.yamlBase | Should -BeLike '*HDT\Modules\powershell-yaml*'
        }

        It 'loads the Hephaestus module' {
            $script:probe.engineLoaded | Should -BeTrue -Because ([string] $script:probe.engineError)
        }
    }

    Context 'phase 02 gatherer, in its actual home' {

        It 'gathers machine facts against the real CIM provider' {
            [string] $script:probe.factError | Should -BeNullOrEmpty
            [int] $script:probe.factCount | Should -BeGreaterThan 10
        }

        It 'knows it is a virtual machine' {
            [string] $script:probe.fact.HDTIsVM | Should -BeExactly 'True'
        }

        It 'knows it booted UEFI' {
            # The uefi-standard layout is chosen from this.
            [string] $script:probe.fact.HDTIsUEFI | Should -BeExactly 'True'
        }
    }

    Context 'the documents the deployment depends on' {

        It 'parses the real DEMO-M3 sequence in WinPE' {
            # Importing the parser is necessary but not sufficient: what task 3
            # depends on is a sequence document actually coming back.
            [string] $script:probe.sequenceError | Should -BeNullOrEmpty
            [string] $script:probe.sequenceId | Should -BeExactly 'DEMO-M3'
            [int] $script:probe.sequenceStep | Should -BeGreaterThan 0
        }

        It 'parses the real rules.yaml in WinPE' {
            [string] $script:probe.ruleError | Should -BeNullOrEmpty
            [int] $script:probe.ruleCount | Should -BeGreaterThan 0
        }

        It 'reads the operating system catalog in WinPE' {
            [string] $script:probe.osCatalogError | Should -BeNullOrEmpty
            [string] $script:probe.osCatalogId | Should -BeExactly 'Win11-LTSC-2024'
        }
    }

    Context 'the Generation 2 disk row this repository had only derived' {

        It 'captured a disk row' {
            [string] $script:probe.diskError | Should -BeNullOrEmpty
            @($script:probe.disk).Count | Should -BeGreaterOrEqual 1
        }

        It 'reports BusType SAS, as SPIKES S6 recorded' {
            # NOT 'SCSI' and NOT 'Virtual'. Do not filter on a VM-specific bus
            # type - this is the value a Gen2 VM's disk actually reports.
            @($script:probe.disk)[0].BusType | Should -BeExactly 'SAS'
        }

        It 'agrees with the fixture on the properties this VM can show' {
            # PARTLY. THE SMOKE VM'S ONLY DISK IS ITS OWN CONTENT DISK, which
            # New-HDTLabContentDisk formatted - so it is GPT and 2 GB, not the
            # virgin 64 GB RAW disk gen2-vm-raw-disk.json describes. That is
            # deliberate: the smoke VM gets exactly one small disk so nothing
            # attached to it could be mistaken for a deployment target.
            #
            # What this run CAN close is the bus type, which is the property
            # SPIKES S6 warned about and the only one anybody would be tempted
            # to filter on. The RAW 64 GB row is captured by
            # Deployment.E2E.Tests.ps1, through IDiskService, a moment before
            # the deployment repartitions it.
            # Assigned first, wrapped second (helpers README F12).
            $captured = ConvertFrom-Json ([System.IO.File]::ReadAllText(
                    (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/disk/gen2-vm-raw-disk.json')))
            $fixture = @($captured)[0]

            $captured = @($script:probe.disk)[0]

            $captured.BusType | Should -BeExactly ([string] $fixture.BusType)
            $captured.FriendlyName | Should -BeExactly ([string] $fixture.FriendlyName)
            $captured.IsBoot | Should -Be ([bool] $fixture.IsBoot)
            $captured.IsSystem | Should -Be ([bool] $fixture.IsSystem)
        }
    }

    Context 'ROADMAP M2s deferred question, answered by the machine itself' {

        # M2 asked "whether WinPE needs wpeutil reboot rather than shutdown.exe"
        # and named phase 05 as the owner. 05-VERIFICATION.md recorded it
        # not_answered after five plans, and the reason it stayed open is that
        # New-HDTPowerService had NEVER EXECUTED - its contract row is skipped
        # permanently, because a contract test may not reboot the machine
        # running it. This is the run that closes it.

        It 'has no shutdown.exe' {
            # THE ANSWER, measured from inside a running WinPE rather than from
            # a mounted image. Not "shutdown.exe behaves differently here": it is
            # not on the machine at all, so the old default could not have worked.
            $script:probe.shutdownExe | Should -BeFalse -Because 'this is why WinPE needs wpeutil, and it is not a preference'
        }

        It 'has wpeutil.exe' {
            # The anti-vacuity control. A probe looking in the wrong System32
            # would report both absent.
            $script:probe.wpeutilExe | Should -BeTrue
        }

        It 'built a power service for WinPE' {
            [string] $script:probe.powerError | Should -BeNullOrEmpty
            [string] $script:probe.powerEnvironment | Should -BeExactly 'WinPE'
        }

        It 'resolved a command this machine actually has' {
            [string] $script:probe.powerCommand | Should -BeExactly 'wpeutil.exe'
            [string] $script:probe.powerArgument | Should -BeExactly 'shutdown'
        }

        It 'powered the machine off with it, and did not fall back' {
            # THE ASSERTION THAT MAKES THE REST MEAN SOMETHING. The probe calls
            # $power.Stop(0) and then waits 120 s; only if it is still running
            # after that does it write FALLBACK.txt and call wpeutil itself.
            # Without this, "the VM ended" would be satisfied by the fallback and
            # would prove nothing at all about the adapter.
            $script:fellBack | Should -BeFalse -Because ("the probe's fallback fired: {0}" -f $script:fallbackText)
        }
    }

    Context 'the capture survives the VM' {

        It 'saved PROBE.json under the e2e artifact root' {
            # The AfterAll destroys the VM and its content disk. A capture that
            # only existed there would be gone before anybody could look at it.
            Test-Path -LiteralPath (Join-Path -Path $script:artifactRoot -ChildPath 'PROBE.json') |
                Should -BeTrue
        }
    }

    Context 'the lab is unharmed' {

        It 'left every VM it does not own exactly as it found it' {
            $after = @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
                    Sort-Object Name |
                    ForEach-Object {
                        [pscustomobject] @{
                            Name = [string] $_.Name; State = [string] $_.State
                            Memory = [long] $_.MemoryStartup
                            Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                        ForEach-Object { [string] $_.SwitchName }) -join ',')
                        }
                    })

            # THE COUNT FIRST, so an empty host reads as "there was nothing to
            # protect" rather than as "nothing was harmed".
            @($after).Count | Should -Be @($script:protectedBefore).Count -Because (
                'this host had {0} VM(s) outside HDT-* when the run started' -f @($script:protectedBefore).Count)

            ($after | ConvertTo-Json -Depth 3) | Should -BeExactly ($script:protectedBefore | ConvertTo-Json -Depth 3)
        }
    }
}
