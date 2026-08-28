# Import-HDTBootImageToWds - DESIGN 6.1's "HDT does not ship a PXE server; WDS
# serves the WIM", with replace-in-place semantics.
#
# ROADMAP M4 NAMES ONE TEST IN THIS FILE: "WDS import replacing rather than
# duplicating an existing image". Everything else here exists to make that one
# legible when it fails.
#
# THE ORDERED JOURNAL IS THE ASSERTION, not a count of calls. Replace-in-place
# means GetBootImage, then RemoveBootImage, then ImportBootImage, IN THAT ORDER:
# an import before the remove would leave two images for a moment and then delete
# the new one, and a call-count assertion cannot tell those apart.
#
# THE REAL ADAPTER APPEARS EXACTLY ONCE IN THIS FILE, in 'reports the missing WDS
# module as a dependency error'. There is no WDS on this host - it is Windows 11
# Pro, and WDS is a Windows Server role - and PROJECT.md confines a PXE
# responder to the isolated 'HDT Lab' switch. So that refusal is the ONE WDS fact this machine
# can prove, it is proven against the real New-HDTWdsService rather than
# simulated, and everything else is asserted against the fake.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:wimPath = 'C:\HDTLab\Share\Boot\HDTPE_x64.wim'

    $script:newFileSystem = {
        return (New-HDTFakeFileSystem -File @{ $script:wimPath = 'MSWIM-ish bytes' })
    }
}

