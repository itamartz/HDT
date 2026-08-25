# The console window, built and wired without ever being shown.
#
# BUILDING A WINDOW AND SHOWING ONE ARE TWO DIFFERENT JOBS, and only the second
# needs a desktop. Windows PowerShell's console host is already STA,
# XamlReader::Load is a markup parser with no compiler behind it, and a handler
# attached to the tree can be raised with RaiseEvent against no display at all.
# While the only entry point was a ScriptMethod ending in ShowDialog, none of
# that could be reached - the method blocked, so nothing could assert on what it
# had wired.
#
# THIS IS THE FILE THAT TESTS THE WIRING ITSELF, not the decisions behind it.
# Every string on the screen is still decided by a Get-HDTConsole* command with
# its own tests; what is asserted here is that the markup, the palette and the
# handlers are actually connected to those decisions - which is exactly what a
# screenshot proves and no other test in this suite does.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # SOFTWARE RENDERING, because hardware rendering on a build agent paints
    # blank often enough to make this look like a wiring failure when it is not.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, read off disk rather than retyped, so the window these
    # tests build and the window the console opens cannot drift apart.
    $script:xaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTConsole.xaml'))

    function New-HDTTestConsoleHostDouble {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        # The four things the handlers write back to. Deliberately a plain
        # object: what matters is that the wiring reaches it by name.
        return [pscustomobject] @{
            Answer = ''
            Width  = 0
            Height = 0
            Window = $null
        }
    }

    function New-HDTTestConsoleNode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object[]])]
        param()

        return [object[]] @(
            [pscustomobject] @{
                Kind             = 'Root'
                Name             = 'Deployment Shares'
                Text             = 'Deployment Shares (0)'
                CanOpen          = $false
                Children         = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                HeaderTitle      = ''
                HeaderRoot       = ''
                HeaderDeployRoot = ''
                Depth            = 0
            }
        )
    }

    function New-HDTTestConsoleWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [object] $ConsoleHost)

        return New-HDTConsoleView -ConsoleHost $ConsoleHost -Xaml $script:xaml -Title 'Hephaestus' `
            -Node (New-HDTTestConsoleNode) -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 40; Top = 20 })
    }
}

Describe 'New-HDTConsoleView' {

    Context 'the window it builds' {

        BeforeAll {
            $script:host1 = New-HDTTestConsoleHostDouble
            $script:window = New-HDTTestConsoleWindow -ConsoleHost $script:host1
        }

        It 'builds a window without a desktop' {
            $script:window | Should -Not -BeNullOrEmpty
            $script:window.GetType().Name | Should -BeExactly 'Window'
        }

        It 'wears the title it was given' {
            $script:window.Title | Should -BeExactly 'Hephaestus'
        }

        It 'wears the anvil rather than the shell that started it' {
            # A window declaring no icon wears powershell.exe's feather, which
            # put two identical buttons on the taskbar.
            $script:window.Icon | Should -Not -BeNullOrEmpty
        }

        It 'comes up at the size it was asked for' {
            $script:window.Width | Should -Be 1800
            $script:window.Height | Should -Be 900
        }

        # THE SEVEN NAMES THE MARKUP PROMISES, resolved against the real tree
        # rather than against a regex over the file.
        It 'finds every control the host wires by name' {
            foreach ($name in @('HDTShareText', 'HDTDeployRootText', 'HDTRootText',
                    'HDTConsoleTree', 'HDTDetailList', 'HDTCommandText', 'HDTCloseButton')) {

                $script:window.FindName($name) | Should -Not -BeNullOrEmpty -Because "the markup promises $name"
            }
        }

        It 'hands the tree the roots it was given' {
            @($script:window.FindName('HDTConsoleTree').ItemsSource).Count | Should -Be 1
        }

        It 'paints the palette onto the window rather than leaving the default' {
            $script:window.Resources['HDTErrorBrush'] | Should -Not -BeNullOrEmpty
        }
    }

    # THE POINT OF THE SPLIT: a handler can now be raised without a display.
    Context 'the Close button, pressed' {

        BeforeAll {
            $script:host2 = New-HDTTestConsoleHostDouble
            $script:window2 = New-HDTTestConsoleWindow -ConsoleHost $script:host2

            $close = $script:window2.FindName('HDTCloseButton')

            # THE HANDLER SETS THE ANSWER AND THEN CLOSES THE WINDOW, and a
            # window that was never SHOWN cannot be closed: RestoreBounds is
            # Rect.Empty on one, its Width is infinite, and the Closing handler
            # casts that to [int]. The answer is written before any of that
            # happens, which is the half being asserted here - showing a window
            # is Show-HDTConsole's job and needs a desktop this test does not
            # have.
            try {
                $close.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } catch [System.Management.Automation.MethodInvocationException] {
                # Close() on a window that was never shown. See above.
                $script:closeRefusal = [string] $_.Exception.Message
            }
        }

        It 'writes Close onto the host the handlers were given' {
            # AND THIS IS THE BUG THE SPLIT WOULD HAVE CAUGHT. A handler closing
            # over the wrong name writes nowhere at all, and a window dismissed
            # with the X never runs it - so it survived every screenshot.
            $script:host2.Answer | Should -BeExactly 'Close'
        }
    }

    Context 'a window built for a second console' {

        It 'writes to its own host, not to the first one' {
            $other = New-HDTTestConsoleHostDouble
            $window = New-HDTTestConsoleWindow -ConsoleHost $other

            try {
                $window.FindName('HDTCloseButton').RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } catch [System.Management.Automation.MethodInvocationException] {
                # Close() on a window that was never shown. See the context above.
                $script:closeRefusal = [string] $_.Exception.Message
            }

            $other.Answer | Should -BeExactly 'Close'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTConsoleView -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTConsoleView'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
