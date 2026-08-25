# Every button on every console window, pressed with nothing selected.
#
# THIS IS THE TEST THAT WOULD HAVE CAUGHT BOTH $call BUGS. A handler naming a
# variable its scope does not carry - $writeRow and $drain were not closures, so
# the $call they named was never theirs - throws a null reference the first time
# a person presses it. Nothing else finds that: the analyzer cannot see into a
# scriptblock, and a screenshot only proves the button was DRAWN.
#
# NOTHING SELECTED IS THE STATE EVERY HANDLER MUST SURVIVE, and it is the state
# a window opens in. A menu item pressed on a fresh window must not take the
# window down; it may do nothing at all, and several of these do, but it has to
# do nothing DELIBERATELY - which is what the guards at the top of each handler
# are for. This presses them all and insists none of them throws.
#
# IT SWEEPS RATHER THAN LISTS, so a button added tomorrow is covered by this
# test the day it is added rather than the day somebody remembers.
#
# WHAT IT WILL NOT PRESS, and why - these are named, not silently skipped:
#   - anything that opens a window: ShowDialog blocks forever with no desktop;
#   - anything that reaches the share: tests/unit may not touch the real
#     filesystem, and Save and Reload do;
#   - Close: it has its own test, and it deliberately ends the window.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function Get-HDTTestMarkup {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory = $true)] [string] $Name)

        return [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath ('src\Hephaestus\UI\Console\{0}' -f $Name)))
    }

    function New-HDTTestPressHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        return [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }
    }

    # THE LOGICAL TREE, not the visual one. Nothing has been rendered, so the
    # visual tree of a templated control does not exist yet - but the tree
    # XamlReader parsed does, and every control the view looks up by name is in
    # it.
    function Get-HDTTestButton {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory = $true)] [object] $Root)

        $found = New-Object System.Collections.ArrayList
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($Root)

        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()

            if ($node -is [System.Windows.Controls.Button] -and
                -not [string]::IsNullOrWhiteSpace([string] $node.Name)) {

                [void] $found.Add($node)
            }

            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
                if ($child -is [System.Windows.DependencyObject]) { $queue.Enqueue($child) }
            }
        }

        return [object[]] @($found)
    }

    # NAMED, NOT SILENTLY SKIPPED. See the header for why each one is here.
    $script:wontPress = @(
        # Ends the window, and has its own test in ConsoleView.Tests.ps1.
        'HDTCloseButton', 'HDTEditorCloseButton', 'HDTBootImageCloseButton'

        # Reach the share. tests/unit may not touch the real filesystem.
        'HDTEditorSaveButton', 'HDTBootImageSaveButton', 'HDTRulesSaveButton'
        'HDTRulesReloadButton', 'HDTBootstrapSaveButton', 'HDTBootstrapReloadButton'

        # Open a file picker, which needs a desktop and blocks without one.
        'HDTBootImageUnattendBrowseButton', 'HDTBootImageBackgroundBrowseButton'
        'HDTCertificateBrowseButton', 'HDTClientCertificateBrowseButton'
        'HDTContentBrowseButton'

        # Own a child window, and Owner cannot be set from a window that was
        # never shown.
        'HDTClientCertificatePasswordButton'

        # Opens a child window THROUGH THE HOST - $partitionDialog calls
        # $editorHost.ShowPartitionProperties - so the ShowDialog is a level
        # down and a scan of the handler body does not see it. That is the
        # reason this list cannot be trusted on its own, and why every sweep
        # below also proves it wrote nothing.
        'HDTPartitionAddButton', 'HDTPartitionEditButton'

        # Runs a real boot image build - minutes of DISM, and it raises Save on
        # the way past.
        'HDTBootImageUpdateButton'

        # WRITES A FILE TO THE SHARE. New-HDTBootImageUnattend creates
        # Unattend-PE.xml, and pressing this in a test created a whole workspace
        # on the developer's disk - which is precisely what
        # "no unit test may reach the real filesystem" forbids.
        'HDTBootImageUnattendTemplateButton'
    )

    # AND A DENY-LIST IS NOT A GUARANTEE, which is the lesson of that workspace.
    # Every window here is pointed at a path that must not exist, and the test
    # asserts afterwards that it still does not - so a handler that writes gets
    # CAUGHT rather than remembered. The paths are per-window so a failure names
    # which sweep did it.
    $script:consolePath = Join-Path -Path $env:TEMP -ChildPath 'hdt-press-console'
    $script:editorPath = Join-Path -Path $env:TEMP -ChildPath 'hdt-press-editor'
    $script:imagePath = Join-Path -Path $env:TEMP -ChildPath 'hdt-press-image'

    function Invoke-HDTTestPress {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Raises a routed event on an in-memory control; it shows nothing.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory = $true)] [object] $Window)

        $pressed = New-Object System.Collections.ArrayList
        $threw = New-Object System.Collections.ArrayList
        $found = 0

        foreach ($button in (Get-HDTTestButton -Root $Window)) {
            $found++

            if ($script:wontPress -contains [string] $button.Name) { continue }

            # A DISABLED BUTTON IS ONE NOBODY CAN PRESS. WPF will not route a
            # click to it, and RaiseEvent goes round that - so pressing one here
            # tests a state the window never reaches and reports a failure the
            # user could never see. Several of these are dark until a step is
            # selected, on purpose.
            if (-not $button.IsEnabled) { continue }

            [void] $pressed.Add([string] $button.Name)

            try {
                $button.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                            [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } catch {
                [void] $threw.Add(('{0}: {1}' -f $button.Name, $_.Exception.Message))
            }
        }

        return [pscustomobject] @{
            Found   = $found
            Pressed = [string[]] @($pressed)
            Threw   = [string[]] @($threw)
        }
    }
}

