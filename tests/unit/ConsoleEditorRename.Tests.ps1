# RENAMING A STEP, THROUGH THE WINDOW THAT ACTUALLY DOES IT.
#
# WHAT WENT WRONG. The name box committed from LostFocus and asked for a tree
# rebuild in the same breath. Clicking another step moves focus out of the box
# BEFORE the tree has finished choosing a row, so the rebuild replaced
# ItemsSource mid-click - and threw, into the catch in $partitionAttempt, which
# puts the message on the Command line and returns. From the outside: typing a
# new name did nothing at all, Save stayed dark, the tree went on showing the
# old name, and clicking that row selected a step the document no longer had.
# The name box then came up DISABLED and Remove went dark.
#
# WHY IT SURVIVED EVERY TEST. Get-HDTConsoleEditorState and Set-HDTStepProperty
# are each right on their own - the rename splices perfectly when called
# directly. Only the ORDER of two handlers on one window was wrong, and nothing
# built the window and clicked through it.
#
# HOW THIS DRIVES A TREE WITH NO DESKTOP. Containers generate from a Measure /
# Arrange / UpdateLayout pass, so ItemContainerGenerator hands back a real
# TreeViewItem and setting ITS IsSelected is what a click does. Setting
# IsSelected on the bound row object instead does nothing: the rows are
# PSCustomObjects, they raise no property change, and the TwoWay binding never
# hears about it - which looks exactly like a dead handler and is not one.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # Hardware rendering on a build agent paints blank often enough to look
        # like a wiring failure when it is not.
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:editorXaml = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTSequenceEditor.xaml'))

        # TWO STEPS, because the fault only shows when the selection MOVES.
        $script:renameYaml = [string[]] @(
            'schemaVersion: 1'
            'id: DEMO-05'
            'name: Windows 11 bare metal'
            'steps:'
            '  - name: Prepare Boot'
            '    type: Validate'
            '  - name: Install Applications'
            '    type: Validate'
        )

        function New-HDTTestRenameWindow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param()

            $path = 'C:\ws\Control\DEMO-05\sequence.yaml'

            # -Node TAKES THE ROOTS, not the state. Handing it the state object
            # builds a tree of one row that carries no steps at all, and every
            # click test against it passes by finding nothing to break.
            $state = Get-HDTConsoleEditorState -Line $script:renameYaml -Path $path

            $window = New-HDTConsoleEditorView `
                -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
                -Xaml $script:editorXaml -Title 'DEMO-05' -Path $path `
                -Node ([object[]] @($state.Root)) -Line $script:renameYaml `
                -Catalog ([object[]] @(Get-HDTConsoleStepCatalog)) -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 0; Top = 0 }) `
                -Editor $state

            # AN ELEMENT THAT WAS NEVER SHOWN HAS NO SIZE, and a tree with no
            # size generates no containers - so nothing below could be clicked.
            $content = $window.Content
            $content.Measure([System.Windows.Size]::new(1180, 760))
            $content.Arrange([System.Windows.Rect]::new(0, 0, 1180, 760))
            $content.UpdateLayout()

            return $window
        }

        function Wait-HDTTestDispatcher {
            [CmdletBinding()]
            [OutputType([void])]
            param([Parameter(Mandatory = $true)] [object] $Window)

            # THE REBUILD IS DELIBERATELY DEFERRED to Background, so draining
            # the queue to that priority is what lets it run.
            $Window.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)
        }

        function Select-HDTTestStep {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Drives an in-memory window; it changes no state on the machine.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [object] $Window,
                [Parameter(Mandatory = $true)] [string] $Like)

            $tree = $Window.FindName('HDTStepTree')
            $tree.UpdateLayout()

            $row = @($tree.ItemsSource) |
                Where-Object { [string] $_.Text -like ('*{0}*' -f $Like) } |
                Select-Object -First 1
            if ($null -eq $row) { return $null }

            $item = $tree.ItemContainerGenerator.ContainerFromItem($row)
            if ($null -eq $item) { return $null }

            $item.IsSelected = $true
            Wait-HDTTestDispatcher -Window $Window

            return $row
        }

        function Get-HDTTestStepText {
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory = $true)] [object] $Window)

            return [string] ((@($Window.FindName('HDTStepTree').ItemsSource) |
                        ForEach-Object { [string] $_.Text }) -join ' | ')
        }
    }

    Describe 'renaming a step in the sequence editor' {

        BeforeAll {
            $script:renameWindow = New-HDTTestRenameWindow

            $script:nameBox = $script:renameWindow.FindName('HDTStepNameBox')
            $script:saveButton = $script:renameWindow.FindName('HDTSaveButton')

            $script:firstRow = Select-HDTTestStep -Window $script:renameWindow -Like 'Prepare Boot'

            $script:nameBefore = [string] $script:nameBox.Text
            $script:saveBefore = [bool] $script:saveButton.IsEnabled

            # TABBING OUT OF THE BOX IS THE COMMIT. There is no Apply here.
            $script:nameBox.Text = 'Stamp the time'
            $script:nameBox.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                        [System.Windows.UIElement]::LostFocusEvent)))
            Wait-HDTTestDispatcher -Window $script:renameWindow

            $script:saveAfter = [bool] $script:saveButton.IsEnabled
            $script:textAfter = Get-HDTTestStepText -Window $script:renameWindow
            $script:echoAfter = [string] $script:renameWindow.FindName('HDTEditorCommandText').Text

            # THE SEQUENCE THE REPORT DESCRIBED: away to another step, then back.
            [void] (Select-HDTTestStep -Window $script:renameWindow -Like 'Install Applications')
            $script:backRow = Select-HDTTestStep -Window $script:renameWindow -Like 'Stamp the time'
        }

        It 'selects a step through the tree and fills the name box from it' {
            # If this fails, nothing below is testing what it claims to.
            $script:firstRow | Should -Not -BeNullOrEmpty
            $script:nameBefore | Should -BeExactly 'Prepare Boot'
        }

        It 'leaves Save dark until something is actually edited' {
            # Walking a sequence and reading it must not offer to write the file.
            $script:saveBefore | Should -BeFalse
        }

        # THE HALF OF THE REPORT THAT SAID Save never went dirty.
        It 'lights Save as soon as the name box is left' {
            $script:saveAfter | Should -BeTrue
        }

        # THE HALF THAT SAID THE TREE KEPT THE OLD NAME.
        It 'shows the new name in the tree without waiting for another click' {
            $script:textAfter | Should -BeLike '*Stamp the time*'
            $script:textAfter | Should -Not -BeLike '*Prepare Boot*'
        }

        It 'still has the other step, under its own name' {
            $script:textAfter | Should -BeLike '*Install Applications*'
        }

        It 'reports the rename on the command line, not an exception from it' {
            # The rebuild used to throw into the catch in $partitionAttempt,
            # which puts the exception message here - so a Set-HDTStepProperty
            # line is the evidence that nothing was swallowed.
            $script:echoAfter | Should -BeLike '*Set-HDTStepProperty*'
        }

        # THE HALF THAT SAID the name could not be edited on the way back.
        It 'comes back to the renamed step with the name box still editable' {
            $script:backRow | Should -Not -BeNullOrEmpty -Because 'the renamed step must be in the tree'
            $script:nameBox.IsEnabled | Should -BeTrue
            $script:nameBox.Text | Should -BeExactly 'Stamp the time'
        }

        It 'comes back with Remove still offered, which needs the step to be found' {
            # Remove went dark for the same reason the name box did: the window
            # was holding a name the document no longer had.
            $script:renameWindow.FindName('HDTRemoveButton').IsEnabled | Should -BeTrue
        }
    }
}
