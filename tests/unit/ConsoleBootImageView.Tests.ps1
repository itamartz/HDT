# The Windows PE window, built and wired without being shown.
#
# THIS IS DEPLOYMENT WORKBENCH'S DEPLOYMENT SHARE PROPERTIES: the boot image's
# name and architecture, its optional components, its drivers and its
# customisations. It is the window a technician spends the longest in before a
# build, and until the ShowDialog split every handler on it was unreachable by
# construction - see New-HDTConsoleView.
#
# WHAT IS ASSERTED HERE IS THE WIRING. What each control decides is
# Get-HDTConsoleBootImage's, Get-HDTConsoleBootImageEdit's and
# Test-HDTConsoleComponentWrite's, each with its own tests. What those cannot
# show is whether the markup still carries the control the host looks up by
# name, and whether the handler on it reaches the object it writes to.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, so this window and the one the console opens cannot
    # drift apart.
    $script:bootXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTBootImage.xaml'))

    $script:workspaceYaml = [string[]] @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT deployment share'
        'bootImage:'
        '  name: HDTPE_wiz_x64'
        '  architecture: amd64'
        '  scratchSpaceMB: 512'
    )

    function New-HDTTestImageHostDouble {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        return [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }
    }

    function New-HDTTestBootImageWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [object] $ConsoleHost)

        return New-HDTConsoleBootImageView -ConsoleHost $ConsoleHost -Xaml $script:bootXaml `
            -Path 'C:\ws\workspace.yaml' -Line $script:workspaceYaml `
            -Component ([object[]] @()) -DriverGroup ([object[]] @()) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })
    }
}

Describe 'New-HDTConsoleBootImageView' {

    Context 'the window it builds' {

        BeforeAll {
            $script:imageHostDouble = New-HDTTestImageHostDouble
            $script:imageWindow = New-HDTTestBootImageWindow -ConsoleHost $script:imageHostDouble
        }

        It 'builds a window without a desktop' {
            $script:imageWindow | Should -Not -BeNullOrEmpty
            $script:imageWindow.GetType().Name | Should -BeExactly 'Window'
        }

        It 'wears the anvil rather than the shell that started it' {
            $script:imageWindow.Icon | Should -Not -BeNullOrEmpty
        }

        It 'finds the controls the host wires by name' {
            foreach ($name in @('HDTBootImageTitleText', 'HDTBootImagePathText',
                    'HDTBootImageCloseButton')) {

                $script:imageWindow.FindName($name) |
                    Should -Not -BeNullOrEmpty -Because "the markup promises $name"
            }
        }

        It 'paints the palette onto the window' {
            $script:imageWindow.Resources['HDTErrorBrush'] | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the Close button, pressed' {

        BeforeAll {
            $script:imageHost2 = New-HDTTestImageHostDouble
            $script:imageWindow2 = New-HDTTestBootImageWindow -ConsoleHost $script:imageHost2

            # A window that was never SHOWN cannot be closed - see
            # tests/unit/ConsoleView.Tests.ps1. The answer lands first.
            try {
                $script:imageWindow2.FindName('HDTBootImageCloseButton').RaiseEvent(
                    (New-Object System.Windows.RoutedEventArgs (
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } catch [System.Management.Automation.MethodInvocationException] {
                $script:imageCloseRefusal = [string] $_.Exception.Message
            }
        }

        It 'writes Close onto the host the handlers were given' {
            $script:imageHost2.Answer | Should -BeExactly 'Close'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTConsoleBootImageView -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTConsoleBootImageView'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
