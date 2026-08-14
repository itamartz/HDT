# W2 of the WPF-first direction, on a machine (.planning/WPF-FIRST.md).
#
# TWO IMAGES, TWO PATHS, AND THE SECOND ONE IS THE IMPORTANT ONE.
#
#   the technician path   skip.welcome = false. The Welcome screen appears,
#                         carries the lease the machine actually got, and
#                         answers when it is dismissed.
#
#   the unattended path   skip.welcome unset. NOTHING IS SHOWN AND NOTHING
#                         WAITS. WPF-FIRST: "THE UNATTENDED PATH IS THE
#                         DEFAULT, NOT THE EXCEPTION. An image built with an
#                         embedded credential and a resolved HDTTaskSequenceID
#                         must still deploy with nobody present."
#
# The second is what stops a wizard from being a regression. Every image built
# before W2 existed has no skip block at all, so "said nothing" MUST mean
# unattended - and the only way to know it still does is to boot one.
#
# NOTHING IS TYPED INTO EITHER MACHINE. startnet.cmd launches the probe, the
# probe closes its own window with WM_CLOSE, and each machine shuts itself down.
# A machine still running at the timeout is the failure.
#
# LAB SAFETY (CLAUDE.md): both VMs are HDT-*, Generation 2, under C:\HDTLab\vms,
# on HDT External - the switch that carries a real DHCP lease, which is the only
# way a network pane can show one (SPIKES S6/S14). Nothing else is touched.

