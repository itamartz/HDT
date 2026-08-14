# The console remembers the size it was left at.
#
# WHY THIS IS NOT ON THE DEPLOYMENT SHARE. A window size is one administrator's
# preference on one workstation, not a property of the share - two people opening
# the same share must not fight over its geometry, and C1 writes nothing to a
# share at all. It lives in %APPDATA%\HDT\console.json, and a test asserts the
# path is nowhere near a workspace root.
#
# A BROKEN PREFERENCE FILE MUST NEVER STOP THE CONSOLE OPENING. Absent, empty,
# not JSON, JSON of the wrong shape, or holding a size nobody could use - every
# one of those answers with the default rather than an error. The whole point of
# the file is convenience; a convenience that can lock an administrator out of
# their tooling is a defect, and it is the kind that only shows up on the day the
# disk filled up mid-write.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:appData = 'C:\Users\tech\AppData\Roaming'
    $script:settingPath = 'C:\Users\tech\AppData\Roaming\HDT\console.json'

    function New-HDTConsoleSettingTestEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()]
            [switch] $Unset
        )

        if ($Unset) {
            return New-HDTFakeEnvironmentProvider
        }

        return New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = $script:appData }
    }
}

Describe 'Get-HDTConsoleSetting' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by HDT.Console' {
            Get-Command -Name 'Get-HDTConsoleSetting' -Module 'HDT.Console' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected file system and environment, so it can run with neither' {
            (Get-Command -Name 'Get-HDTConsoleSetting').Parameters.ContainsKey('FileSystem') | Should -BeTrue
            (Get-Command -Name 'Get-HDTConsoleSetting').Parameters.ContainsKey('Environment') | Should -BeTrue
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleSetting').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'where it keeps the file' {

        It 'puts it under the user profile, never on a deployment share' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment)

            $setting.Path | Should -BeExactly $script:settingPath
        }
    }

    Context 'a first run' {

        It 'answers the default size when there is no file' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }

        It 'answers the default when the profile has no APPDATA at all' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment -Unset)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }
    }

    Context 'a size that was remembered' {

        It 'answers what was written' {
            $fs = New-HDTFakeFileSystem -File @{
                $script:settingPath = '{ "width": 1440, "height": 820 }'
            }

            $setting = Get-HDTConsoleSetting -FileSystem $fs -Environment (New-HDTConsoleSettingTestEnvironment)

            $setting.Width | Should -Be 1440
            $setting.Height | Should -Be 820
        }
    }

    Context 'a file that cannot be trusted' {

        It 'answers the default for <Name> rather than failing to open a window' -ForEach @(
            @{ Name = 'text that is not JSON'; Content = 'this is not json' }
            @{ Name = 'JSON with no size in it'; Content = '{ "theme": "Dark" }' }
            @{ Name = 'an empty file'; Content = '' }
            @{ Name = 'a size of zero'; Content = '{ "width": 0, "height": 0 }' }
            @{ Name = 'a negative size'; Content = '{ "width": -1400, "height": -900 }' }
        ) {
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = $Content }

            $setting = Get-HDTConsoleSetting -FileSystem $fs -Environment (New-HDTConsoleSettingTestEnvironment)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }

        It 'raises a size smaller than the window can be to the minimum' {
            # A window remembered at 200x100 is one an administrator cannot use
            # and cannot easily fix, because the thing they would fix it with is
            # the window.
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 200, "height": 100 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs -Environment (New-HDTConsoleSettingTestEnvironment)

            $setting.Width | Should -Be 900
            $setting.Height | Should -Be 520
        }
    }
}

Describe 'Save-HDTConsoleSetting' {

    It 'is exported by HDT.Console' {
        Get-Command -Name 'Save-HDTConsoleSetting' -Module 'HDT.Console' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes a size Get-HDTConsoleSetting reads back' {
        $fs = New-HDTFakeFileSystem
        $environment = New-HDTConsoleSettingTestEnvironment

        [void] (Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $fs -Environment $environment)

        $setting = Get-HDTConsoleSetting -FileSystem $fs -Environment $environment

        $setting.Width | Should -Be 1620
        $setting.Height | Should -Be 940
    }

    It 'writes it under the user profile and nowhere else' {
        $fs = New-HDTFakeFileSystem

        [void] (Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment))

        $written = @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' })

        @($written).Count | Should -Be 1
        $written[0].Arguments[0] | Should -BeExactly $script:settingPath
    }

    It 'refuses to remember a size the window could not open at' {
        $fs = New-HDTFakeFileSystem

        [void] (Save-HDTConsoleSetting -Width 10 -Height 10 -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment))

        @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' }).Count | Should -Be 0
    }

    It 'does not fail the console when the file cannot be written' {
        # Closing a window must not throw because a preference could not be
        # saved. The console is already on its way out; there is nothing useful
        # an administrator could do with the error.
        $fs = New-HDTFakeFileSystem -WriteFailure @{ $script:settingPath = 'the disk is full.' }

        { Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) } | Should -Not -Throw
    }

    It 'says whether it saved, so a caller is not left guessing' {
        $good = New-HDTFakeFileSystem
        $bad = New-HDTFakeFileSystem -WriteFailure @{ $script:settingPath = 'the disk is full.' }

        (Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $good `
                -Environment (New-HDTConsoleSettingTestEnvironment)) | Should -BeTrue

        (Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $bad `
                -Environment (New-HDTConsoleSettingTestEnvironment)) | Should -BeFalse
    }
}
