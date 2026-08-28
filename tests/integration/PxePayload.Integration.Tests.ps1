# THE DEMONSTRATION THAT STANDS IN FOR THE WDS ONE, AND WHY IT HAS TO.
#
# ROADMAP M4's second exit clause is "a physical or virtual machine PXE-boots the
# same image from WDS and deploys". IT IS NOT MET, AND IT CANNOT BE MET HERE:
#
#   * There is no WDS on this host. It is Windows 11 Pro; the WDS PowerShell
#     module and the wdsutil.exe binary ship with a Windows SERVER role.
#   * Standing one up is constrained by PROJECT.md's lab safety rules. Rule 3
#     puts PXE/WDS testing on the isolated 'HDT Lab' switch only, because a PXE
#     responder answers every machine on its segment - on a shared switch it
#     would answer machines that are not part of the test, and anything else
#     answering there would silently invalidate the run.
#
# So NO WDS IMPORT HAS EVER EXECUTED, anywhere in this repository. What is proven
# instead is New-HDTPxePayload's staging completeness against the REAL ADK media
# tree and the REAL boot WIM 05-04 built: every file a TFTP/HTTP stack needs is
# there and its bytes verify.
#
# THAT IS NOT THE SAME CLAIM AS "A MACHINE WILL PXE BOOT FROM THIS", and this
# file will not make the larger one. The BCD staged here is the ADK media
# template, which describes booting sources\boot.wim from removable media; a
# TFTP/HTTP stack generally needs its own store and its own device element.
# Claiming staging completeness is honest. Claiming bootability would not be, and
# the difference is the whole value of this phase.
#
# EVERY SKIP CONDITION IS RECOMPUTED INSIDE BeforeAll (SPIKES S9.15).

