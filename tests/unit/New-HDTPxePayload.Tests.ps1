# New-HDTPxePayload - DESIGN 6.1's other half: "For sites with an existing
# TFTP/HTTP stack instead of WDS, New-HDTPxePayload stages bootmgr, bootmgfw.efi,
# boot.sdi, the BCD, and the boot WIM into a directory to point that server at."
#
# COMPLETENESS IS CHECKED AGAINST ONE LIST, NOT TWO. The required set is a
# declared table inside the command, and -ListRequired hands that same table back
# - so this file asserts what the command declares rather than a second copy of
# it that could drift. A row added to the table without a copy landing turns this
# red; a row deleted from the table stops being asserted, which is why the count
# is pinned as well.
#
# WHAT 'Complete' MEANS, AND WHAT IT DOES NOT. Complete is "every declared file
# is staged and its bytes verify". It is NOT "a machine will PXE boot from this".
# The BCD staged here is the ADK media template, which describes booting
# sources\boot.wim from removable media; a TFTP/HTTP stack generally needs its
# own BCD store and its own device element, and NOTHING IN THIS REPOSITORY HAS
# EVER NETWORK-BOOTED THIS PAYLOAD - there is no WDS on this host and PROJECT.md
# forbids standing one up beside CM01's PXE responder.
#
# A HASH MISMATCH IS A FAILURE, NOT A WARNING. A truncated boot.sdi on a TFTP
# server is a machine that hangs at boot with no message on the screen and no
# line in any log.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:kitsRoot = 'C:\Kits\'
    $script:adkRoot = 'C:\Kits\Assessment and Deployment Kit'
    $script:mediaRoot = Join-Path -Path $script:adkRoot -ChildPath 'Windows Preinstallation Environment\amd64\Media'
    $script:workspace = 'C:\HDTLab\Share'
    $script:payloadPath = 'C:\HDTLab\pxe'

    # The ADK media tree as this machine actually ships it, captured from
    # C:\Program Files (x86)\Windows Kits\10\...\Windows Preinstallation
    # Environment\amd64\Media rather than invented (CLAUDE.md, Conventions).
    $script:adkFile = @{
        (Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr')                       = 'bootmgr bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr.efi')                   = 'bootmgr.efi bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'EFI\Boot\bootx64.efi')          = 'bootx64.efi bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'Boot\boot.sdi')                 = 'boot.sdi bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'Boot\BCD')                      = 'BCD bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'Boot\Fonts\wgl4_boot.ttf')      = 'wgl4 bytes'
        (Join-Path -Path $script:mediaRoot -ChildPath 'Boot\Fonts\segmono_boot.ttf')   = 'segmono bytes'
    }

    $script:workspaceFile = @{
        (Join-Path -Path $script:workspace -ChildPath 'Boot\HDTPE_x64.wim')           = 'the boot image'
        (Join-Path -Path $script:workspace -ChildPath 'Boot\HDTPE_x64.manifest.json') = '{ "schemaVersion": 1 }'
    }

    $script:newFileSystem = {
        param([string[]] $Omit)

        $file = @{}
        foreach ($key in @($script:adkFile.Keys)) {
            if (@($Omit) -contains $key) { continue }
            $file[$key] = $script:adkFile[$key]
        }
        foreach ($key in @($script:workspaceFile.Keys)) {
            if (@($Omit) -contains $key) { continue }
            $file[$key] = $script:workspaceFile[$key]
        }

        return (New-HDTFakeFileSystem -File $file)
    }

    $script:newRegistry = {
        return (New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot }
            })
    }

    $script:stage = {
        param([object] $FileSystem, [object] $Registry)

        return (New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -FileSystem $FileSystem -Registry $Registry -Confirm:$false)
    }
}

