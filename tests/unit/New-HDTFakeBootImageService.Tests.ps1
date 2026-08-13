# The IBootImageService double, and the one fake in this repository that MODELS
# A MOUNT.
#
# Every other fake answers questions. This one has to hold a small piece of
# state that the code under test then WRITES INTO: Update-HDTBootImage mounts a
# WIM, writes startnet.cmd into <mount>\Windows\System32, stages the engine into
# <mount>\HDT, and only then commits. The whole point of DESIGN 5.1's
# mount/apply/inject/commit/export cycle is the order of those things, and a fake
# that recorded 'MountImage' and did nothing else could not tell a builder that
# wrote before mounting from one that wrote after.
#
# So MountImage seeds <MountPath>\Windows\System32 into the INJECTED filesystem,
# and DismountImage with Save false takes the whole tree away again. A builder
# that wrote after discarding is caught by a test rather than by a boot image
# that is missing its launcher.
#
# It is a fake talking to a fake, which is unusual here and deliberate: the
# alternative is a builder test that cannot read back the bytes it just wrote.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:mountPath = 'C:\HDTLab\scratch\bootimage\work\mount'
    $script:wimPath = 'C:\HDTLab\scratch\bootimage\work\HDTPE_x64.wim'
    $script:startnetPath = Join-Path -Path $script:mountPath -ChildPath 'Windows\System32\startnet.cmd'
}

