# THE ENGINE'S FIRST RUN INSIDE WinPE, and it runs BEFORE the deployment on
# purpose.
#
# Everything phase 04 built is asserted against fakes, on a developer machine,
# under pwsh 7. This file boots the SPIKES S1/S3 WinPE image in a Generation 2
# VM on the isolated 'HDT Lab' switch, starts tests/e2e/payload/Start-HDTLabProbe.ps1
# at the prompt, and reads what came back.
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
    $script:isoPath = 'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso'
    $script:skipSmoke = -not (Test-Path -LiteralPath $script:isoPath -PathType Leaf)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:vmName = 'HDT-M3-Smoke'
    $script:vmRoot = Join-Path -Path 'C:\HDTLab\vms' -ChildPath $script:vmName
    $script:contentPath = Join-Path -Path $script:vmRoot -ChildPath 'HDT-M3-Smoke-content.vhdx'
    $script:isoPath = 'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso'
    $script:artifactRoot = 'C:\HDTLab\scratch\e2e'

    # -- the two protected VMs, recorded BEFORE anything starts ------------
    #
    # MemoryStartup, NOT MemoryStartupBytes: that is New-VM's parameter name,
    # not the property Get-VM returns. Without StrictMode the missing property
    # is $null, [long] $null is 0, and this comparison held 0 against 0 - the
    # assertion protecting the user's lab was passing while comparing nothing
    # (helpers README 12). Only ./build.ps1 -Task e2e sets StrictMode; a bare
    # Invoke-Pester does not, which is why it hid.

    $script:protectedBefore = @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
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

    # Recomputed here rather than read from BeforeDiscovery: the two phases do
    # not share a scope, and reading it throws under the StrictMode ./build.ps1
    # sets. See the same note in Deployment.E2E.Tests.ps1.
    $script:canSmoke = Test-Path -LiteralPath $script:isoPath -PathType Leaf

    if ($script:canSmoke) {
        # -- a small content disk: the module, the parser, the workspace ----

        $yamlModule = @(Get-Module -Name 'powershell-yaml' -ListAvailable |
                Sort-Object Version -Descending)[0]

        $script:yamlSource = [string] $yamlModule.ModuleBase
        Write-Information ("staging powershell-yaml {0} from {1}" -f $yamlModule.Version, $script:yamlSource) -InformationAction Continue

        New-HDTLabContentDisk -Path $script:contentPath -SizeByte 2147483648 -Confirm:$false -Source @{
            'HDT\Modules\Hephaestus'                             = (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus')
            'HDT\Modules\powershell-yaml'                        = $script:yamlSource
            'HDT\Start-HDTLabProbe.ps1'                          = (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/payload/Start-HDTLabProbe.ps1')
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

        # SPIKES S1 measured boot to a WinPE prompt at well under 100 s on
        # 2 vCPU / 4 GB. 150 s is that with room, and a screenshot is saved
        # either way so a human can see what was on screen when we typed.
        Start-Sleep -Seconds 150

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'smoke-winpe.png') | Out-Null

        # The content drive letter is not guaranteed in WinPE, so the line
        # scans for the probe rather than assuming one.
        $line = 'for %d in (C D E F G) do @if exist %d:\HDT\Start-HDTLabProbe.ps1 powershell -ExecutionPolicy Bypass -File %d:\HDT\Start-HDTLabProbe.ps1'
        Send-HDTLabVmText -Name $script:vmName -Text $line -Enter -Confirm:$false

        # The probe shuts the machine down when it has written its answer.
        $script:startedOk = Wait-HDTLabVmState -Name $script:vmName -State 'Off' -TimeoutMinute 15

        Save-HDTLabVmScreen -Name $script:vmName -Path (Join-Path -Path $script:artifactRoot -ChildPath 'smoke-final.png') | Out-Null

        # -- read the answer off the disk ----------------------------------

        try {
            Mount-DiskImage -ImagePath $script:contentPath -StorageType VHDX -Access ReadOnly | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $script:contentPath).Number
            $letter = @(Get-Partition -DiskNumber $number | Where-Object { $_.DriveLetter } |
                    ForEach-Object { [string] $_.DriveLetter })

            if ($letter.Count -ge 1) {
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

    Context 'the capture survives the VM' {

        It 'saved PROBE.json under the e2e artifact root' {
            # The AfterAll destroys the VM and its content disk. A capture that
            # only existed there would be gone before anybody could look at it.
            Test-Path -LiteralPath (Join-Path -Path $script:artifactRoot -ChildPath 'PROBE.json') |
                Should -BeTrue
        }
    }

    Context 'the lab is unharmed' {

        It 'left CM01 and DC01 exactly as it found them' {
            $after = @(Hyper-V\Get-VM -Name 'CM01', 'DC01' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [pscustomobject] @{
                            Name = [string] $_.Name; State = [string] $_.State
                            Memory = [long] $_.MemoryStartup
                            Switch = (@(Hyper-V\Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue |
                                        ForEach-Object { [string] $_.SwitchName }) -join ',')
                        }
                    })

            ($after | ConvertTo-Json -Depth 3) | Should -BeExactly ($script:protectedBefore | ConvertTo-Json -Depth 3)
        }
    }
}
