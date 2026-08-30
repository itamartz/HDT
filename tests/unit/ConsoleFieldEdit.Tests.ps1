# TYPING INTO THE DETAILS PANE, THROUGH THE WINDOW THAT ACTUALLY WRITES IT.
#
# WHAT WENT WRONG. Adding a version to a task sequence raised a message box
# saying Get-HDTHandlerCall was not recognized, and took the console down with
# it. The function exists; it is private, and $writeRow - the pane's writer -
# asked for it from INSIDE ITSELF. $writeRow used to be a plain scriptblock,
# where that worked; d0470cd made it a closure so it could see its maker's
# locals, and .GetNewClosure() binds a block to a fresh dynamic module whose
# command lookup falls through to the GLOBAL scope, where no private function
# of this module exists. Every private name inside a closure is unreachable,
# which is the whole reason Get-HDTHandlerCall exists - and it was the one name
# asked for the way it says not to.
#
# WHY EVERY EXISTING TEST MISSED IT. Set-HDTTaskSequenceProperty -Version is
# right on its own and has been for months. ConsoleButtonPress presses every
# BUTTON on the window - and this is not a button: it is LostFocus on a text box
# in the details pane, raised when a technician types a value and clicks away.
# Nothing typed.
#
# HOW THIS DRIVES A PANE WITH NO DESKTOP. The same way ConsoleEditorRename
# drives the tree: Measure / Arrange / UpdateLayout generates the item
# containers, so the TextBox the DataTemplate declares is a real element that
# can be given text and made to raise a real routed LostFocus - which is exactly
# what moving focus off it does.
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

        $script:consoleXaml = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTConsole.xaml'))

        $script:sequenceYaml = @(
            'schemaVersion: 1'
            'id: DEMO-05'
            'name: Windows 11 bare metal'
            'steps:'
            '  - name: Prepare Boot'
            '    type: Validate'
        ) -join [System.Environment]::NewLine

        # THE TEXTBOX THE DataTemplate DECLARES, found the way a click finds it.
        # FindName cannot: a templated item's controls are not in the window's
        # name scope, so the visual tree is what has to be walked.
        function Get-HDTTestTemplateBox {
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter(Mandatory = $true)] [object] $Root)

            $queue = New-Object -TypeName System.Collections.Queue
            $queue.Enqueue($Root)

            while ($queue.Count -gt 0) {
                $node = $queue.Dequeue()
                if ($node -is [System.Windows.Controls.TextBox]) { return $node }

                $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($i = 0; $i -lt $count; $i++) {
                    $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
                }
            }

            return $null
        }
    }

    Describe 'a version typed into the details pane of a task sequence' {

        BeforeAll {
            $script:documentPath = Join-Path -Path $TestDrive -ChildPath 'sequence.yaml'
            [System.IO.File]::WriteAllText($script:documentPath, $script:sequenceYaml)

            # THE REAL ROW BUILDERS, so the shape under test is the shape the
            # console shows. A hand-written row would pass whatever it declared.
            $field = @(New-HDTConsoleField -Label 'Version' -Value '' -Property 'version')

            $script:node = New-HDTConsoleNode -Depth 0 -Kind 'TaskSequence' -Status 'Ok' `
                -Text 'DEMO-05 - Windows 11 bare metal' -Name 'DEMO-05' -Field $field `
                -Command "Import-HDTSequenceDocument -Path '$script:documentPath'" `
                -Subject ([pscustomobject] @{ Path = $script:documentPath }) `
                -Header ([pscustomobject] @{
                        Title = 'DEMO'; Root = 'C:\ws'; DeployRoot = '\\host\ws'
                    })

            $script:window = New-HDTConsoleView `
                -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
                -Xaml $script:consoleXaml -Title 'Hephaestus' -Node ([object[]] @($script:node)) `
                -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 0; Top = 0 })

            # AN ELEMENT THAT WAS NEVER SHOWN HAS NO SIZE, and a control with no
            # size generates no containers - so nothing below could be typed in.
            $content = $script:window.Content
            $content.Measure([System.Windows.Size]::new(1800, 900))
            $content.Arrange([System.Windows.Rect]::new(0, 0, 1800, 900))
            $content.UpdateLayout()

            $tree = $script:window.FindName('HDTConsoleTree')
            $tree.UpdateLayout()

            $item = $tree.ItemContainerGenerator.ContainerFromItem($script:node)
            $item.IsSelected = $true

            $script:window.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)

            $detail = $script:window.FindName('HDTDetailList')
            $detail.UpdateLayout()

            $script:box = Get-HDTTestTemplateBox -Root $detail.ItemContainerGenerator.ContainerFromIndex(0)
        }

        It 'found the box the pane draws for the row, so nothing below is vacuous' {
            $script:box | Should -Not -BeNullOrEmpty
            $script:box.DataContext.Property | Should -BeExactly 'version'
        }

        Context 'and the focus moved off it' {

            BeforeAll {
                $script:box.Text = '2.1'

                # MOVING FOCUS OFF A BOX IS A ROUTED EVENT, and the handler is on
                # the pane rather than on the box, so it has to bubble - which is
                # what raising it here does and what calling the handler directly
                # would not prove.
                $script:threw = ''

                try {
                    $script:box.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                -ArgumentList ([System.Windows.Controls.TextBox]::LostFocusEvent)))
                } catch {
                    $script:threw = [string] $_.Exception.Message
                }

                $script:written = [System.IO.File]::ReadAllText($script:documentPath)
            }

            It 'does not throw out of the handler and onto a message box' {
                $script:threw | Should -BeNullOrEmpty
            }

            It 'writes the version into the document on disk' {
                $script:written | Should -Match 'version:\s*(''|")?2\.1'
            }

            It 'keeps the rest of the document, so the splice is a splice' {
                $script:written | Should -Match 'id:\s*DEMO-05'
                $script:written | Should -Match 'Prepare Boot'
            }

            It 'echoes the command that did it, which is what DESIGN 12 promises' {
                [string] $script:window.FindName('HDTCommandText').Text |
                    Should -BeExactly "Set-HDTTaskSequenceProperty -Line `$line -Version '2.1'"
            }

            It 'takes the typed value as the row''s new original, so Apply goes quiet' {
                [string] $script:box.DataContext.Original | Should -BeExactly '2.1'
            }
        }
    }
}
