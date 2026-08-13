# THE FIRST TIME ANY OF PHASE 05's CODE TOUCHES DISM OR OSCDIMG.
#
# Everything in tests/unit proves the boot image build DECIDES correctly, in
# seconds, against hand-written fakes. This file proves the TOOLS do what the
# fakes were told they do: a real Mount-WindowsImage, nine real cabs into a real
# WIM, a real Export-WindowsImage, a real oscdimg.
#
# THE CENTRAL ASSERTION IS READ BACK OUT OF A MOUNT. The built WIM is re-mounted
# READ-ONLY into a second path and startnet.cmd is read off it and compared, line
# by line, with Get-HDTStartnetScript's output. That is evidence rather than a
# claim: the unit suite asserts what the builder WROTE, and this asserts what is
# actually inside the image.
#
# THE SECOND IS DESIGN 6.1.1, WHICH ROADMAP M4 NAMES EXPLICITLY: the WIM inside
# the ISO hashes identical to the standalone WIM. Asserted three ways - the file
# on disk, sources\boot.wim inside the mounted ISO, and the manifest's
# isoBootWimSha256 - because a manifest that agreed with itself but not with the
# disk would be worse than none.
#
# Budget 15-25 minutes. SPIKES S1's hand build produced a 480 MB WIM and a 533 MB
# ISO from nine cabs.
#
# EVERY SKIP CONDITION IS RECOMPUTED INSIDE BeforeAll (SPIKES S9.15): Pester's
# discovery and run phases do not share a scope, and a $script: variable set in
# BeforeDiscovery throws when read from BeforeAll under ./build.ps1's StrictMode.
# Discovery needs its own copy for the -Skip: on each Describe, which is
# evaluated there.

BeforeDiscovery {
    $script:discoveryElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

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

    $script:discoveryYaml = @(Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue).Count -gt 0

    $script:discoveryFreeGb = 0
    try {
        $script:discoveryFreeGb = [math]::Floor(
            (Get-PSDrive -Name 'C' -ErrorAction Stop).Free / 1GB)
    } catch {
        $script:discoveryFreeGb = 0
    }

    $script:skipBuild = (-not $script:discoveryElevated) -or (-not $script:discoveryAdk) -or
        (-not $script:discoveryYaml) -or ($script:discoveryFreeGb -lt 8)

    if ($script:skipBuild) {
        Write-Warning ("BootImage.Integration.Tests.ps1 is SKIPPED. It builds a real boot image, which needs: an elevated session (currently {0}), the Windows ADK with the Deployment Tools and the Windows PE add-on (currently {1}), powershell-yaml (currently {2}), and about 8 GB free on C: (currently {3} GB)." -f
            $script:discoveryElevated, $script:discoveryAdk, $script:discoveryYaml, $script:discoveryFreeGb)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # RECOMPUTED, not borrowed from BeforeDiscovery. See the header.
    $script:elevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    $script:hasAdk = $false
    try {
        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:hasAdk = $true
    } catch {
        $script:hasAdk = $false
    }

    $script:hasYaml = @(Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction SilentlyContinue).Count -gt 0

    $script:freeGb = 0
    try { $script:freeGb = [math]::Floor((Get-PSDrive -Name 'C' -ErrorAction Stop).Free / 1GB) } catch { $script:freeGb = 0 }

    $script:skipBuild = (-not $script:elevated) -or (-not $script:hasAdk) -or
        (-not $script:hasYaml) -or ($script:freeGb -lt 8)

    # THE SCRATCH AREA. Never the repository, never C:\HDTLab\vms, never the
    # staged media - CLAUDE.md's protected paths. Everything this file creates
    # lives under here and is created by this file.
    $script:scratchRoot = 'C:\HDTLab\scratch\bootimage'
    $script:workspaceRoot = Join-Path -Path $script:scratchRoot -ChildPath 'Share'
    $script:workPath = Join-Path -Path $script:scratchRoot -ChildPath 'work'
    $script:inspectPath = Join-Path -Path $script:scratchRoot -ChildPath 'inspect'

    $script:skipWorkspaceRoot = Join-Path -Path $script:scratchRoot -ChildPath 'SkipIsoShare'
    $script:skipWorkPath = Join-Path -Path $script:scratchRoot -ChildPath 'skipwork'

    $script:wimPath = Join-Path -Path $script:workspaceRoot -ChildPath 'Boot\HDTPE_x64.wim'
    $script:isoPath = Join-Path -Path $script:workspaceRoot -ChildPath 'Boot\HDTPE_x64.iso'
    $script:manifestPath = Join-Path -Path $script:workspaceRoot -ChildPath 'Boot\HDTPE_x64.manifest.json'

    $script:secret = 'HDT-Integration-Secret-2026!'

    $script:buildSecond = 0
    $script:isoSecond = 0
    $script:manifest = $null
    $script:buildResult = $null
    $script:skipResult = $null

    # This host's disk 0, before anything runs. Compared in AfterAll: a boot
    # image build has no business touching a disk at all, and the other
    # integration files take the same snapshot.
    $script:disk0Before = ''
    try {
        $disk = Get-Disk -Number 0 -ErrorAction Stop
        $script:disk0Before = '{0}|{1}|{2}' -f $disk.PartitionStyle, $disk.IsBoot, $disk.IsSystem
    } catch {
        $script:disk0Before = 'unreadable'
    }

    $script:gitStatusBefore = ''
    try {
        Push-Location -LiteralPath $script:repoRoot
        $script:gitStatusBefore = (@(& git status --porcelain 2>$null) -join "`n")
    } catch {
        $script:gitStatusBefore = 'unreadable'
    } finally {
        Pop-Location
    }

    function New-HDTBootImageScratchWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a scratch workspace under C:\HDTLab\scratch that this file owns.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Root
        )

        # An explicit -LiteralPath to a directory this file created, under
        # C:\HDTLab\scratch - one of the three locations CLAUDE.md permits.
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }

        foreach ($folder in @('', 'Control', 'Boot', 'Logs', 'Drivers', 'Modules\MyVendorTools')) {
            $target = $Root
            if (-not [string]::IsNullOrEmpty($folder)) { $target = Join-Path -Path $Root -ChildPath $folder }
            New-Item -Path $target -ItemType Directory -Force | Out-Null
        }

        $workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-INTEGRATION
