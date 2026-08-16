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
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:appData = 'C:\Users\tech\AppData\Roaming'
    $script:settingPath = 'C:\Users\tech\AppData\Roaming\HDT\console.json'

    # A DESKTOP BIG ENOUGH TO BE OUT OF THE WAY, passed to every test that is
    # about the FILE rather than about the screen.
    #
    # Without it those tests read the real monitor, and a test that asserts
    # "answers what was written" would pass at this desk and fail on a laptop -
    # the size having been clamped by a rule the test was not written to
    # exercise. A remembered size is only machine-independent when the machine
    # is stated.
    function New-HDTConsoleTestScreen {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        return New-HDTFakeScreen -Width 3840 -Height 2160
    }

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

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleSetting' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
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
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTConsoleTestScreen)

            $setting.Path | Should -BeExactly $script:settingPath
        }
    }

    Context 'a first run' {

        It 'answers the default size when there is no file' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTConsoleTestScreen)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }

        It 'answers the default when the profile has no APPDATA at all' {
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment -Unset) `
                -Screen (New-HDTConsoleTestScreen)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }
    }

    Context 'a size that was remembered' {

        It 'answers what was written' {
            $fs = New-HDTFakeFileSystem -File @{
                $script:settingPath = '{ "width": 1440, "height": 820 }'
            }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTConsoleTestScreen)

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

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTConsoleTestScreen)

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }

        It 'raises a size smaller than the window can be to the minimum' {
            # A window remembered at 200x100 is one an administrator cannot use
            # and cannot easily fix, because the thing they would fix it with is
            # the window.
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 200, "height": 100 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTConsoleTestScreen)

            $setting.Width | Should -Be 900
            $setting.Height | Should -Be 520
        }
    }

    # THE SAME ARGUMENT AS THE MINIMUM, FROM THE OTHER END. A window too small to
    # use and a window too big to reach are one defect: the administrator cannot
    # fix either, because the thing they would fix it with is the window. A size
    # bigger than the screen is worse, in fact - WindowStartupLocation is
    # CenterScreen, so a window taller than the desktop is centred with its title
    # bar ABOVE the top edge, and a title bar off the top cannot be dragged back.
    # The window is then open, focusable and invisible, which reads to the person
    # who launched it as "the console did not start".
    #
    # THIS IS NOT HYPOTHETICAL. A 1800x900 console.json - the shipped default -
    # opened on a 1280x800 laptop is exactly the case that produced it.
    Context 'a size the screen cannot show' {

        It 'takes an injected screen, so it can be proven on one desk' {
            (Get-Command -Name 'Get-HDTConsoleSetting').Parameters.ContainsKey('Screen') | Should -BeTrue
        }

        It 'lowers a remembered size to the screen that has to show it' {
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 1800, "height": 900 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTFakeScreen -Width 1280 -Height 770)

            $setting.Width | Should -Be 1280
            $setting.Height | Should -Be 770
        }

        It 'lowers the DEFAULT size too, because a first run on a small screen is the same trap' {
            # No file at all, so this is 1800x900 straight from the constants -
            # and it must still fit.
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTFakeScreen -Width 1280 -Height 770)

            $setting.Width | Should -Be 1280
            $setting.Height | Should -Be 770
        }

        It 'leaves a size that already fits exactly alone' {
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 1440, "height": 820 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTFakeScreen -Width 2560 -Height 1400)

            $setting.Width | Should -Be 1440
            $setting.Height | Should -Be 820
        }

        It 'clamps only the dimension that does not fit' {
            # A tall narrow desktop, or a very wide short one, is not a reason to
            # forget the other half of a remembered size.
            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 1800, "height": 700 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTFakeScreen -Width 1280 -Height 1400)

            $setting.Width | Should -Be 1280
            $setting.Height | Should -Be 700
        }

        It 'never goes below the minimum, even on a screen smaller than the minimum' {
            # The floor wins. MinWidth/MinHeight in the markup would override
            # anything lower anyway, so reporting a size WPF will refuse would be
            # a number that lies about the window it produces.
            $setting = Get-HDTConsoleSetting -FileSystem (New-HDTFakeFileSystem) `
                -Environment (New-HDTConsoleSettingTestEnvironment) `
                -Screen (New-HDTFakeScreen -Width 640 -Height 480)

            $setting.Width | Should -Be 900
            $setting.Height | Should -Be 520
        }

        It 'opens at the remembered size rather than not opening, when the screen cannot be read' -ForEach @(
            @{ Name = 'a screen that throws'; Screen = $null }
            @{ Name = 'a screen reporting nothing'; Screen = $null }
        ) {
            # Same rule as the preference file: a convenience must never be the
            # reason a window fails to open. Built per-case below because a
            # -ForEach table cannot hold a live object.
            $screen = switch ($Name) {
                'a screen that throws' { New-HDTFakeScreen -Throw }
                default { New-HDTFakeScreen -Width 0 -Height 0 }
            }

            $fs = New-HDTFakeFileSystem -File @{ $script:settingPath = '{ "width": 1800, "height": 900 }' }

            $setting = Get-HDTConsoleSetting -FileSystem $fs `
                -Environment (New-HDTConsoleSettingTestEnvironment) -Screen $screen

            $setting.Width | Should -Be 1800
            $setting.Height | Should -Be 900
        }
    }
}

Describe 'Save-HDTConsoleSetting' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Save-HDTConsoleSetting' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes a size Get-HDTConsoleSetting reads back' {
        $fs = New-HDTFakeFileSystem
        $environment = New-HDTConsoleSettingTestEnvironment

        [void] (Save-HDTConsoleSetting -Width 1620 -Height 940 -FileSystem $fs -Environment $environment)

        $setting = Get-HDTConsoleSetting -FileSystem $fs -Environment $environment `
            -Screen (New-HDTConsoleTestScreen)

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