BeforeDiscovery {
    $script:e2eRoot = $PSScriptRoot
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:skipWizard =$true
    try {
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:skipWizard =$false
    } catch {
        $script:skipWizard =$true
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:labRoot = 'C:\HDTLab\scratch\wizard-e2e'
    $script:artifactRoot = Join-Path -Path $script:labRoot -ChildPath 'artifacts'

    $script:result = @{}

    # Recomputed here rather than read from BeforeDiscovery: the two phases do
    # not share a scope, and reading it throws under the StrictMode ./build.ps1
    # sets. Same note as Deployment.E2E.Tests.ps1.
    $script:canRun = $false
    try {
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:canRun = $true
    } catch {
        $script:canRun = $false
    }

    # ONE RUN PER PATH, EACH A COMPLETE BUILD-BOOT-READ. The two differ by one
    # line of workspace.yaml - the skip block - so anything else that differs is
    # a defect rather than a variable.
    $script:runPath = {
        param(
            [string] $Name,
            [string] $SkipBlock,
            [int] $DwellSecond)

        $vmName = 'HDT-W2-{0}' -f $Name
        $root = Join-Path -Path $script:labRoot -ChildPath $Name
        $workspace = Join-Path -Path $root -ChildPath 'workspace'
        $staging = Join-Path -Path $root -ChildPath 'payload'
        $scratch = Join-Path -Path $root -ChildPath 'mount'
        $marker = Join-Path -Path $root -ChildPath 'marker'
        $contentPath = 'C:\HDTLab\vms\{0}-content.vhdx' -f $vmName

        foreach ($folder in @($root, $workspace, (Join-Path -Path $workspace -ChildPath 'Boot'),
            (Join-Path -Path $workspace -ChildPath 'Control'), (Join-Path -Path $workspace -ChildPath 'Logs'),
                $staging, $scratch, $marker, $script:artifactRoot)) {

            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
            }
        }

        Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e/payload/Start-HDTWizardProbe.ps1') `
            -Destination (Join-Path -Path $staging -ChildPath 'Start-HDTWizardProbe.ps1') -Force

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

        [System.IO.File]::WriteAllText((Join-Path -Path $marker -ChildPath 'readme.txt'),
            'The probe writes WIZARDPROBE.json beside this marker.', $utf8NoBom)

        # -WindowStyle Hidden hides the POWERSHELL host. The cmd.exe window
        # startnet.cmd runs in is a different window and is Hide-HDTShellWindow's
        # job inside the payload - S15 recorded that both are needed.
        [System.IO.File]::WriteAllText((Join-Path -Path $workspace -ChildPath 'workspace.yaml'), @"
# Written by tests/e2e/Wizard.E2E.Tests.ps1 - the '$Name' path.
schemaVersion: 1
id: HDT-W2-$Name
name: HDT W2 $Name workspace
deployRoot: \Share
logLevel: Debug
bootImage:
  name: HDTPE_w2_$Name
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
$SkipBlock  extraContent:
    - source: $staging
      destination: \HDT
  entryCommand: powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File X:\HDT\Start-HDTWizardProbe.ps1 -DwellSecond $DwellSecond
"@, $utf8NoBom)

        [System.IO.File]::WriteAllText((Join-Path -Path $workspace -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", $utf8NoBom)

        $build = Update-HDTBootImage -WorkspaceRoot $workspace -ScratchPath $scratch -Confirm:$false

        Remove-HDTLabVirtualMachine -Name $vmName -Confirm:$false

        New-HDTLabContentDisk -Path $contentPath -SizeByte 1073741824 -Confirm:$false `
            -Source @{ 'HDTPROBE' = $marker } | Out-Null

        New-HDTLabVirtualMachine -Name $vmName -MemoryByte 2147483648 -ProcessorCount 2 `
            -SwitchName 'HDT External' -VhdPath @($contentPath) -IsoPath ([string] $build.IsoPath) `
            -Confirm:$false | Out-Null

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        Hyper-V\Start-VM -Name $vmName

        # A BURST, NOT ONE SHOT. S15: GetVirtualSystemThumbnailImage answers
        # 32775 often enough that a single capture at a fixed second finishes
        # with no picture at all.
        for ($second = 30; $second -le 180; $second += 15) {
            Start-Sleep -Seconds 15

            try {
                Save-HDTLabVmScreen -Name $vmName `
                    -Path (Join-Path -Path $script:artifactRoot -ChildPath ('{0}-{1:d3}s.png' -f $Name, $second)) | Out-Null
            } catch {
                $null = $_
            }

            if ((Hyper-V\Get-VM -Name $vmName).State -eq 'Off') { break }
        }

        $stopped = Wait-HDTLabVmState -Name $vmName -State 'Off' -TimeoutMinute 10
        $clock.Stop()

        $probe = $null
        $raw = ''

        try {
            Mount-DiskImage -ImagePath $contentPath -StorageType VHDX -Access ReadOnly | Out-Null

            $number = [int] (Get-DiskImage -ImagePath $contentPath).Number
            $letter = @(Get-Partition -DiskNumber $number | Where-Object { $_.DriveLetter } |
                    ForEach-Object { [string] $_.DriveLetter })

            if ($letter.Count -ge 1) {
                $probePath = '{0}:\WIZARDPROBE.json' -f $letter[0]
                if (Test-Path -LiteralPath $probePath) {
                    $raw = [System.IO.File]::ReadAllText($probePath)
                    $probe = ConvertFrom-Json $raw

                    # COPIED OFF BEFORE THE VM IS DESTROYED. The AfterAll removes
                    # the VM and its VHDX.
                    [System.IO.File]::WriteAllText(
                        (Join-Path -Path $script:artifactRoot -ChildPath ('WIZARDPROBE-{0}.json' -f $Name)),
                        $raw, $utf8NoBom)
                }
            }
        } finally {
            Dismount-DiskImage -ImagePath $contentPath -ErrorAction SilentlyContinue | Out-Null
        }

        return [pscustomobject] @{
            VmName        = $vmName
            Probe         = $probe
            Raw           = $raw
            StoppedItself = $stopped
            ElapsedSecond = [int] $clock.Elapsed.TotalSeconds
        }
    }

    if ($script:canRun) {
        # skip.welcome FALSE: the technician asked for the screen, on an image
        # that could otherwise have skipped it.
        $script:result['technician'] = & $script:runPath 'technician' "  skip:`n    welcome: false`n" 40

        # NO SKIP BLOCK AT ALL - the shape every image built before W2 has.
        $script:result['unattended'] = & $script:runPath 'unattended' '' 40
    }
}

AfterAll {
    # Runs on failure too. Powered off and removed unless the operator asked.
    if (Get-Command -Name 'Remove-HDTLabVirtualMachine' -ErrorAction SilentlyContinue) {
        foreach ($name in @('HDT-W2-technician', 'HDT-W2-unattended')) {
            if ($env:HDT_KEEP_LAB_VM -eq '1') {
                Write-Warning ("HDT_KEEP_LAB_VM=1: {0} was left in place." -f $name)
            } else {
                Remove-HDTLabVirtualMachine -Name $name -Confirm:$false
            }
        }
    }
}

Describe 'the W2 Welcome screen in WinPE' -Tag 'E2E' -Skip:$skipWizard {

    Context 'the technician path' {

        BeforeAll {
            $script:technician = $script:result['technician']
        }

        It 'wrote an answer at all' {
            $script:technician.Probe | Should -Not -BeNullOrEmpty -Because (
                'no WIZARDPROBE.json means the payload never ran; look in {0}' -f $script:artifactRoot)
        }

        It 'was started by startnet.cmd, not by anything typed at the prompt' {
            [string] $script:technician.Probe.launchedBy | Should -BeExactly 'startnet'
        }

        It 'loaded the engine out of the boot image' {
            [bool] $script:technician.Probe.moduleImported | Should -BeTrue
            [string] $script:technician.Probe.modulePath | Should -BeExactly 'X:\HDT\Modules'
        }

        It 'did NOT skip the Welcome screen, because the image said not to' {
            [bool] $script:technician.Probe.skipWelcome | Should -BeFalse
        }

        It 'showed the window' {
            [bool] $script:technician.Probe.shown | Should -BeTrue -Because (
                'showError was: {0}' -f [string] $script:technician.Probe.showError)
        }

        It 'read the lease the machine actually got, through WMI' {
            # SPIKES S14: Get-NetIPAddress does not exist here. This is the
            # positive half - Win32_NetworkAdapterConfiguration answering on a
            # live machine.
            [bool] $script:technician.Probe.networkRead | Should -BeTrue
            [bool] $script:technician.Probe.hasLease | Should -BeTrue -Because (
                'HDT External carries a real DHCP lease; HDT Lab would not')
            [string] $script:technician.Probe.ipAddress | Should -Match '^\d+\.\d+\.\d+\.\d+$'
        }

        It 'put that lease in the boxes' {
            @($script:technician.Probe.fieldName) | Should -Contain 'HDTIpAddressBox'
            @($script:technician.Probe.fieldName) | Should -Contain 'HDTGatewayBox'
        }

        It 'never offers to prefill the password box' {
            # The image can carry a credential. A prefilled PasswordBox would
            # put the share password on a screen in a room where somebody is
            # deploying a machine.
            @($script:technician.Probe.fieldName) | Should -Not -Contain 'HDTPasswordBox'
        }

        It 'hid the console, and put it back' {
            # A hidden console plus a payload that throws is a technician
            # staring at a blank screen with nothing to read.
            [bool] $script:technician.Probe.consoleHidden | Should -BeTrue
            [bool] $script:technician.Probe.consoleRestored | Should -BeTrue
        }

        It 'read a dismissed window as Cancel, and never as Next' {
            # THE ONE THAT MATTERS. The probe closes the window with WM_CLOSE,
            # which runs no handler - the same thing the X does. Next leads to a
            # task sequence that partitions a disk.
            [string] $script:technician.Probe.action | Should -BeExactly 'Cancel'
        }

        It 'ended the machine itself' {
            [bool] $script:technician.StoppedItself | Should -BeTrue
        }
    }

    Context 'the unattended path' {

        BeforeAll {
            $script:unattended = $script:result['unattended']
        }

        It 'wrote an answer at all' {
            $script:unattended.Probe | Should -Not -BeNullOrEmpty
        }

        It 'skipped the Welcome screen, because the image said nothing' {
            # THE REGRESSION GUARD FOR EVERY IMAGE ALREADY BUILT. None of them
            # has a skip block, and a wizard that appeared by default would make
            # each of them start waiting for a human who is not there.
            [bool] $script:unattended.Probe.skipWelcome | Should -BeTrue -Because (
                'an image that can reach its share unaided must deploy with nobody present')
        }

        It 'is the DEFAULT and not something the image asked for' {
            @($script:unattended.Probe.skipSource) |
                Should -Contain 'HDTSkipWelcome=True (default)'
        }

        It 'showed no window at all' {
            [bool] $script:unattended.Probe.shown | Should -BeFalse
        }

        It 'left no answer behind, because there was no question' {
            # 'Cancel' from a wizard that never opened is indistinguishable from
            # a technician cancelling one that did, and a caller reading Action
            # would not be able to tell.
            [string] $script:unattended.Probe.action | Should -BeExactly ''
        }

        It 'never hid the console, because it never showed anything over it' {
            [bool] $script:unattended.Probe.consoleHidden | Should -BeFalse
        }

        It 'still read the network, because diagnosis is not a question' {
            [bool] $script:unattended.Probe.networkRead | Should -BeTrue
        }

        It 'ended the machine itself, with nobody present' {
            [bool] $script:unattended.StoppedItself | Should -BeTrue
        }

        It 'got there faster than the path that stopped to ask' {
            # The dwell is the difference, and it is the whole cost of a wizard.
            [int] $script:unattended.ElapsedSecond |
                Should -BeLessThan ([int] $script:result['technician'].ElapsedSecond)
        }
    }
}