name: HDT boot image integration workspace
deployRoot: \Share
logLevel: Info
credential:
  username: HDTLAB\svc-hdt-deploy
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  extraContent:
    - source: Modules\MyVendorTools
      destination: \HDT\Modules\MyVendorTools
'@

        [System.IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath 'workspace.yaml'),
            $workspaceYaml, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath 'rules.yaml'),
            "schemaVersion: 1`nrules: []`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath 'Modules\MyVendorTools\Tool.psm1'),
            "function Get-HDTVendorTool { 'vendor' }`n", (New-Object System.Text.UTF8Encoding($false)))

        $secure = New-Object -TypeName System.Security.SecureString
        foreach ($character in $script:secret.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        Set-HDTShareCredential -WorkspaceRoot $Root `
            -Credential (New-Object System.Management.Automation.PSCredential 'HDTLAB\svc-hdt-deploy', $secure) `
            -Confirm:$false | Out-Null
    }

    if (-not $script:skipBuild) {
        New-HDTBootImageScratchWorkspace -Root $script:workspaceRoot

        $started = Get-Date
        $script:buildResult = Update-HDTBootImage -WorkspaceRoot $script:workspaceRoot `
            -ScratchPath $script:workPath -Confirm:$false
        $script:buildSecond = [int] ((Get-Date) - $started).TotalSeconds

        $script:manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:manifestPath))

        # THE READ-ONLY RE-MOUNT. Everything in 'what is inside it' is asserted
        # from the files themselves, not from the build's own claims.
        if (Test-Path -LiteralPath $script:inspectPath) {
            Remove-Item -LiteralPath $script:inspectPath -Recurse -Force
        }
        New-Item -Path $script:inspectPath -ItemType Directory -Force | Out-Null

        Mount-WindowsImage -ImagePath $script:wimPath -Index 1 -Path $script:inspectPath -ReadOnly | Out-Null
    }
}

AfterAll {
    # Runs even when the tests failed, which is the whole point.

    if (-not [string]::IsNullOrEmpty($script:inspectPath)) {
        # Filtered to THIS FILE'S OWN mount paths and nothing else. An unfiltered
        # Get-WindowsImage -Mounted | Dismount-WindowsImage would dismount
        # whatever the developer had open.
        foreach ($row in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
            $path = [string] $row.Path

            if ($path -ne $script:inspectPath -and $path -ne (Join-Path -Path $script:workPath -ChildPath 'mount')) {
                continue
            }

            try { Dismount-WindowsImage -Path $path -Discard -ErrorAction Stop | Out-Null } catch { $null = $_ }
        }
    }

    if (-not [string]::IsNullOrEmpty($script:isoPath)) {
        $attached = Get-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue
        if ($null -ne $attached -and $attached.Attached) {
            Dismount-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # The artifacts stay for inspection unless the caller asked for a clean-up,
    # mirroring the E2E's HDT_KEEP_LAB_VM.
    if ($env:HDT_KEEP_BOOT_IMAGE -ne '1') {
        foreach ($path in @($script:inspectPath, $script:workPath, $script:skipWorkPath)) {
            if ([string]::IsNullOrEmpty($path)) { continue }

            # -LiteralPath to a specific directory this file created, under
            # C:\HDTLab\scratch. Never a variable that could name anything else.
            if ($path -like 'C:\HDTLab\scratch\bootimage\*' -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'the WIM it built' -Skip:$script:skipBuild -Tag 'Slow' {

    It 'exists at Boot\HDTPE_x64.wim' {
        Test-Path -LiteralPath $script:wimPath -PathType Leaf | Should -BeTrue
    }

    It 'is substantially larger than winpe.wim' {
        # SPIKES S1 got 480 MB from nine cabs; the ADK's own winpe.wim is
        # 340 134 390 bytes on disk. A 340 MB result means nothing was applied,
        # and that is a build that would look green and boot into a WinPE with
        # no PowerShell in it.
        (Get-Item -LiteralPath $script:wimPath).Length | Should -BeGreaterThan 400MB
    }

    It 'reports one index' {
        @(Get-WindowsImage -ImagePath $script:wimPath).Count | Should -Be 1
    }

    It 'reports the size and hash the build claimed' {
        $script:buildResult.WimSizeBytes | Should -Be (Get-Item -LiteralPath $script:wimPath).Length
        $script:buildResult.WimSha256 |
            Should -BeExactly (Get-FileHash -LiteralPath $script:wimPath -Algorithm SHA256).Hash
    }
}

Describe 'what is inside it' -Skip:$script:skipBuild -Tag 'Slow' {

    It 'has all nine optional components installed' {
        $package = @(Get-WindowsPackage -Path $script:inspectPath)

        foreach ($row in @($script:manifest.optionalComponents)) {
            $name = [string] $row.name

            $match = @($package | Where-Object { [string] $_.PackageName -like ($name + '*') })

            $match.Count | Should -BeGreaterThan 0 -Because "the manifest claims $name was applied"
            @($match | Where-Object { [string] $_.PackageState -eq 'Installed' }).Count |
                Should -BeGreaterThan 0 -Because "$name must be Installed, not merely present"
        }
    }

    It 'has the en-us pack for every component that ships one' {
        $package = @(Get-WindowsPackage -Path $script:inspectPath)

        $withLanguage = @($script:manifest.optionalComponents |
                Where-Object { -not [string]::IsNullOrEmpty([string] $_.languageCab) })

        $withLanguage.Count | Should -BeGreaterThan 0 -Because 'a build with no language packs at all proves nothing here'

        foreach ($row in $withLanguage) {
            $name = [string] $row.name

            @($package | Where-Object {
                    [string] $_.PackageName -like ($name + '*') -and [string] $_.PackageName -like '*en-US*'
                }).Count | Should -BeGreaterThan 0 -Because "$name's en-us pack must be in the image"
        }
    }

    It 'has a startnet.cmd that runs wpeinit and then Start-HDTDeployment.ps1' {
        # THE PHASE'S CENTRAL ASSERTION AT THE FILE LEVEL. Read out of a MOUNTED
        # IMAGE and compared line by line with the pure function that generated
        # it, so this is evidence rather than a claim.
        $path = Join-Path -Path $script:inspectPath -ChildPath 'Windows\System32\startnet.cmd'

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

        $actual = [System.IO.File]::ReadAllText($path)
        $expected = & (Get-Module -Name Hephaestus) { Get-HDTStartnetScript }

        $actual | Should -BeExactly $expected

        $line = @($actual.TrimEnd("`r", "`n") -split "`r`n")
        $line.Count | Should -Be 5
        $line[3] | Should -BeExactly 'wpeinit'
        $line[4] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
    }

    It 'wrote startnet.cmd without a byte order mark' {
        # cmd.exe reading a BOM as a command is a class of failure that produces
        # no useful message at all.
        $path = Join-Path -Path $script:inspectPath -ChildPath 'Windows\System32\startnet.cmd'
        $byte = [System.IO.File]::ReadAllBytes($path)

        $byte[0] | Should -Not -Be 0xEF
    }

    It 'has the engine module at HDT\Modules\Hephaestus' {
        $manifestFile = Join-Path -Path $script:inspectPath -ChildPath 'HDT\Modules\Hephaestus\Hephaestus.psd1'

        Test-Path -LiteralPath $manifestFile -PathType Leaf | Should -BeTrue

        $staged = Import-PowerShellDataFile -Path $manifestFile
        [string] $staged.ModuleVersion | Should -BeExactly ([string] (Get-Module -Name Hephaestus).Version)
    }

    It 'excludes Payload from the staged module tree' {
        Test-Path -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'HDT\Modules\Hephaestus\Payload') |
            Should -BeFalse
    }

    It 'has powershell-yaml at HDT\Modules\powershell-yaml' {
        $base = Join-Path -Path $script:inspectPath -ChildPath 'HDT\Modules\powershell-yaml'

        Test-Path -LiteralPath $base -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $base -ChildPath 'powershell-yaml.psd1') -PathType Leaf | Should -BeTrue

        # net47 is the flavour SPIKES S9.1 proved loads against WinPE-NetFx
        # inside a real WinPE. A powershell-yaml with only netstandard in it
        # would import on the desk and fail in the image, and the DLL is the file
        # that actually loads - a folder that exists and is empty would not.
        #
        # IT IS UNDER lib\, NOT AT THE MODULE ROOT. powershell-yaml 0.4.12 ships
        # lib\net47\ and lib\netstandard2.1\; the first draft of this assertion
        # looked for <base>\net47 and was the one test this file's first real run
        # turned red.
        Test-Path -LiteralPath (Join-Path -Path $base -ChildPath 'lib\net47\YamlDotNet.dll') -PathType Leaf |
            Should -BeTrue
    }

    It 'has Start-HDTDeployment.ps1 at HDT\' {
        Test-Path -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'HDT\Start-HDTDeployment.ps1') -PathType Leaf |
            Should -BeTrue
    }

    It 'has Start-HDTResume.ps1 at HDT\' {
        # The full-OS leg is staged FROM the boot image TO the target, so it has
        # to be here even though nothing in WinPE runs it.
        Test-Path -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'HDT\Start-HDTResume.ps1') -PathType Leaf |
            Should -BeTrue
    }

    It 'has the extraContent the workspace declared' {
        Test-Path -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'HDT\Modules\MyVendorTools\Tool.psm1') -PathType Leaf |
            Should -BeTrue
    }

    It 'has a bootstrap.json that Get-HDTBootstrapConfiguration accepts' {
        $bootstrap = Get-HDTBootstrapConfiguration -Path (Join-Path -Path $script:inspectPath -ChildPath 'HDT\bootstrap.json')

        $bootstrap.WorkspaceId | Should -BeExactly 'HDT-LAB-INTEGRATION'
        $bootstrap.Provider | Should -BeExactly 'Local'
        $bootstrap.HasCredential | Should -BeTrue
    }

    It 'carries the volume-relative deployRoot into the image unchanged' {
        $bootstrap = Get-HDTBootstrapConfiguration -Path (Join-Path -Path $script:inspectPath -ChildPath 'HDT\bootstrap.json')

        $bootstrap.DeployRoot | Should -BeExactly '\Share'
    }

    It 'has no share credential in plain text anywhere under HDT\' {
        # DESIGN 6.3 promises obfuscation. This is the test that it was actually
        # applied, rather than the password being written straight into
        # bootstrap.json by an implementation that meant to protect it.
        $hit = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'HDT') -Recurse -File |
                Where-Object { $_.Length -lt 2MB } |
                Where-Object {
                    $text = ''
                    try { $text = [System.IO.File]::ReadAllText($_.FullName) } catch { $text = '' }
                    $text.Contains($script:secret)
                })

        @($hit | ForEach-Object { $_.FullName }) | Should -BeNullOrEmpty
    }

    It 'has PowerShell in the image' {
        # The single file the whole engine depends on. WinPE-PowerShell put it
        # there; if this is absent, every other assertion above is about an image
        # that cannot run HDT.
        Test-Path -LiteralPath (Join-Path -Path $script:inspectPath -ChildPath 'Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -PathType Leaf |
            Should -BeTrue
    }
}

Describe 'the ISO it built' -Skip:$script:skipBuild -Tag 'Slow' {

    It 'exists at Boot\HDTPE_x64.iso' {
        Test-Path -LiteralPath $script:isoPath -PathType Leaf | Should -BeTrue
    }

    It 'is larger than the WIM' {
        (Get-Item -LiteralPath $script:isoPath).Length |
            Should -BeGreaterThan (Get-Item -LiteralPath $script:wimPath).Length
    }

    It 'contains a boot.wim that hashes identical to the standalone WIM' {
        # DESIGN 6.1.1, AND ROADMAP M4 NAMES THIS TEST EXPLICITLY. "Because both
        # artifacts come from one build, a bug reproduced from the ISO is a bug
        # in the PXE path." That equivalence is what makes the ISO worth
        # generating every time, and it is the property the whole debugging
        # story rests on.
        $wimHash = (Get-FileHash -LiteralPath $script:wimPath -Algorithm SHA256).Hash

        $letter = ''
        try {
            Mount-DiskImage -ImagePath $script:isoPath -Access ReadOnly -ErrorAction Stop | Out-Null
            $letter = [string] (Get-DiskImage -ImagePath $script:isoPath | Get-Volume).DriveLetter

            $letter | Should -Not -BeNullOrEmpty

            $insidePath = '{0}:\sources\boot.wim' -f $letter
            Test-Path -LiteralPath $insidePath -PathType Leaf | Should -BeTrue

            (Get-FileHash -LiteralPath $insidePath -Algorithm SHA256).Hash | Should -BeExactly $wimHash
        } finally {
            Dismount-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It 'records that equality in the manifest' {
        # THREE-WAY. A manifest that agreed with itself but not with the disk
        # would be worse than none, because an operator would trust it.
        $wimHash = (Get-FileHash -LiteralPath $script:wimPath -Algorithm SHA256).Hash

        $script:manifest.artifacts.wim.sha256 | Should -BeExactly $wimHash
        $script:manifest.artifacts.isoBootWimSha256 | Should -BeExactly $wimHash
    }

    It 'contains bootmgr.efi and EFI\Boot\bootx64.efi' {
        $letter = ''
        try {
            Mount-DiskImage -ImagePath $script:isoPath -Access ReadOnly -ErrorAction Stop | Out-Null
            $letter = [string] (Get-DiskImage -ImagePath $script:isoPath | Get-Volume).DriveLetter

            Test-Path -LiteralPath ('{0}:\bootmgr.efi' -f $letter) -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath ('{0}:\EFI\Boot\bootx64.efi' -f $letter) -PathType Leaf | Should -BeTrue
        } finally {
            Dismount-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It 'contains EFI\Microsoft\Boot\BCD' {
        $letter = ''
        try {
            Mount-DiskImage -ImagePath $script:isoPath -Access ReadOnly -ErrorAction Stop | Out-Null
            $letter = [string] (Get-DiskImage -ImagePath $script:isoPath | Get-Volume).DriveLetter

            Test-Path -LiteralPath ('{0}:\EFI\Microsoft\Boot\BCD' -f $letter) -PathType Leaf | Should -BeTrue
        } finally {
            Dismount-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It 'was built with efisys_noprompt.bin' {
        # SPIKES S3: a VM booted an efisys_noprompt.bin ISO straight into WinPE
        # with no keypress, Generation 2, Secure Boot on. 05-05 depends on that.
        $script:manifest.artifacts.iso.noPromptForKey | Should -BeTrue
        $script:manifest.artifacts.iso.firmware | Should -BeExactly 'UEFI'
    }
}

Describe 'the manifest' -Skip:$script:skipBuild -Tag 'Slow' {

    It 'records hashes that match the files on disk' {
        $script:manifest.artifacts.wim.sha256 |
            Should -BeExactly (Get-FileHash -LiteralPath $script:wimPath -Algorithm SHA256).Hash
        $script:manifest.artifacts.iso.sha256 |
            Should -BeExactly (Get-FileHash -LiteralPath $script:isoPath -Algorithm SHA256).Hash
    }

    It 'records sizes that match the files on disk' {
        $script:manifest.artifacts.wim.sizeBytes | Should -Be (Get-Item -LiteralPath $script:wimPath).Length
        $script:manifest.artifacts.iso.sizeBytes | Should -Be (Get-Item -LiteralPath $script:isoPath).Length
    }

    It 'records the ADK this machine has' {
        $script:manifest.adk.root | Should -BeExactly (Get-HDTAdkPath -Asset Root)
        $script:manifest.adk.oscdimg | Should -BeExactly (Get-HDTAdkPath -Asset Oscdimg)
        $script:manifest.adk.winpeWim | Should -BeExactly (Get-HDTAdkPath -Asset WinPeWim)
    }

    It 'records the nine components it applied' {
        @($script:manifest.optionalComponents).Count | Should -Be 9
        @($script:manifest.optionalComponents | ForEach-Object { $_.name })[0] | Should -BeExactly 'WinPE-WMI'
    }

    It 'carries no secret' {
        [System.IO.File]::ReadAllText($script:manifestPath) | Should -Not -BeLike ('*' + $script:secret + '*')
    }
}

Describe '-SkipIso' -Skip:$script:skipBuild -Tag 'Slow' {

    BeforeAll {
        # A SECOND FULL BUILD. The implementation exports from its own scratch
        # WIM, so there is no cheap way to reuse the first build's artifacts
        # without pretending the second build did work it did not do.
        # tests/integration/README.md records the measured cost.
        New-HDTBootImageScratchWorkspace -Root $script:skipWorkspaceRoot

        $started = Get-Date
        $script:skipResult = Update-HDTBootImage -WorkspaceRoot $script:skipWorkspaceRoot `
            -ScratchPath $script:skipWorkPath -SkipIso -Confirm:$false
        $script:skipSecond = [int] ((Get-Date) - $started).TotalSeconds
    }

    It 'produced a WIM' {
        Test-Path -LiteralPath (Join-Path -Path $script:skipWorkspaceRoot -ChildPath 'Boot\HDTPE_x64.wim') -PathType Leaf |
            Should -BeTrue
    }

    It 'produced no ISO' {
        Test-Path -LiteralPath (Join-Path -Path $script:skipWorkspaceRoot -ChildPath 'Boot\HDTPE_x64.iso') |
            Should -BeFalse
    }

    It 'still wrote a manifest' {
        Test-Path -LiteralPath (Join-Path -Path $script:skipWorkspaceRoot -ChildPath 'Boot\HDTPE_x64.manifest.json') -PathType Leaf |
            Should -BeTrue
    }

    It 'recorded the ISO as skipped' {
        $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText(
            (Join-Path -Path $script:skipWorkspaceRoot -ChildPath 'Boot\HDTPE_x64.manifest.json')))

        $manifest.artifacts.iso.skipped | Should -BeTrue
        [string] $manifest.artifacts.iso.path | Should -BeExactly ''
        @($script:skipResult.Skipped) | Should -Be @('Iso')
    }
}

