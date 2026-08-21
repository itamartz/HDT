# THE BOOT STATUS OVERLAY: WHAT A TECHNICIAN LOOKS AT BETWEEN startnet.cmd AND
# THE FIRST REAL WINDOW.
#
# THE PROBLEM IT SOLVES. WinPE boots into cmd.exe running startnet.cmd, and that
# black full-screen window covers the desktop for the whole run. A BGInfo start
# command - the machine's serial, model and address on the wallpaper, which is
# why an administrator puts one in a boot image at all - paints BEHIND it, so
# nothing of it is visible. MDT has no console to hide: winpeshl.ini makes
# LiteTouch.wsf the shell, which is why the same BGInfo is on screen there from
# the first second.
#
# Start-HDTDeployment therefore hides the console - and the moment it does, the
# twenty seconds before the Welcome screen are twenty seconds with NOTHING on
# them. This window is what goes there: the payload's own account of itself, in
# a transparent, borderless panel over the wallpaper rather than a black
# rectangle on top of it.
#
# SO THE RULE THIS FILE EXISTS FOR: the console is hidden only when this window
# opened. A boot image built without WinPE-NetFx has no WPF, this comes back as
# Console, and the payload leaves the console exactly where it was. Nobody ever
# ends up looking at a blank screen.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:xamlPath = 'X:\HDT\UI\HDTBootStatus.xaml'

    # The real window, read off disk rather than retyped, so the shipped file and
    # the file these tests exercise cannot drift.
    $script:realXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTBootStatus.xaml'))

    function New-HDTBootStatusTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Xaml = $script:realXaml,

            [Parameter()]
            [switch] $Missing
        )

        $file = @{}
        if (-not $Missing) { $file[$script:xamlPath] = $Xaml }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Start-HDTBootStatus' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Start-HDTBootStatus' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected status host, so it can run with no display' {
            (Get-Command -Name 'Start-HDTBootStatus').Parameters.Keys | Should -Contain 'StatusHost'
        }

        It 'takes an injected file system' {
            (Get-Command -Name 'Start-HDTBootStatus').Parameters.Keys | Should -Contain 'FileSystem'
        }
    }

    Context 'when the window opens' {

        It 'reports Window and hands back the host that drew it' {
            $drawn = New-HDTFakeBootStatusHost

            $result = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost $drawn -FileSystem (New-HDTBootStatusTestFileSystem)

            $result.Mode | Should -Be 'Window'
            $result.Reason | Should -BeNullOrEmpty
            $result.StatusHost | Should -Be $drawn
        }

        It 'hands the host the markup that was on disk' {
            $drawn = New-HDTFakeBootStatusHost

            $null = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost $drawn -FileSystem (New-HDTBootStatusTestFileSystem)

            $drawn.LastXaml | Should -Be $script:realXaml
            $drawn.IsOpen | Should -BeTrue
        }

        It 'hands the window its two strings out of the table' {
            # THE MARKUP CARRIES NO TEXT. The overlay's runspace has no
            # Hephaestus module in it, so it cannot read Strings\en-us.psd1 for
            # itself - the same split that hands it a command prompt path rather
            # than a command.
            $drawn = New-HDTFakeBootStatusHost

            $null = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost $drawn -FileSystem (New-HDTBootStatusTestFileSystem)

            $drawn.LastText | Should -Not -BeNullOrEmpty
            $drawn.LastText['HDTBootStatusHeading.Text'] | Should -Be 'Hephaestus Deployment Toolkit'
        }

        It 'hands the window a command prompt path, because F8 must work with the console hidden' {
            # The overlay is the ONLY thing on screen once the payload hides the
            # console, so it is the one window where a technician cannot reach a
            # prompt any other way. Its runspace has no Hephaestus module in it,
            # so the path is resolved here and handed over with the markup - the
            # same split the progress window uses.
            $drawn = New-HDTFakeBootStatusHost

            $null = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost $drawn -FileSystem (New-HDTBootStatusTestFileSystem)

            $drawn.LastCommandPromptPath | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when it cannot draw one' {

        It 'reports Console rather than throwing when the window file is missing' {
            $result = $null

            { $script:missingResult = Start-HDTBootStatus -XamlPath $script:xamlPath `
                    -StatusHost (New-HDTFakeBootStatusHost) `
                    -FileSystem (New-HDTBootStatusTestFileSystem -Missing) } | Should -Not -Throw

            $result = $script:missingResult

            $result.Mode | Should -Be 'Console'
            $result.Reason | Should -Match 'HDTBootStatus.xaml'
        }

        It 'reports Console rather than throwing when the markup will not parse' {
            $result = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost (New-HDTFakeBootStatusHost) `
                -FileSystem (New-HDTBootStatusTestFileSystem -Xaml '<Window')

            $result.Mode | Should -Be 'Console'
            $result.Reason | Should -Not -BeNullOrEmpty
        }

        It 'reports Console rather than throwing on a machine with no WPF' {
            # A boot image built without WinPE-NetFx. This is the path nobody
            # exercises until the night it matters, and the one that decides
            # whether the payload dares hide the console.
            $result = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost (New-HDTFakeBootStatusHost -FailOpen) `
                -FileSystem (New-HDTBootStatusTestFileSystem)

            $result.Mode | Should -Be 'Console'
            $result.Reason | Should -Match 'PresentationFramework'
        }

        It 'still hands back a host with the same methods, so the caller never branches' {
            $result = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost (New-HDTFakeBootStatusHost -FailOpen) `
                -FileSystem (New-HDTBootStatusTestFileSystem)

            { $result.StatusHost.Write('a line') } | Should -Not -Throw
            { $result.StatusHost.Close() } | Should -Not -Throw
        }
    }

    Context 'the line it is given' {

        It 'reaches the window' {
            $drawn = New-HDTFakeBootStatusHost

            $result = Start-HDTBootStatus -XamlPath $script:xamlPath `
                -StatusHost $drawn -FileSystem (New-HDTBootStatusTestFileSystem)

            $result.StatusHost.Write('12:00:01  bootstrap: provider Smb')
            $result.StatusHost.Write('12:00:02  address 192.168.2.40 after 1 attempt(s)')

            @($drawn.Line).Count | Should -Be 2
            @($drawn.Line)[-1] | Should -Match 'address'
        }
    }
}