Describe 'Import-HDTBootImageToWds' {

    Context 'when no image of that name exists' {

        BeforeEach {
            $script:journal = [System.Collections.ArrayList]::new()
            $script:fs = & $script:newFileSystem
            $script:wds = New-HDTFakeWdsService -Journal $script:journal
        }

        It 'imports when no image of that name exists' {
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false | Out-Null

            @($script:journal | ForEach-Object { [string] $_.Operation }) |
                Should -Be @('GetBootImage', 'ImportBootImage')
        }

        It 'reports Replaced false and no previous version' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            $result.Replaced | Should -BeFalse
            [string] $result.PreviousVersion | Should -BeExactly ''
        }

        It 'defaults the image name to the WIM base name' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            [string] $result.ImageName | Should -BeExactly 'HDTPE_x64'
            @($script:wds.Operations | Where-Object { $_.Operation -eq 'ImportBootImage' })[0].Arguments[1] |
                Should -BeExactly 'HDTPE_x64'
        }

        It 'passes the name it was given instead' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -ImageName 'HDT Boot (production)' `
                -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            [string] $result.ImageName | Should -BeExactly 'HDT Boot (production)'
        }

        It 'defaults the architecture to x64' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            [string] $result.Architecture | Should -BeExactly 'x64'
            @($script:wds.Operations)[0].Arguments[0] | Should -BeExactly 'x64'
        }

        It 'returns the path it imported' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            [string] $result.Path | Should -BeExactly $script:wimPath
        }
    }

    Context 'when one does' {

        BeforeEach {
            $script:journal = [System.Collections.ArrayList]::new()
            $script:fs = & $script:newFileSystem
            $script:wds = New-HDTFakeWdsService -Journal $script:journal -Image @(
                [pscustomobject] @{ ImageName = 'HDTPE_x64'; Architecture = 'x64'; FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' }
                [pscustomobject] @{ ImageName = 'LegacyPE'; Architecture = 'x64'; FileName = 'LegacyPE.wim'; Version = '10.0.19041.1' })
        }

        It 'removes and re-imports when one does' {
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false | Out-Null

            @($script:journal | ForEach-Object { [string] $_.Operation }) |
                Should -Be @('GetBootImage', 'RemoveBootImage', 'ImportBootImage')
        }

        It 'leaves one image after importing twice' {
            # ROADMAP M4's NAMED TEST. Two imports of the same boot image leave
            # ONE image on the server, because the second replaced the first.
            # Without the RemoveBootImage leg this reads 2 - and a fleet PXE
            # booting from a menu with two identical entries is exactly the MDT
            # operational problem DESIGN 6.1 says replace-in-place solves.
            $wds = New-HDTFakeWdsService

            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $wds -FileSystem $script:fs -Confirm:$false | Out-Null
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $wds -FileSystem $script:fs -Confirm:$false | Out-Null

            @($wds.GetBootImage('x64')).Count | Should -Be 1
        }

        It 'leaves the images it was not asked about alone' {
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false | Out-Null

            @($script:wds.GetBootImage('x64') | ForEach-Object { [string] $_.ImageName }) |
                Should -Contain 'LegacyPE'
        }

        It 'matches the existing image name case-insensitively' {
            $wds = New-HDTFakeWdsService -Image @(
                [pscustomobject] @{ ImageName = 'hdtpe_X64'; Architecture = 'x64'; FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' })

            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $wds -FileSystem $script:fs -Confirm:$false

            $result.Replaced | Should -BeTrue
            @($wds.GetOperationName()) | Should -Be @('GetBootImage', 'RemoveBootImage', 'ImportBootImage')
        }

        It 'ignores an image of the same name on another architecture' {
            $wds = New-HDTFakeWdsService -Image @(
                [pscustomobject] @{ ImageName = 'HDTPE_x64'; Architecture = 'arm64'; FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' })

            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $wds -FileSystem $script:fs -Confirm:$false

            $result.Replaced | Should -BeFalse
            @($wds.GetOperationName()) | Should -Be @('GetBootImage', 'ImportBootImage')
        }

        It 'reports Replaced true and the previous version' {
            $result = Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs -Confirm:$false

            $result.Replaced | Should -BeTrue
            [string] $result.PreviousVersion | Should -BeExactly '10.0.26100.1'
        }

        It 'logs what it threw away' {
            # AN ADMIN NEEDS TO KNOW WHAT WAS DELETED. This command removes a boot
            # image a fleet PXE boots from; a run that replaced one silently would
            # leave nobody able to say what the previous image was.
            $information = $null
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs `
                -Confirm:$false -InformationVariable information | Out-Null

            $text = (@($information | ForEach-Object { [string] $_.MessageData }) -join "`n")

            $text | Should -BeLike '*HDTPE_x64*'
            $text | Should -BeLike '*10.0.26100.1*'
        }

        It 'logs the import as well as the removal' {
            $information = $null
            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $script:wds -FileSystem $script:fs `
                -Confirm:$false -InformationVariable information | Out-Null

            @($information).Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'refusals' {

        It 'refuses a path that is not an existing wim' {
            $journal = [System.Collections.ArrayList]::new()
            $wds = New-HDTFakeWdsService -Journal $journal
            $fs = New-HDTFakeFileSystem

            { Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim' -WdsService $wds -FileSystem $fs -Confirm:$false } |
                Should -Throw '*HDTPE_x64.wim*'

            # AND IT CALLED NOTHING. A refusal that had already asked the server
            # for its image list would be a refusal that touched production.
            @($journal).Count | Should -Be 0
        }

        It 'names Update-HDTBootImage when the wim is not there' {
            $fs = New-HDTFakeFileSystem

            { Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim' `
                    -WdsService (New-HDTFakeWdsService) -FileSystem $fs -Confirm:$false } |
                Should -Throw '*Update-HDTBootImage*'
        }

        It 'refuses a path that is not a wim at all' {
            $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\Share\Boot\HDTPE_x64.iso' = 'iso' }

            { Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.iso' `
                    -WdsService (New-HDTFakeWdsService) -FileSystem $fs -Confirm:$false } |
                Should -Throw '*.wim*'
        }

        It 'throws HDTConfigurationError for a missing wim' {
            $record = $null
            try {
                Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim' `
                    -WdsService (New-HDTFakeWdsService) -FileSystem (New-HDTFakeFileSystem) -Confirm:$false
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            [string] $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'ShouldProcess' {

        It 'calls nothing under -WhatIf' {
            # It removes a boot image a fleet PXE boots from, so SupportsShouldProcess
            # is not decoration (CLAUDE.md hard rule 6).
            $journal = [System.Collections.ArrayList]::new()
            $wds = New-HDTFakeWdsService -Journal $journal -Image @(
                [pscustomobject] @{ ImageName = 'HDTPE_x64'; Architecture = 'x64'; FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' })

            Import-HDTBootImageToWds -Path $script:wimPath -WdsService $wds -FileSystem (& $script:newFileSystem) -WhatIf | Out-Null

            @($journal).Count | Should -Be 0
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name 'Import-HDTBootImageToWds').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'the real adapter, on a host that has no WDS' {

        It 'reports the missing WDS module as a dependency error' {
            # THE ONE WDS FACT THIS MACHINE CAN PROVE, and it is proven against
            # the REAL New-HDTWdsService rather than simulated. This host is
            # Windows 11 Pro; the WDS PowerShell module ships with the Windows
            # Server role. If this test ever starts failing on a machine that has
            # WDS, that is a machine where the rest of the WDS path can finally be
            # exercised for real - which would be news, not a defect.
            if (@(Get-Module -ListAvailable -Name 'WDS' -ErrorAction SilentlyContinue).Count -gt 0) {
                Set-ItResult -Skipped -Because 'this machine has the WDS module, so its absence cannot be asserted here'
                return
            }

            $record = $null
            try { New-HDTWdsService } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            [string] $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
            [string] $record.Exception.Message | Should -BeLike '*WDS*'
            [string] $record.Exception.Message | Should -BeLike '*Windows Server*'
        }
    }
}