Describe 'the lab and this machine are unharmed' -Skip:$script:skipBuild -Tag 'Slow' {

    It 'left no image mounted at either scratch path' {
        $mounted = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object {
                    [string] $_.Path -eq (Join-Path -Path $script:workPath -ChildPath 'mount') -or
                    [string] $_.Path -eq (Join-Path -Path $script:skipWorkPath -ChildPath 'mount')
                })

        @($mounted | ForEach-Object { $_.Path }) | Should -BeNullOrEmpty
    }

    It 'left no disk image attached' {
        $attached = Get-DiskImage -ImagePath $script:isoPath -ErrorAction SilentlyContinue

        if ($null -ne $attached) { $attached.Attached | Should -BeFalse }
    }

    It 'wrote nothing into the repository' {
        # git status --porcelain, compared with the snapshot taken before the
        # build. A build that scattered a mount folder into the working tree
        # would show up here rather than in somebody's next commit.
        Push-Location -LiteralPath $script:repoRoot
        try {
            $after = (@(& git status --porcelain 2>$null) -join "`n")
        } finally {
            Pop-Location
        }

        $after | Should -BeExactly $script:gitStatusBefore
    }

    It 'left this host disk 0 as it found it' {
        $disk = Get-Disk -Number 0 -ErrorAction SilentlyContinue
        $after = 'unreadable'
        if ($null -ne $disk) { $after = '{0}|{1}|{2}' -f $disk.PartitionStyle, $disk.IsBoot, $disk.IsSystem }

        $after | Should -BeExactly $script:disk0Before
    }

    It 'created nothing under C:\HDTLab\vms' {
        # This file has no business there at all; the assertion is that nothing
        # happened, which is what makes it safe to make.
        if (Test-Path -LiteralPath 'C:\HDTLab\vms') {
            @(Get-ChildItem -LiteralPath 'C:\HDTLab\vms' -Filter 'bootimage*' -ErrorAction SilentlyContinue) |
                Should -BeNullOrEmpty
        }
    }
}