BeforeDiscovery {
    $script:discoveryAdk = $false
    try {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:discoveryAdk = $true
    } catch {
        $script:discoveryAdk = $false
    }

    $script:discoveryWim = Test-Path -LiteralPath 'C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.wim' -PathType Leaf

    $script:skipPayload = (-not $script:discoveryAdk) -or (-not $script:discoveryWim)

    if ($script:skipPayload) {
        Write-Warning ("PxePayload.Integration.Tests.ps1 is SKIPPED. It stages the REAL ADK media tree (currently resolvable: {0}) and the REAL boot WIM at C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.wim (currently present: {1}). Run ./build.ps1 -Task integration to build that WIM with BootImage.Integration.Tests.ps1 first, or install the Windows ADK with the Windows PE add-on." -f
            $script:discoveryAdk, $script:discoveryWim)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # RECOMPUTED, not borrowed from BeforeDiscovery (SPIKES S9.15).
    $script:hasAdk = $false
    try {
        [void] (Get-HDTAdkPath -Asset WinPeMedia -ErrorAction Stop)
        $script:hasAdk = $true
    } catch {
        $script:hasAdk = $false
    }

    $script:bootWorkspace = 'C:\HDTLab\scratch\bootimage\Share'
    $script:bootWim = Join-Path -Path $script:bootWorkspace -ChildPath 'Boot\HDTPE_x64.wim'
    $script:bootManifest = Join-Path -Path $script:bootWorkspace -ChildPath 'Boot\HDTPE_x64.manifest.json'

    $script:hasWim = Test-Path -LiteralPath $script:bootWim -PathType Leaf
    $script:skipPayload = (-not $script:hasAdk) -or (-not $script:hasWim)

    # Under C:\HDTLab\scratch, created by this file and removed by it - one of
    # the three locations CLAUDE.md permits a delete.
    $script:payloadRoot = 'C:\HDTLab\scratch\pxe'

    $script:result = $null
    $script:mediaRoot = ''
    $script:workspaceBefore = @()
    $script:stageSecond = 0

    if (-not $script:skipPayload) {
        $script:mediaRoot = Get-HDTAdkPath -Asset WinPeMedia

        # What the workspace looked like before, so 'wrote nothing into the
        # workspace' is a comparison rather than an assertion about intent.
        $script:workspaceBefore = @(Get-ChildItem -LiteralPath $script:bootWorkspace -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { '{0}|{1}' -f $_.FullName, $_.Length } | Sort-Object)

        if (Test-Path -LiteralPath $script:payloadRoot) {
            Remove-Item -LiteralPath $script:payloadRoot -Recurse -Force
        }

        $started = Get-Date
        $script:result = New-HDTPxePayload -WorkspaceRoot $script:bootWorkspace -Path $script:payloadRoot -Confirm:$false
        $script:stageSecond = [int] ((Get-Date) - $started).TotalSeconds

        Write-Information ("staged {0} file(s) into {1} in {2}s; Complete={3}" -f
            @($script:result.File).Count, $script:payloadRoot, $script:stageSecond, $script:result.Complete) -InformationAction Continue
    }
}

AfterAll {
    # Runs on failure too. An explicit -LiteralPath to the directory this file
    # created, under C:\HDTLab\scratch, and nowhere else.
    if ($env:HDT_KEEP_PXE_PAYLOAD -ne '1') {
        if ($script:payloadRoot -eq 'C:\HDTLab\scratch\pxe' -and (Test-Path -LiteralPath $script:payloadRoot)) {
            Remove-Item -LiteralPath $script:payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the payload it staged' -Skip:$script:skipPayload -Tag 'Slow' {

    It 'stages every required file' {
        # ONE LIST, read out of the command. The unit suite asserts this against
        # a fake filesystem; here the same table is checked against files that
        # exist on this disk.
        foreach ($row in @(New-HDTPxePayload -ListRequired)) {
            if (-not $row.Required) { continue }

            $full = Join-Path -Path $script:payloadRoot -ChildPath ([string] $row.Destination)

            if ([string] $row.Kind -eq 'Directory') {
                @(Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue).Count |
                    Should -BeGreaterThan 0 -Because ("{0} is a declared directory" -f $row.Destination)
                continue
            }

            Test-Path -LiteralPath $full -PathType Leaf |
                Should -BeTrue -Because ("{0} is declared required" -f $row.Destination)
        }
    }

    It 'stages a boot.sdi whose bytes match the ADK source' {
        $source = Join-Path -Path $script:mediaRoot -ChildPath 'Boot\boot.sdi'
        $staged = Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\boot.sdi'

        (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash |
            Should -BeExactly (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }

    It 'stages a bootmgr.exe whose bytes match the ADK bootmgr' {
        $source = Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr'
        $staged = Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\bootmgr.exe'

        (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash |
            Should -BeExactly (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }

    It 'stages a bootmgfw.efi whose bytes match the ADK bootmgr.efi' {
        $source = Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr.efi'
        $staged = Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\bootmgfw.efi'

        (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash |
            Should -BeExactly (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }

    It 'stages a boot WIM whose hash matches the manifest' {
        # THIS TIES THE PXE PAYLOAD TO DESIGN 6.1.1. The manifest records the
        # hash of the WIM the build exported, and SPIKES S11.2 records that the
        # same hash is carried by sources\boot.wim inside the ISO. So the file a
        # TFTP server would serve, the file the ISO boots, and the standalone WIM
        # are one set of bytes - which is what makes "a bug reproduced from the
        # ISO is a bug in the PXE path" true rather than hopeful.
        $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:bootManifest))
        $staged = Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\Images\HDTPE_x64.wim'

        (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash |
            Should -BeExactly ([string] $manifest.artifacts.wim.sha256)
        [string] $manifest.artifacts.isoBootWimSha256 |
            Should -BeExactly ([string] $manifest.artifacts.wim.sha256)
    }

    It 'stages the fonts' {
        $staged = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\Fonts') -File)
        $source = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:mediaRoot -ChildPath 'Boot\Fonts') -File)

        @($staged | ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @($source | ForEach-Object { $_.Name } | Sort-Object)
    }

    It 'stages the manifest beside the image' {
        Test-Path -LiteralPath (Join-Path -Path $script:payloadRoot -ChildPath 'Boot\x64\HDTPE_x64.manifest.json') -PathType Leaf |
            Should -BeTrue
    }

    It 'reports Complete' {
        $script:result.Complete | Should -BeTrue -Because (
            'missing: {0}' -f ((@($script:result.Missing) -join ', ')))
    }

    It 'reports a hash for every row that matches the file on disk' {
        foreach ($row in @($script:result.File)) {
            $full = Join-Path -Path $script:payloadRoot -ChildPath ([string] $row.Destination)

            [string] $row.Sha256 | Should -BeExactly (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
            [long] $row.SizeBytes | Should -Be (Get-Item -LiteralPath $full).Length
        }
    }

    It 'wrote nothing into the workspace' {
        $after = @(Get-ChildItem -LiteralPath $script:bootWorkspace -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { '{0}|{1}' -f $_.FullName, $_.Length } | Sort-Object)

        ($after -join "`n") | Should -BeExactly ($script:workspaceBefore -join "`n")
    }
}

Describe 'what this file does NOT prove' -Skip:$script:skipPayload -Tag 'Slow' {

    It 'has no WDS on this host, and says so rather than working around it' {
        # ASSERTED, not commented. If a future machine grows a WDS module this
        # goes red, and that is the day the WDS leg can finally be run for real -
        # news rather than a defect.
        @(Get-Module -ListAvailable -Name 'WDS' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        Get-Command -Name 'wdsutil.exe' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'never network-booted the payload it just staged' {
        # There is nothing to assert here except the absence of the thing, and
        # the absence is the point: Complete means "staged and verified", not
        # "bootable". The source comment on New-HDTPxePayload, ROADMAP M4 and
        # 05-05-SUMMARY.md all say so in those words, and this test names the
        # files that must keep saying it.
        $source = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTPxePayload.ps1'
        $text = [System.IO.File]::ReadAllText($source)

        $text | Should -BeLike '*never been network-booted*'
    }
}