Describe 'New-HDTPxePayload' {

    Context 'the declared table' {

        It 'lists every file DESIGN 6.1 names' {
            $row = @(New-HDTPxePayload -ListRequired)

            $destination = @($row | ForEach-Object { [string] $_.Destination })

            $destination | Should -Contain 'Boot\x64\bootmgr.exe'
            $destination | Should -Contain 'Boot\x64\bootmgfw.efi'
            $destination | Should -Contain 'Boot\x64\boot.sdi'
            $destination | Should -Contain 'Boot\x64\BCD'
            $destination | Should -Contain 'Boot\x64\Fonts'
            $destination | Should -Contain 'Boot\x64\Images\HDTPE_x64.wim'
            $destination | Should -Contain 'Boot\x64\HDTPE_x64.manifest.json'
        }

        It 'has exactly eight rows' {
            # PINNED. -ListRequired is what the completeness assertion below reads,
            # so a table somebody emptied would make that assertion vacuous
            # (tests/helpers/README.md section 12) and this is the guard on it.
            @(New-HDTPxePayload -ListRequired).Count | Should -Be 8
        }

        It 'marks wdsmgfw.efi optional and everything else required' {
            $row = @(New-HDTPxePayload -ListRequired)

            @($row | Where-Object { -not $_.Required } | ForEach-Object { [string] $_.Destination }) |
                Should -Be @('Boot\x64\wdsmgfw.efi')
        }

        It 'takes the boot image name into the destinations' {
            $row = @(New-HDTPxePayload -ListRequired -BootImageName 'CustomPE')

            @($row | ForEach-Object { [string] $_.Destination }) | Should -Contain 'Boot\x64\Images\CustomPE.wim'
        }

        It 'uses the arm64 folder for arm64' {
            $row = @(New-HDTPxePayload -ListRequired -Architecture arm64)

            @($row | ForEach-Object { [string] $_.Destination }) | Should -Contain 'Boot\arm64\boot.sdi'
        }

        It 'names Fonts as a directory and the rest as files' {
            $row = @(New-HDTPxePayload -ListRequired)

            @($row | Where-Object { [string] $_.Kind -eq 'Directory' } | ForEach-Object { [string] $_.Destination }) |
                Should -Be @('Boot\x64\Fonts')
        }
    }

    Context 'staging' {

        BeforeEach {
            $script:fs = & $script:newFileSystem @()
            $script:registry = & $script:newRegistry
            $script:result = & $script:stage $script:fs $script:registry
        }

        It 'stages every required file in the declared table' {
            # ONE LIST. The table is read out of the command, not written again
            # here, so a row that was declared and never copied is a failure and a
            # row that was copied and never declared cannot hide.
            foreach ($row in @(New-HDTPxePayload -ListRequired)) {
                if (-not $row.Required) { continue }

                if ([string] $row.Kind -eq 'Directory') {
                    @($script:result.File | Where-Object { [string] $_.Destination -like (([string] $row.Destination) + '\*') }).Count |
                        Should -BeGreaterThan 0 -Because ("nothing was staged under {0}" -f $row.Destination)
                    continue
                }

                @($script:result.File | Where-Object { [string] $_.Destination -eq [string] $row.Destination }).Count |
                    Should -Be 1 -Because ("{0} is declared required" -f $row.Destination)
            }
        }

        It 'reports Complete true when they all landed' {
            $script:result.Complete | Should -BeTrue
        }

        It 'wrote every file it reports' {
            foreach ($row in @($script:result.File)) {
                $full = Join-Path -Path $script:payloadPath -ChildPath ([string] $row.Destination)
                $script:fs.TestPath($full) | Should -BeTrue -Because ("{0} is in the result" -f $row.Destination)
            }
        }

        It 'copies the boot WIM into Images\' {
            $script:fs.TestPath((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\Images\HDTPE_x64.wim')) |
                Should -BeTrue
        }

        It 'copies the manifest beside it' {
            $script:fs.TestPath((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\HDTPE_x64.manifest.json')) |
                Should -BeTrue
        }

        It 'stages the fonts' {
            $script:fs.TestPath((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\Fonts\wgl4_boot.ttf')) | Should -BeTrue
            $script:fs.TestPath((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\Fonts\segmono_boot.ttf')) | Should -BeTrue
        }

        It 'renames bootmgr to bootmgr.exe and bootmgr.efi to bootmgfw.efi' {
            # The ADK media tree names them bootmgr and bootmgr.efi; a TFTP root
            # wants bootmgr.exe and bootmgfw.efi. Naming that mapping in the table
            # is the whole reason the table has a Source column.
            $row = @($script:result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\bootmgr.exe' })
            [string] $row[0].Source | Should -BeExactly (Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr')

            $efi = @($script:result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\bootmgfw.efi' })
            [string] $efi[0].Source | Should -BeExactly (Join-Path -Path $script:mediaRoot -ChildPath 'bootmgr.efi')
        }

        It 'reports a size and a hash for every row' {
            foreach ($row in @($script:result.File)) {
                [long] $row.SizeBytes | Should -BeGreaterThan 0
                [string] $row.Sha256 | Should -Not -BeNullOrEmpty
            }
        }

        It 'verifies each copy by hash' {
            # The fake hashes the same bytes the real adapter would, so a copy
            # that landed is a copy whose hash equals the source's - and this
            # asserts the command actually compared them rather than reporting
            # the source's hash twice.
            @($script:fs.GetOperationName() | Where-Object { $_ -eq 'GetHash' }).Count |
                Should -BeGreaterOrEqual (2 * @($script:result.File).Count)
        }

        It 'wrote nothing into the workspace' {
            $written = @($script:fs.Operations |
                    Where-Object { @('WriteAllText', 'AppendAllText', 'RemoveItem') -contains [string] $_.Operation } |
                    ForEach-Object { [string] $_.Arguments[0] })

            $written += @($script:fs.Operations |
                    Where-Object { [string] $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [string] $_.Arguments[1] })

            foreach ($path in $written) {
                $path | Should -Not -BeLike ($script:workspace + '\*')
            }
        }
    }

    Context 'an optional file the ADK does not ship' {

        It 'ignores an optional file that the ADK does not ship' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:mediaRoot -ChildPath 'EFI\Boot\bootx64.efi'))

            $result = & $script:stage $fs (& $script:newRegistry)

            $result.Complete | Should -BeTrue
            @($result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\wdsmgfw.efi' }).Count | Should -Be 0
        }

        It 'records it as skipped rather than silently dropping it' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:mediaRoot -ChildPath 'EFI\Boot\bootx64.efi'))

            $result = & $script:stage $fs (& $script:newRegistry)

            @($result.Skipped) | Should -Contain 'Boot\x64\wdsmgfw.efi'
        }
    }

    Context 'a required source that is missing' {

        It 'reports Complete false when a required source is missing' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:mediaRoot -ChildPath 'Boot\BCD'))

            $result = & $script:stage $fs (& $script:newRegistry)

            $result.Complete | Should -BeFalse
        }

        It 'names the file it could not stage' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:mediaRoot -ChildPath 'Boot\BCD'))

            $result = & $script:stage $fs (& $script:newRegistry)

            @($result.Missing) | Should -Contain 'Boot\x64\BCD'
        }

        It 'still stages the files that are there' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:mediaRoot -ChildPath 'Boot\BCD'))

            $result = & $script:stage $fs (& $script:newRegistry)

            @($result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\boot.sdi' }).Count | Should -Be 1
        }
    }

    Context 'a hash mismatch' {

        It 'fails rather than warns on a hash mismatch' {
            # A TRUNCATED boot.sdi ON A TFTP SERVER IS A MACHINE THAT HANGS AT
            # BOOT WITH NO MESSAGE. The fake is told the destination hashes
            # differently from the source, which is the one filesystem condition
            # no amount of seeding content can express.
            $fs = & $script:newFileSystem @()
            $fs.SeedHash((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\boot.sdi'), 'DEADBEEF')

            { & $script:stage $fs (& $script:newRegistry) } | Should -Throw '*boot.sdi*'
        }

        It 'says both hashes' {
            $fs = & $script:newFileSystem @()
            $fs.SeedHash((Join-Path -Path $script:payloadPath -ChildPath 'Boot\x64\boot.sdi'), 'DEADBEEF')

            { & $script:stage $fs (& $script:newRegistry) } | Should -Throw '*DEADBEEF*'
        }
    }

    Context 'refusals' {

        It 'refuses when the boot WIM has not been built' {
            $fs = & $script:newFileSystem @((Join-Path -Path $script:workspace -ChildPath 'Boot\HDTPE_x64.wim'))

            { & $script:stage $fs (& $script:newRegistry) } | Should -Throw '*Update-HDTBootImage*'
        }

        It 'refuses a destination inside the workspace' {
            # The payload is for a DIFFERENT server. A copy of the share inside
            # the share is a deployment share that grows a copy of itself every
            # time somebody runs this.
            $fs = & $script:newFileSystem @()

            { New-HDTPxePayload -WorkspaceRoot $script:workspace `
                    -Path (Join-Path -Path $script:workspace -ChildPath 'Pxe') `
                    -FileSystem $fs -Registry (& $script:newRegistry) -Confirm:$false } |
                Should -Throw '*workspace*'
        }

        It 'refuses the workspace root itself as a destination' {
            $fs = & $script:newFileSystem @()

            { New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:workspace `
                    -FileSystem $fs -Registry (& $script:newRegistry) -Confirm:$false } |
                Should -Throw '*workspace*'
        }
    }

    Context 'ShouldProcess' {

        It 'copies nothing under -WhatIf' {
            $fs = & $script:newFileSystem @()

            New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -FileSystem $fs -Registry (& $script:newRegistry) -WhatIf | Out-Null

            @($fs.GetOperationName() | Where-Object { $_ -eq 'CopyItem' }).Count | Should -Be 0
            $fs.TestPath($script:payloadPath) | Should -BeFalse
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name 'New-HDTPxePayload').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'the ADK' {

        It 'resolves every ADK path through Get-HDTAdkPath' {
            # PROJECT.md: the ADK layout has moved between releases, so nothing
            # writes a kit path down. Asserted from the fake REGISTRY's journal:
            # a command that had hardcoded the media tree would never have asked.
            $fs = & $script:newFileSystem @()
            $registry = & $script:newRegistry

            & $script:stage $fs $registry | Out-Null

            @($registry.Operations | Where-Object {
                    [string] $_.Operation -eq 'GetValue' -and [string] $_.Arguments[1] -eq 'KitsRoot10'
                }).Count | Should -BeGreaterThan 0
        }

        It 'reports a missing ADK media tree as a dependency error' {
            $fs = New-HDTFakeFileSystem -File $script:workspaceFile
            $registry = & $script:newRegistry

            $record = $null
            try { & $script:stage $fs $registry } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            [string] $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }

        It 'takes an explicit -AdkRoot over the registry' {
            $fs = & $script:newFileSystem @()
            $registry = New-HDTFakeRegistryService

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -AdkRoot $script:adkRoot -FileSystem $fs -Registry $registry -Confirm:$false

            $result.Complete | Should -BeTrue
        }
    }
}
