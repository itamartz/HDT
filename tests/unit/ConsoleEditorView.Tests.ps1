# The task sequence editor's window, built and wired without being shown.
#
# THE SAME SPLIT AS New-HDTConsoleView, AND THE SAME REASON. Building a window
# and showing one are different jobs, and only the second needs a desktop -
# Windows PowerShell's console host is already STA, XamlReader::Load is a markup
# parser, and a handler can be raised with RaiseEvent against no display. While
# the only entry point was a ScriptMethod ending in ShowDialog, several hundred
# handlers in this window were unreachable by construction.
#
# WHAT IS ASSERTED HERE IS THE WIRING, not the decisions. Every string the
# editor shows is decided by Get-HDTConsoleEditorState, Get-HDTConsoleStepCatalog
# and their neighbours, each with its own tests. What those cannot show is
# whether the markup still carries the control the host looks up by name, and
# whether the handler on it reaches the object it is supposed to write to.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Hardware rendering on a build agent paints blank often enough to look like
    # a wiring failure when it is not.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, so the window these tests build and the one the editor
    # opens cannot drift apart.
    $script:editorXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTSequenceEditor.xaml'))

    $script:sequenceYaml = [string[]] @(
        'schemaVersion: 1'
        'id: DEMO-05'
        'name: Windows 11 bare metal'
        'steps:'
        '  - name: Prepare Boot'
        '    type: Validate'
    )

    function New-HDTTestEditorHostDouble {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        return [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }
    }

    function New-HDTTestEditorWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [object] $ConsoleHost)

        # -Path IS MANDATORY. Without it the command waits for input, which in
        # a plain script is a hang and under Pester is a throw - the same trap
        # tests/contract/NoInteractivePrompt.Contract.Tests.ps1 exists for.
        $node = @(Get-HDTConsoleEditorState -Line $script:sequenceYaml `
                -Path 'C:\ws\Control\DEMO-05\sequence.yaml')

        return New-HDTConsoleEditorView -ConsoleHost $ConsoleHost -Xaml $script:editorXaml `
            -Title 'DEMO-05' -Path 'C:\ws\Control\DEMO-05\sequence.yaml' `
            -Node ([object[]] @($node)) -Line $script:sequenceYaml `
            -Catalog ([object[]] @(Get-HDTConsoleStepCatalog)) -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })
    }
}

Describe 'New-HDTConsoleEditorView' {

    Context 'the window it builds' {

        BeforeAll {
            $script:editorHostDouble = New-HDTTestEditorHostDouble
            $script:editorWindow = New-HDTTestEditorWindow -ConsoleHost $script:editorHostDouble
        }

        It 'builds a window without a desktop' {
            $script:editorWindow | Should -Not -BeNullOrEmpty
            $script:editorWindow.GetType().Name | Should -BeExactly 'Window'
        }

        It 'wears the anvil rather than the shell that started it' {
            $script:editorWindow.Icon | Should -Not -BeNullOrEmpty
        }

        It 'comes up at the size it was asked for' {
            $script:editorWindow.Width | Should -Be 1180
            $script:editorWindow.Height | Should -Be 760
        }

        # THE NAMES THE MARKUP PROMISES, resolved against the real tree rather
        # than against a regex over the file.
        It 'finds every control the editor wires by name' {
            foreach ($name in @('HDTEditorTitleText', 'HDTEditorPathText', 'HDTStepTree',
                    'HDTStepDetail', 'HDTEditorCommandText', 'HDTEditorCloseButton',
                    'HDTAddButton', 'HDTRemoveButton', 'HDTUpButton', 'HDTDownButton',
                    'HDTCopyButton', 'HDTPasteButton')) {

                $script:editorWindow.FindName($name) |
                    Should -Not -BeNullOrEmpty -Because "the markup promises $name"
            }
        }

        It 'puts the sequence it was given into the step tree' {
            @($script:editorWindow.FindName('HDTStepTree').ItemsSource).Count |
                Should -BeGreaterThan 0
        }

        It 'paints the palette onto the window' {
            $script:editorWindow.Resources['HDTErrorBrush'] | Should -Not -BeNullOrEmpty
        }
    }

    # THE POINT OF THE SPLIT.
    Context 'the Close button, pressed' {

        BeforeAll {
            $script:host2 = New-HDTTestEditorHostDouble
            $script:window2 = New-HDTTestEditorWindow -ConsoleHost $script:host2

            # The handler writes the answer and then closes the window, and a
            # window that was never SHOWN cannot be closed - see
            # tests/unit/ConsoleView.Tests.ps1. The answer lands first.
            try {
                $script:window2.FindName('HDTEditorCloseButton').RaiseEvent(
                    (New-Object System.Windows.RoutedEventArgs (
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } catch [System.Management.Automation.MethodInvocationException] {
                $script:closeRefusal = [string] $_.Exception.Message
            }
        }

        It 'writes Close onto the host the handlers were given' {
            # A handler closing over the wrong name writes nowhere at all, and a
            # window dismissed with the X never runs it - so it would survive
            # every screenshot ever taken of this editor.
            $script:host2.Answer | Should -BeExactly 'Close'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTConsoleEditorView -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTConsoleEditorView'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