Describe 'New-HDTConsoleBootStatusHost' {

    # THE FALLBACK IS A HOST, NOT A BRANCH AT THE CALL SITE - the same rule
    # New-HDTConsoleProgressHost carries, for the same reason: the machines this
    # exists for are the machines nobody is testing on.
    #
    # AND IT WRITES NOTHING, WHICH IS NOT AN OVERSIGHT. The payload's own $say
    # has already put this line on the console with Write-Information; a second
    # copy would double every line of a deployment's account of itself. What
    # this object is for is letting the payload call Write with no branch on a
    # machine that could not draw a window - and on that machine the console is
    # still visible, because the payload only hides it when Mode is Window.

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTConsoleBootStatusHost' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'has the same methods the real host has, so the two are interchangeable' {
        $console = New-HDTConsoleBootStatusHost
        $real = New-HDTBootStatusHost

        foreach ($name in @('Open', 'Write', 'Close')) {
            $console.PSObject.Methods.Name | Should -Contain $name
            $real.PSObject.Methods.Name | Should -Contain $name
        }
    }

    It 'never throws from any of them' {
        $console = New-HDTConsoleBootStatusHost

        { $console.Open('<Window />', 'X:\Windows\System32\cmd.exe') } | Should -Not -Throw
        { $console.Write('a line') } | Should -Not -Throw
        { $console.Close() } | Should -Not -Throw
    }
}