Describe 'New-HDTFakeBootImageService' {

    Context 'the mount it models' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:boot = New-HDTFakeBootImageService -FileSystem $script:fs
        }

        It 'creates the mount path in the injected filesystem on MountImage' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)

            $script:fs.TestPath($script:mountPath) | Should -BeTrue
        }

        It 'seeds Windows\System32 under the mount' {
            # startnet.cmd goes there, and both the real DISM mount and this one
            # must offer a directory that already exists to write it into.
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)

            $script:fs.TestPath((Join-Path -Path $script:mountPath -ChildPath 'Windows\System32')) | Should -BeTrue
        }

        It 'makes the mount readable while it is mounted' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:fs.WriteAllText($script:startnetPath, "@echo off`r`nwpeinit`r`n")

            $script:fs.ReadAllText($script:startnetPath) | Should -BeLike '*wpeinit*'
        }

        It 'discards the mount contents on DismountImage with Save false' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:fs.WriteAllText($script:startnetPath, 'wpeinit')

            $script:boot.DismountImage($script:mountPath, $false)

            $script:fs.TestPath($script:startnetPath) | Should -BeFalse
        }

        It 'keeps them on DismountImage with Save true' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:fs.WriteAllText($script:startnetPath, 'wpeinit')

            $script:boot.DismountImage($script:mountPath, $true)

            $script:fs.ReadAllText($script:startnetPath) | Should -BeExactly 'wpeinit'
        }

        It 'throws when a second MountImage targets the same path' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)

            { $script:boot.MountImage($script:wimPath, 1, $script:mountPath) } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'mounts a second image at a different path' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)

            { $script:boot.MountImage($script:wimPath, 1, 'C:\HDTLab\scratch\bootimage\inspect') } |
                Should -Not -Throw
        }

        It 'throws when AddPackage is called with nothing mounted' {
            # Parity with DISM, which refuses a -Path that is not a mount.
            { $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab') } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'throws when SetScratchSpace is called with nothing mounted' {
            { $script:boot.SetScratchSpace($script:mountPath, 512) } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'throws when DismountImage is called with nothing mounted' {
            { $script:boot.DismountImage($script:mountPath, $true) } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'lets the same path be mounted again after a dismount' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:boot.DismountImage($script:mountPath, $true)

            { $script:boot.MountImage($script:wimPath, 1, $script:mountPath) } | Should -Not -Throw
        }

        It 'writes the exported image into the injected filesystem' {
            # Step 16 of DESIGN 5.1 copies the exported WIM into the media tree,
            # and the copy is the whole of DESIGN 6.1.1. A fake whose export
            # produced no file would make that copy unprovable.
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:boot.DismountImage($script:mountPath, $true)
            $script:boot.ExportImage($script:wimPath, 1, 'C:\ws\Boot\HDTPE_x64.wim')

            $script:fs.TestPath('C:\ws\Boot\HDTPE_x64.wim') | Should -BeTrue
        }

        It 'gives an exported image and a copy of it the same hash' {
            $script:boot.ExportImage($script:wimPath, 1, 'C:\ws\Boot\HDTPE_x64.wim')
            $script:fs.CopyItem('C:\ws\Boot\HDTPE_x64.wim', 'C:\scratch\media\sources\boot.wim')

            $script:fs.GetHash('C:\scratch\media\sources\boot.wim') |
                Should -BeExactly $script:fs.GetHash('C:\ws\Boot\HDTPE_x64.wim')
        }

        It 'writes the ISO into the injected filesystem from NewIso' {
            $script:boot.NewIso('C:\scratch\media', 'C:\ws\Boot\HDTPE_x64.iso', @('-m', '-o'))

            $script:fs.TestPath('C:\ws\Boot\HDTPE_x64.iso') | Should -BeTrue
        }
    }

    Context 'recording' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:boot = New-HDTFakeBootImageService -FileSystem $script:fs
        }

        It 'records every method with its arguments' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)

            $script:boot.Operations[0].Operation | Should -BeExactly 'MountImage'
            @($script:boot.Operations[0].Arguments) | Should -Be @($script:wimPath, 1, $script:mountPath)
        }

        It 'records AddPackage in the order it was called' {
            # The ordering assertion Update-HDTBootImage's test depends on: the
            # language pack goes immediately after its component (DESIGN 5.1).
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab')
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\en-us\WinPE-WMI_en-us.cab')
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-NetFx.cab')

            @($script:boot.Operations |
                    Where-Object { $_.Operation -eq 'AddPackage' } |
                    ForEach-Object { [System.IO.Path]::GetFileName($_.Arguments[1]) }) |
                Should -Be @('WinPE-WMI.cab', 'WinPE-WMI_en-us.cab', 'WinPE-NetFx.cab')
        }

        It 'returns operation names in order from GetOperationName' {
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab')
            $script:boot.SetScratchSpace($script:mountPath, 512)
            $script:boot.DismountImage($script:mountPath, $true)
            $script:boot.ExportImage($script:wimPath, 1, 'C:\ws\Boot\HDTPE_x64.wim')

            $script:boot.GetOperationName() |
                Should -Be @('MountImage', 'AddPackage', 'SetScratchSpace', 'DismountImage', 'ExportImage')
        }

        It 'records before it throws' {
            try { $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab') } catch { $null = $_ }

            $script:boot.GetOperationName() | Should -Be @('AddPackage')
        }

        It 'returns the drivers it was seeded with from AddDriver' {
            $driver = @(
                [pscustomobject] @{ Inf = 'oem0.inf'; Provider = 'Intel'; Version = '12.19.2.60'; Date = '2024-01-01' }
                [pscustomobject] @{ Inf = 'oem1.inf'; Provider = 'Microsoft'; Version = '10.0.26100.1'; Date = '2024-06-01' }
            )
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Driver $driver
            $boot.MountImage($script:wimPath, 1, $script:mountPath)

            $added = @($boot.AddDriver($script:mountPath, 'C:\ws\Drivers\boot-critical', $true))

            $added.Count | Should -Be 2
            $added[0].Inf | Should -BeExactly 'oem0.inf'
        }

        It 'returns an array from AddDriver even for one driver' {
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Driver @([pscustomobject] @{ Inf = 'oem0.inf' })
            $boot.MountImage($script:wimPath, 1, $script:mountPath)

            $boot.AddDriver($script:mountPath, 'C:\ws\Drivers\boot-critical', $true) -is [System.Array] | Should -BeTrue
        }

        It 'returns the packages it was told to add from GetPackage' {
            # So a test can assert "all nine went in" with no DISM anywhere.
            $script:boot.MountImage($script:wimPath, 1, $script:mountPath)
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab')
            $script:boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-NetFx.cab')

            $package = @($script:boot.GetPackage($script:mountPath))

            @($package | ForEach-Object { $_.Name }) | Should -Be @('WinPE-WMI', 'WinPE-NetFx')
            @($package | ForEach-Object { $_.State }) | Should -Be @('Installed', 'Installed')
        }

        It 'returns the packages it was seeded with from GetPackage' {
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Package @{ 'WinPE-Setup' = 'Installed' }
            $boot.MountImage($script:wimPath, 1, $script:mountPath)

            @($boot.GetPackage($script:mountPath) | ForEach-Object { $_.Name }) | Should -Contain 'WinPE-Setup'
        }

        It 'returns the image rows it was seeded with from GetImageInfo' {
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Image @{
                'C:\Adk\winpe.wim' = @([pscustomobject] @{ Index = 1; Name = 'Microsoft Windows PE (amd64)'; SizeBytes = 340134390 })
            }

            $row = @($boot.GetImageInfo('C:\Adk\winpe.wim'))

            $row.Count | Should -Be 1
            $row[0].Index | Should -Be 1
            $row[0].SizeBytes | Should -Be 340134390
        }

        It 'throws FileNotFoundException from GetImageInfo for an image nobody seeded' {
            { $script:boot.GetImageInfo('C:\Adk\nosuch.wim') } |
                Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
        }

        It 'throws the seeded failure' {
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Failure @{ AddPackage = 'Error: 0x800f081e' }
            $boot.MountImage($script:wimPath, 1, $script:mountPath)

            { $boot.AddPackage($script:mountPath, 'C:\Adk\WinPE_OCs\WinPE-WMI.cab') } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'records into a shared journal as BootImageService' {
            $journal = [System.Collections.ArrayList]::new()
            $fs = New-HDTFakeFileSystem -Journal $journal
            $boot = New-HDTFakeBootImageService -FileSystem $fs -Journal $journal

            $boot.MountImage($script:wimPath, 1, $script:mountPath)
            $fs.WriteAllText($script:startnetPath, 'wpeinit')
            $boot.DismountImage($script:mountPath, $true)

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('BootImageService.MountImage', 'FileSystem.WriteAllText', 'BootImageService.DismountImage')
        }

        It 'names itself BootImageService' {
            $script:boot.ServiceName | Should -BeExactly 'BootImageService'
        }

        It 'records nothing for seeding' {
            $boot = New-HDTFakeBootImageService -FileSystem $script:fs -Package @{ 'WinPE-Setup' = 'Installed' } `
                -Driver @([pscustomobject] @{ Inf = 'oem0.inf' })

            @($boot.Operations).Count | Should -Be 0
        }
    }

    Context 'it does no real work' {

        It 'mounts nothing on the real filesystem' {
            # README section 7. Without this a fake can fall through to the real
            # machine and every test above it becomes a lie.
            $path = 'C:\HDTLab\does-not-exist\bootimage-mount'
            $boot = New-HDTFakeBootImageService

            $boot.MountImage('C:\HDTLab\does-not-exist\winpe.wim', 1, $path)

            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'runs no oscdimg' {
            $boot = New-HDTFakeBootImageService
            $boot.NewIso('C:\HDTLab\does-not-exist\media', 'C:\HDTLab\does-not-exist\out.iso', @('-m', '-o', '-u2'))

            @(Get-Process -Name 'oscdimg' -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'creates no ISO' {
            $boot = New-HDTFakeBootImageService
            $boot.NewIso('C:\HDTLab\does-not-exist\media', 'C:\HDTLab\does-not-exist\out.iso', @('-m'))

            Test-Path -LiteralPath 'C:\HDTLab\does-not-exist\out.iso' | Should -BeFalse
        }

        It 'exports nothing to the real filesystem' {
            $boot = New-HDTFakeBootImageService
            $boot.ExportImage('C:\HDTLab\does-not-exist\a.wim', 1, 'C:\HDTLab\does-not-exist\b.wim')

            Test-Path -LiteralPath 'C:\HDTLab\does-not-exist\b.wim' | Should -BeFalse
        }

        It 'brings its own filesystem when none was injected' {
            $boot = New-HDTFakeBootImageService

            $boot.MountImage('C:\a.wim', 1, 'C:\mount')

            $boot.FileSystem.TestPath('C:\mount\Windows\System32') | Should -BeTrue
        }
    }
}
