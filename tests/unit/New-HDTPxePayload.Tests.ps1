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
# confines a PXE responder to the isolated 'HDT Lab' switch.
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

    Context 'the Secure Boot bootloader swap' {

        # BOTH PATHS, OR NEITHER (ROADMAP M4). Correcting the ISO and leaving the
        # TFTP root alone leaves WDS/PXE serving the same revoked SVN 3.0 loader
        # the ADK ships, and the two are one product to the person whose machine
        # shows Security Violation and nothing else.

        BeforeAll {
            # THE SHAPE OF A REAL SERVICED WINDOWS. The swap now takes the OS
            # loader off the SAME machine as the boot managers, and this command
            # reads that loader's version as the yardstick the manifest's
            # recorded version is measured against - so <Windows>\Boot\EFI has
            # to have a <Windows>\System32\Boot beside it.
            $script:windowsRoot = 'C:\PatchedWindows'
            $script:bootLoaderPath = $script:windowsRoot + '\Boot\EFI'
            $script:osLoaderSourcePath = $script:windowsRoot + '\System32\Boot'

            # THE MEASURED PAIR (SPIKES S20.2, S20.3). 10.0.28000.342 is this laptop's
            # own C:\Windows\Boot\EFI, and 10.0.26100.1 is the winload.efi the
            # ADK's WinPE really carries - the two versions whose combination
            # failed 0xc0430001 on a Gen 2 VM with Secure Boot on.
            $script:patchedLoaderVersion = '10.0.28000.342'
            $script:adkOsLoaderVersion = '10.0.26100.1'

            # WHAT A SERVICED WINDOWS CARRIES, read off the build host on
            # 2026-09-10. It is on the OS's track (26100) and the boot manager
            # is on its own (28000); that host boots the pair with Secure Boot
            # ON, which is why the check compares loader against loader and
            # never loader against boot manager (SPIKES S20.3).
            $script:servicedOsLoaderVersion = '10.0.26100.8655'

            # A PXE PAYLOAD CANNOT MOUNT THE IMAGE IT STAGES, so the OS loader
            # version comes from the manifest Update-HDTBootImage wrote beside
            # the WIM. That is the only place the fact exists on this side.
            $script:newSwapManifest = {
                param([string] $OsLoaderVersion)

                if ([string]::IsNullOrEmpty($OsLoaderVersion)) { return '{ "schemaVersion": 1 }' }

                return ('{{ "schemaVersion": 1, "osLoader": {{ "path": "C:\\scratch\\mount\\Windows\\System32\\Boot\\winload.efi", "version": "{0}" }} }}' -f $OsLoaderVersion)
            }

            $script:newSwapFileSystem = {
                param(
                    [string[]] $Omit,
                    [string] $OsLoaderVersion = '10.0.26100.8655',
                    [string] $LoaderVersion = '10.0.28000.342',
                    [string] $ServicedOsLoaderVersion = '10.0.26100.8655')

                $file = @{}
                foreach ($key in @($script:adkFile.Keys)) { $file[$key] = $script:adkFile[$key] }
                foreach ($key in @($script:workspaceFile.Keys)) { $file[$key] = $script:workspaceFile[$key] }

                $file[(Join-Path -Path $script:workspace -ChildPath 'Boot\HDTPE_x64.manifest.json')] =
                (& $script:newSwapManifest $OsLoaderVersion)

                $version = @{}

                foreach ($leaf in @('bootmgr.efi', 'bootmgfw.efi')) {
                    if (@($Omit) -contains $leaf) { continue }
                    $file[($script:bootLoaderPath + '\' + $leaf)] = ('patched {0} bytes' -f $leaf)
                    $version[($script:bootLoaderPath + '\' + $leaf)] = $LoaderVersion
                }

                # THE OS LOADER HALF OF THE SAME WINDOWS. This command copies
                # none of it - it cannot mount the WIM it stages - but it reads
                # the version, because that is what the manifest's recorded
                # version has to be at or above.
                foreach ($leaf in @('winload.efi', 'winload.exe')) {
                    if (@($Omit) -contains $leaf) { continue }
                    $file[($script:osLoaderSourcePath + '\' + $leaf)] = ('serviced {0} bytes' -f $leaf)
                    $version[($script:osLoaderSourcePath + '\' + $leaf)] = $ServicedOsLoaderVersion
                }

                return (New-HDTFakeFileSystem -File $file -Version $version)
            }
        }

        It 'stages both UEFI loaders from the patched folder instead of the ADK' {
            $fs = & $script:newSwapFileSystem @()
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false

            $row = @($result.File | Where-Object { [string] $_.Destination -like '*.efi' })

            @($row | ForEach-Object { [string] $_.Destination }) |
                Should -Be @('Boot\x64\wdsmgfw.efi', 'Boot\x64\bootmgfw.efi')

            foreach ($entry in $row) {
                [string] $entry.Source | Should -BeLike ($script:bootLoaderPath + '\*')
            }
        }

        It 'keeps the payload table''s source pairing when it substitutes' {
            # The table stages bootmgfw.efi FROM the ADK media's bootmgr.efi and
            # wdsmgfw.efi FROM EFI\Boot\bootx64.efi - the firmware boot manager
            # under the removable-media name. bootmgr.efi and bootmgfw.efi are
            # different binaries, so a substitution that crossed them over would
            # produce a payload that looks staged and boots nothing.
            $fs = & $script:newSwapFileSystem @()
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false

            $bootmgfw = @($result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\bootmgfw.efi' })
            $wdsmgfw = @($result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\wdsmgfw.efi' })

            [string] $bootmgfw[0].Source | Should -BeExactly ($script:bootLoaderPath + '\bootmgr.efi')
            [string] $wdsmgfw[0].Source | Should -BeExactly ($script:bootLoaderPath + '\bootmgfw.efi')
        }

        It 'leaves every other declared row on the ADK media' {
            # The swap is two files. bootmgr.exe, boot.sdi, the BCD and the fonts
            # are not signed loaders and have no SVN; moving them would be an
            # unrelated change hiding inside a security fix.
            $fs = & $script:newSwapFileSystem @()
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false

            $other = @($result.File | Where-Object { [string] $_.Destination -notlike '*.efi' })

            $other | Should -Not -BeNullOrEmpty
            foreach ($entry in $other) {
                [string] $entry.Source | Should -Not -BeLike ($script:bootLoaderPath + '\*')
            }
        }

        It 'still hashes what it staged, so a substituted copy is verified too' {
            # A swapped loader gets the same treatment as every other row: hash
            # the source, hash the copy, refuse on a mismatch. A truncated
            # bootmgfw.efi on a TFTP server is a machine that hangs at boot.
            $fs = & $script:newSwapFileSystem @()
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false

            $swapped = @($result.File | Where-Object { [string] $_.Destination -eq 'Boot\x64\bootmgfw.efi' })

            [string] $swapped[0].Sha256 | Should -Not -BeNullOrEmpty
            $result.Complete | Should -BeTrue
        }

        It 'stages the ADK loaders when no bootloader folder is named' {
            $fs = & $script:newSwapFileSystem @()
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -FileSystem $fs -Registry $registry -Confirm:$false

            foreach ($entry in @($result.File)) {
                [string] $entry.Source | Should -Not -BeLike ($script:bootLoaderPath + '\*')
            }
        }

        It 'refuses a folder missing a loader, naming the file and the cause' {
            $fs = & $script:newSwapFileSystem @('bootmgfw.efi')
            $registry = & $script:newRegistry

            $record = $null
            try {
                New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                    -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty

            $message = [string] $record.Exception.Message
            $message | Should -Match 'bootmgfw\.efi'
            $message | Should -Match 'Secure Boot'
            $message | Should -Not -Match 'Could not find file'
        }

        # =================================================================
        # THE SERVICING CHECK - SPIKES S20.2, corrected by S20.3
        # =================================================================
        #
        # THE SWAP AS FIRST SHIPPED PRODUCED MEDIA THAT DOES NOT BOOT, and said
        # nothing. Measured on Gen 2 Hyper-V, 2026-09-07: swapped media failed
        # with Secure Boot ON (0xc0430001), the same ISO passed with it OFF, and
        # the unswapped ADK media passed with it ON. The firmware accepted the
        # loader; the BOOT MANAGER refused the OS loader behind it.
        #
        # WHAT IS COMPARED IS LOADER AGAINST LOADER. Update-HDTBootImage now
        # replaces the image's own winload.efi from the same serviced Windows as
        # the boot managers; this command reads that Windows's winload.efi
        # version - purely, no mount - and holds the manifest's recorded version
        # to it. Comparing against the BOOT MANAGER's version would order two
        # different servicing tracks, which is the false refusal S20.3 records:
        # the build host runs 10.0.28000.342 over 10.0.26100.8655, Secure Boot
        # ON, every day.
        #
        # A PXE PAYLOAD CANNOT MOUNT THE IMAGE, so the manifest is the only place
        # the image's own version exists on this side. Both delivery paths or
        # neither, which is already this file's rule for the swap itself.

        It 'accepts a 28000-series boot manager over a 26100-series OS loader' {
            # THE FALSE REFUSAL, GUARDED. This pair is what the build host boots
            # with Secure Boot on; a payload command that refused it would refuse
            # every correctly built image.
            $fs = & $script:newSwapFileSystem @() $script:servicedOsLoaderVersion
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false

            $result.Complete | Should -BeTrue
        }

        It 'refuses a boot image whose recorded OS loader is behind the serviced one' {
            # THE REAL DEFECT: an image built before the injection existed, or
            # one built against a different Windows, still carrying the ADK's
            # RTM 10.0.26100.1 under a serviced 10.0.26100.8655.
            $fs = & $script:newSwapFileSystem @() $script:adkOsLoaderVersion
            $registry = & $script:newRegistry

            $record = $null
            try {
                New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                    -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty

            $message = [string] $record.Exception.Message
            $message | Should -Match 'rollback'
            $message | Should -Match '0xc0430001'
            $message | Should -Match ([regex]::Escape($script:adkOsLoaderVersion))
            $message | Should -Match ([regex]::Escape($script:servicedOsLoaderVersion))
        }

        It 'stages nothing at all when it refuses' {
            # A TFTP ROOT HALF FULL OF A PAYLOAD THAT CANNOT BOOT is worse than
            # an empty one: it looks served. The refusal happens before the first
            # copy, like every other refusal in this command.
            $fs = & $script:newSwapFileSystem @() $script:adkOsLoaderVersion
            $registry = & $script:newRegistry

            try {
                New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                    -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false
            } catch {
                $null = $_
            }

            @($fs.Operations | Where-Object { $_.Operation -eq 'CopyItem' }) | Should -BeNullOrEmpty
        }

        It 'refuses when the manifest does not record an OS loader version' {
            # SILENCE IS THE FAILURE MODE. An image built before this check
            # existed carries no osLoader block, so the one fact the decision
            # turns on is missing - and "missing" cannot be read as "safe" for a
            # feature whose failure mode is a machine that will not start.
            $fs = & $script:newSwapFileSystem @() ''
            $registry = & $script:newRegistry

            $record = $null
            try {
                New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                    -BootLoaderPath $script:bootLoaderPath -FileSystem $fs -Registry $registry -Confirm:$false
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty

            $message = [string] $record.Exception.Message
            $message | Should -Match 'Update-HDTBootImage'
            $message | Should -Match 'manifest'
        }

        It 'says nothing about servicing levels when no swap was asked for' {
            # OPT-IN. A payload staged from the ADK's own matched pair is the
            # control run, and it PASSED with Secure Boot on.
            $fs = & $script:newSwapFileSystem @() ''
            $registry = & $script:newRegistry

            $result = New-HDTPxePayload -WorkspaceRoot $script:workspace -Path $script:payloadPath `
                -FileSystem $fs -Registry $registry -Confirm:$false

            $result.Complete | Should -BeTrue
        }
    }
}