Describe 'every button on the console, pressed with nothing selected' {

    BeforeAll {
        $script:consoleHostDouble = New-HDTTestPressHost

        $script:consoleWindow = New-HDTConsoleView -ConsoleHost $script:consoleHostDouble `
            -Xaml (Get-HDTTestMarkup -Name 'HDTConsole.xaml') -Title 'Hephaestus' `
            -Node ([object[]] @([pscustomobject] @{
                        Kind = 'Root'; Name = 'Deployment Shares'; Text = 'Deployment Shares (0)'
                        CanOpen = $false; Depth = 0
                        Children = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                        HeaderTitle = ''; HeaderRoot = ''; HeaderDeployRoot = ''
                    })) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 40; Top = 20 })

        $script:consoleResult = Invoke-HDTTestPress -Window $script:consoleWindow
    }

    It 'finds buttons, so a sweep that walked nothing cannot read as success' {
        # NOT Pressed. Every button on a fresh console is dark until a row is
        # chosen - Apply and Open Report both are - so pressing none of them is
        # the right answer here, and finding none would be a broken walk.
        $script:consoleResult.Found | Should -BeGreaterThan 0
    }

    It 'survives every press' {
        # A handler naming a variable its scope does not carry throws here and
        # nowhere else - see the header.
        $script:consoleResult.Threw | Should -BeNullOrEmpty
    }

    It 'answers nothing, because nothing was chosen' {
        $script:consoleHostDouble.Answer | Should -BeExactly ''
    }

    It 'wrote nothing to disk' {
        Test-Path -LiteralPath $script:consolePath | Should -BeFalse
    }
}

Describe 'every button on the task sequence editor, pressed with nothing selected' {

    BeforeAll {
        $line = [string[]] @(
            'schemaVersion: 1'
            'id: DEMO-05'
            'name: Windows 11 bare metal'
            'steps:'
            '  - name: Prepare Boot'
            '    type: Validate'
        )

        $script:editorHostDouble = New-HDTTestPressHost

        $script:editorWindow = New-HDTConsoleEditorView -ConsoleHost $script:editorHostDouble `
            -Xaml (Get-HDTTestMarkup -Name 'HDTSequenceEditor.xaml') -Title 'DEMO-05' `
            -Path (Join-Path -Path $script:editorPath -ChildPath 'Control\DEMO-05\sequence.yaml') `
            -Node ([object[]] @(Get-HDTConsoleEditorState -Line $line `
                        -Path (Join-Path -Path $script:editorPath -ChildPath 'Control\DEMO-05\sequence.yaml'))) `
            -Line $line -Catalog ([object[]] @(Get-HDTConsoleStepCatalog)) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })

        $script:editorResult = Invoke-HDTTestPress -Window $script:editorWindow
    }

    It 'presses something' {
        $script:editorResult.Pressed.Count | Should -BeGreaterThan 0
    }

    It 'survives every press' {
        $script:editorResult.Threw | Should -BeNullOrEmpty
    }

    It 'wrote nothing to disk' {
        Test-Path -LiteralPath $script:editorPath | Should -BeFalse
    }
}

Describe 'every button on the Windows PE window, pressed with nothing selected' {

    BeforeAll {
        $script:imageHostDouble = New-HDTTestPressHost

        $script:imageWindow = New-HDTConsoleBootImageView -ConsoleHost $script:imageHostDouble `
            -Xaml (Get-HDTTestMarkup -Name 'HDTBootImage.xaml') `
            -Path (Join-Path -Path $script:imagePath -ChildPath 'workspace.yaml') `
            -Line ([string[]] @('schemaVersion: 1', 'id: HDT-LAB', 'name: HDT deployment share',
                    'bootImage:', '  name: HDTPE_wiz_x64', '  architecture: amd64')) `
            -Component ([object[]] @()) -DriverGroup ([object[]] @()) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })

        $script:imageResult = Invoke-HDTTestPress -Window $script:imageWindow
    }

    It 'presses something' {
        $script:imageResult.Pressed.Count | Should -BeGreaterThan 0
    }

    It 'survives every press' {
        $script:imageResult.Threw | Should -BeNullOrEmpty
    }

    It 'wrote nothing to disk' {
        # THE ASSERTION THAT WOULD HAVE CAUGHT IT. The template button wrote
        # Unattend-PE.xml and a workspace beside it before it was excluded.
        Test-Path -LiteralPath $script:imagePath | Should -BeFalse
    }
}

}
