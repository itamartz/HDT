# THE SHARES THE CONSOLE COMES BACK TO.
#
# Deployment Workbench remembers the deployment shares somebody added and shows
# them the next time it opens; HDT's console showed whatever was on the command
# line and forgot it the moment the window closed. So the only way to open the
# same two shares twice was to type both paths twice.
#
# THEY LIVE BESIDE THE WINDOW SIZE, in %APPDATA%\HDT\console.json, for the same
# reason the size does: which shares an administrator works on is about THIS
# PERSON at THIS DESK, not about any one share, so it cannot live in a share.
#
# A REMEMBERED PATH IS NOT A PROMISE. A share on a disconnected USB disk, or one
# somebody deleted, must not stop the console opening - it is read like any
# other, and a share that will not open becomes a row saying so.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:settingPath = 'C:\appdata\HDT\console.json'

    $script:newEnvironment = {
        New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = 'C:\appdata' }
    }
}

Describe 'the shares a console remembers' {

    Context 'reading them back' {

        It 'is empty on a machine that has never opened one' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (& $script:newEnvironment) -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -BeNullOrEmpty
        }

        It 'reads the ones the file names, in the order it names them' {
            $fileSystem = New-HDTFakeFileSystem -File @{
                $script:settingPath = '{ "width": 1800, "height": 900, "share": [ "C:\\one", "\\\\server\\two" ] }'
            }

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem `
                -Environment (& $script:newEnvironment) -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -Be @('C:\one', '\\server\two')
        }

        It 'is empty rather than broken when the file is nonsense' {
            # The size already survives an unreadable file; the shares have to
            # as well, or a corrupt preference is a console that will not open.
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:settingPath = 'not json at all' }

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem `
                -Environment (& $script:newEnvironment) -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -BeNullOrEmpty
        }
    }

    Context 'writing them' {

        It 'keeps what it was given' {
            $fileSystem = New-HDTFakeFileSystem
            $environment = & $script:newEnvironment

            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900 -Share @('C:\one', 'C:\two') `
                    -FileSystem $fileSystem -Environment $environment)

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem -Environment $environment `
                -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -Be @('C:\one', 'C:\two')
        }

        It 'writes the same share once, however many times it was opened' {
            $fileSystem = New-HDTFakeFileSystem
            $environment = & $script:newEnvironment

            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900 `
                    -Share @('C:\one', 'C:\ONE', 'C:\two') `
                    -FileSystem $fileSystem -Environment $environment)

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem -Environment $environment `
                -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share).Count | Should -Be 2
        }

        It 'forgets them when it is handed none, which is what closing the last one means' {
            $fileSystem = New-HDTFakeFileSystem
            $environment = & $script:newEnvironment

            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900 -Share @('C:\one') `
                    -FileSystem $fileSystem -Environment $environment)
            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900 -Share @() `
                    -FileSystem $fileSystem -Environment $environment)

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem -Environment $environment `
                -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -BeNullOrEmpty
        }

        It 'leaves the remembered shares alone when it is not told about them' {
            # The window's size is saved on every close, and a close that said
            # nothing about shares must not be the thing that forgets them.
            $fileSystem = New-HDTFakeFileSystem
            $environment = & $script:newEnvironment

            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900 -Share @('C:\one') `
                    -FileSystem $fileSystem -Environment $environment)
            [void] (Save-HDTConsoleSetting -Width 1600 -Height 800 `
                    -FileSystem $fileSystem -Environment $environment)

            $setting = Get-HDTConsoleSetting -FileSystem $fileSystem -Environment $environment `
                -Screen (New-HDTFakeScreen -Width 3840 -Height 2160)

            @($setting.Share) | Should -Be @('C:\one')
        }
    }
}
