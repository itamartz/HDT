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

Describe 'the overlay window itself' {

    # FOUND ON A BOOTED VM, WHICH IS THE ONLY PLACE IT WAS VISIBLE. The first
    # version was WindowState="Maximized" and transparent, on the reasoning that
    # a window with no ground of its own does not cover anything. It does: its
    # lines were drawn ACROSS THE WELCOME SCREEN, over the share box and the
    # credential fields a technician was meant to type into.
    #
    # A PANEL, NOT A SCREEN. These assertions are cheap and they are the only
    # thing standing between that defect and the next person who reaches for
    # Maximized because it saves computing a size.

    BeforeAll {
        $script:markup = [xml] $script:realXaml
    }

    It 'is not maximized' {
        $script:markup.DocumentElement.GetAttribute('WindowState') | Should -Not -Be 'Maximized'
    }

    It 'declares a width and a height of its own' {
        [double] $script:markup.DocumentElement.GetAttribute('Width') | Should -BeGreaterThan 0
        [double] $script:markup.DocumentElement.GetAttribute('Height') | Should -BeGreaterThan 0
    }

    It 'is smaller than the smallest screen WinPE comes up on' {
        # 1024x768. A panel that filled it would be the maximized window again
        # by another route.
        [double] $script:markup.DocumentElement.GetAttribute('Width') | Should -BeLessThan 1024
        [double] $script:markup.DocumentElement.GetAttribute('Height') | Should -BeLessThan 768
    }

    It 'sits in the middle of the screen' {
        $script:markup.DocumentElement.GetAttribute('WindowStartupLocation') | Should -Be 'CenterScreen'
    }

    It 'is transparent, so the wallpaper behind it is the point' {
        $script:markup.DocumentElement.GetAttribute('AllowsTransparency') | Should -Be 'True'
        $script:markup.DocumentElement.GetAttribute('Background') | Should -Be 'Transparent'
    }

    It 'is not Topmost, so nothing it cannot close can end up under it' {
        $script:markup.DocumentElement.GetAttribute('Topmost') | Should -Not -Be 'True'
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

    It 'offers no Hide or Show, because the window owns its own z-order' {
        # THE VERBS THAT COST THREE ROUNDS ON A BOOTED VM. The payload used them
        # to keep the panel off the Welcome screen; SetWindowPos(HWND_BOTTOM) in
        # New-HDTBootStatusHost is what actually does that, once, at Open.
        foreach ($name in @('Hide', 'Show')) {
            (New-HDTConsoleBootStatusHost).PSObject.Methods.Name | Should -Not -Contain $name
            (New-HDTBootStatusHost).PSObject.Methods.Name | Should -Not -Contain $name
        }
    }

    It 'never throws from any of them' {
        $console = New-HDTConsoleBootStatusHost

        { $console.Open('<Window />', 'X:\Windows\System32\cmd.exe') } | Should -Not -Throw
        { $console.Write('a line') } | Should -Not -Throw
        { $console.Close() } | Should -Not -Throw
    }

    It 'attempts no z-order trick, because z-order was never the problem' {
        # MEASURED ON A BOOTED VM. WinPE runs no compositor, so a transparent
        # window's repaint is not clipped by whatever is above it - an opaque
        # cmd.exe window covered this panel completely while the Welcome screen
        # was bled through the instant the panel repainted. SetWindowPos
        # (HWND_BOTTOM) was tried and changed nothing, and dead Win32 that
        # encodes a wrong theory is worse than none.
        #
        # ShowDialog IS ALSO GONE: Close() here is a flag the UI thread's timer
        # reads, which a modal dialog makes awkward for no gain.
        $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                -ChildPath 'src/Hephaestus/Public/New-HDTBootStatusHost.ps1') -Raw

        # THE CALL, NOT THE WORD. The header above explains the trap by naming
        # it, and a raw scan for the name convicts the one file that had to say
        # it - the same lesson tests/contract/WinPeUiStack.Contract.Tests.ps1
        # already wrote down twice.
        $source | Should -Not -Match '::SetWindowPos'
        $source | Should -Not -Match 'HDTBootStatusNative'
        $source | Should -Not -Match '\$window\.ShowDialog'
        $source | Should -Match 'Dispatcher\]::Run'
    }
}
