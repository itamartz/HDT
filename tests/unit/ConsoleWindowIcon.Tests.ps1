# The icon on the console's windows, and in the taskbar button.
#
# WPF FALLS BACK TO THE PROCESS ICON WHEN A WINDOW DECLARES NONE, and the
# process here is powershell.exe - so every window the console opened wore the
# PowerShell feather, in its title bar and in the taskbar. That is not a
# cosmetic complaint: a technician alt-tabbing between the console, a task
# sequence editor and a shell had three identical buttons to choose from.
#
# THE ICON IS DRAWN, NOT SHIPPED AS A FILE. A .ico in the module would be a
# binary asset nothing in this repository can diff or review, and it would have
# to be read off disk at a path that changes between a source tree, a bundle and
# an installed module. Geometry is text, and RenderTargetBitmap turns it into
# the ImageSource Window.Icon wants without touching the file system at all.
#
# WHAT IS ASSERTED HERE IS WHAT CAN BE WRONG WITHOUT LOOKING: the bitmap is the
# size a taskbar will ask for, it is frozen so a window on another thread may
# hold it, and no window in the console host was left without it. Whether the
# anvil looks like an anvil is decided by looking at it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # EVERY FILE THAT OPENS A WINDOW, not just the host. The three big windows
    # are BUILT in New-HDTConsole*View now and only SHOWN by the host - see
    # New-HDTConsoleView - so counting the host alone would let a window lose its
    # icon simply by moving, which is exactly the drift this test exists to stop.
    $script:hostSource = (@(
            'src\Hephaestus\Public\New-HDTConsoleHost.ps1'
            'src\Hephaestus\Private\New-HDTConsoleView.ps1'
            'src\Hephaestus\Private\New-HDTConsoleEditorView.ps1'
            'src\Hephaestus\Private\New-HDTConsoleBootImageView.ps1'
        ) | ForEach-Object {
            Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath $_) -Raw
        }) -join [System.Environment]::NewLine
}

Describe 'Get-HDTConsoleWindowIcon' {
    It 'draws a 256-pixel square, which is the largest size a shell asks for' {
        InModuleScope Hephaestus {
            $icon = Get-HDTConsoleWindowIcon

            $icon.PixelWidth | Should -Be 256
            $icon.PixelHeight | Should -Be 256
        }
    }

    It 'answers with an ImageSource, which is what Window.Icon takes' {
        InModuleScope Hephaestus {
            $icon = Get-HDTConsoleWindowIcon

            $icon -is [System.Windows.Media.ImageSource] | Should -BeTrue
        }
    }

    It 'freezes it, so a window built on another thread may hold it' {
        InModuleScope Hephaestus {
            (Get-HDTConsoleWindowIcon).IsFrozen | Should -BeTrue
        }
    }
}

Describe 'The console host' {
    # THE COUNT IS THE ASSERTION, because the failure this guards against is a
    # window somebody adds later and forgets - not one of the windows that are
    # here today. Every Window the host builds, whether it parsed it out of
    # markup or assembled it in code, is given the icon.
    It 'gives every window it opens the icon' {
        $built = ([regex]::Matches($script:hostSource, '\[System\.Windows\.Markup\.XamlReader\]::Load\(')).Count +
                 ([regex]::Matches($script:hostSource, 'New-Object -TypeName System\.Windows\.Window\b')).Count

        # Two spellings, one meaning. A window built inside a handler has to
        # reach the icon through Get-HDTHandlerCall, because a closure resolves
        # commands in the caller's scope and the icon is private.
        $iconed = ([regex]::Matches($script:hostSource,
                "\.Icon = (Get-HDTConsoleWindowIcon|& \`$call 'Get-HDTConsoleWindowIcon')")).Count

        $built | Should -BeGreaterThan 10
        $iconed | Should -Be $built
    }
}
