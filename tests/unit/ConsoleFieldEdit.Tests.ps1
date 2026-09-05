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

# ONE TEST BELOW IS SKIPPED ON A GITHUB-HOSTED RUNNER ONLY, NEVER HERE.
#
# Renaming a row raises a real WPF LostFocus event whose handler writes the
# document and then rebuilds the tree. On this machine, and every local run,
# that always completes clean. On GitHub's Windows runner it has failed the
# same way three scheduled Coverage runs running (2026-09-03 through
# 2026-09-05, including a run against a commit that fixed an UNRELATED,
# already-diagnosed EOL-dependent regex defect - so this is not that bug
# recurring):
#
#   Exception calling "RaiseEvent": Cannot validate argument on parameter
#   'Path'. The argument is null or empty.
#
# Traced as far as $rebuildTree in New-HDTConsoleView.ps1: $openShare already
# filters blank HeaderRoot values before anything is handed a -Path, so the
# empty value is arriving from a WPF dispatcher timing difference on that
# runner's hardware/OS image, not from this file's own logic - and it will not
# reproduce here to be iterated on. Skipped rather than deleted, with the
# reason on record, per the user's decision on 2026-09-05. The write this
# handler performs is unaffected either way: the document is saved BEFORE the
# rebuild that throws, and the test asserting the write itself is not skipped.
#
# $env:, NOT A $script: VARIABLE. The It sits inside InModuleScope, and
# InModuleScope's -Skip: read happens in the MODULE's script scope, not this
# file's - Get-HDTSlowSuiteSkipViolation exists for exactly this class of
# cross-scope trap. $env: is process-global, so there is no scope to cross.

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

    # THE SAME GESTURE ON AN IMPORTED UPDATE, which had no write path at all: the
    # pane showed a name it could not change and no description row whatever.
    #
    # DRIVEN THROUGH THE WINDOW FOR THE REASON ABOVE. Set-HDTWindowsUpdate can be
    # right on its own and the pane still write nothing - the row has to reach
    # Get-HDTConsoleRowDocument, come back naming a command that takes a share
    # and an id rather than lines, and be called with neither of the two
    # parameters the read-splice-save path would have handed it.
    Describe 'a description typed into the details pane of an imported update' {

        BeforeAll {
            $script:updateRoot = Join-Path -Path $TestDrive -ChildPath 'share'
            $script:updateFolder = Join-Path -Path $script:updateRoot -ChildPath 'WindowsUpdates\KB5094126-x64'

            [void] (New-Item -Path $script:updateFolder -ItemType Directory -Force)

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:updateRoot -ChildPath 'workspace.yaml'),
                "schemaVersion: 1`nid: HDT`nname: HDT share`n")

            $script:updatePath = Join-Path -Path $script:updateFolder -ChildPath 'update.yaml'

            [System.IO.File]::WriteAllText($script:updatePath, (@(
                        '# Imported from the Update Catalogue.'
                        'schemaVersion: 1'
                        'id: KB5094126-x64'
                        'kb: KB5094126'
                        'name: KB5094126 for Windows 11 24H2'
                        'release: Win11-24H2'
                        'kind: CumulativeUpdate'
                        'architecture: x64'
                        'fileName: windows11.0-kb5094126-x64.msu'
                        'enabled: true'
                    ) -join [System.Environment]::NewLine))

            # THE REAL ROW BUILDERS, so the shape under test is the shape the
            # console shows. Only the two rows the pane makes typeable, so the
            # container index below is the row it names.
            $field = @(
                New-HDTConsoleField -Label 'Name' -Value 'KB5094126 for Windows 11 24H2' -Property 'name'
                New-HDTConsoleField -Label 'Description' -Value '' -Property 'description'
            )

            $script:updateNode = New-HDTConsoleNode -Depth 0 -Kind 'WindowsUpdate' -Status 'Ok' `
                -Text 'KB5094126 - KB5094126 for Windows 11 24H2' -Name 'KB5094126-x64' -Field $field `
                -Command "Get-HDTWindowsUpdate -WorkspaceRoot '$script:updateRoot' -Id 'KB5094126-x64'" `
                -Subject ([pscustomobject] @{ Path = $script:updatePath }) `
                -Header ([pscustomobject] @{
                        Title = 'HDT'; Root = $script:updateRoot; DeployRoot = $script:updateRoot
                    })

            # OpenShare IS ON THE REAL HOST and the rebuild writes to it - what
            # the window ended up with, for Show-HDTConsole to remember after it
            # closes. A rename rebuilds the tree, so a double without it fails on
            # the write rather than on anything under test.
            $script:updateWindow = New-HDTConsoleView `
                -ConsoleHost ([pscustomobject] @{
                        Answer = ''; Width = 0; Height = 0; Window = $null; OpenShare = [string[]] @()
                    }) `
                -Xaml $script:consoleXaml -Title 'Hephaestus' -Node ([object[]] @($script:updateNode)) `
                -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 0; Top = 0 })

            $content = $script:updateWindow.Content
            $content.Measure([System.Windows.Size]::new(1800, 900))
            $content.Arrange([System.Windows.Rect]::new(0, 0, 1800, 900))
            $content.UpdateLayout()

            $tree = $script:updateWindow.FindName('HDTConsoleTree')
            $tree.UpdateLayout()

            $item = $tree.ItemContainerGenerator.ContainerFromItem($script:updateNode)
            $item.IsSelected = $true

            $script:updateWindow.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)

            $detail = $script:updateWindow.FindName('HDTDetailList')
            $detail.UpdateLayout()

            $script:updateNameBox = Get-HDTTestTemplateBox -Root $detail.ItemContainerGenerator.ContainerFromIndex(0)
            $script:updateDescriptionBox = Get-HDTTestTemplateBox -Root $detail.ItemContainerGenerator.ContainerFromIndex(1)
        }

        It 'draws a typeable box for each of the two rows' {
            $script:updateNameBox.DataContext.Property | Should -BeExactly 'name'
            $script:updateDescriptionBox.DataContext.Property | Should -BeExactly 'description'

            $script:updateNameBox.IsReadOnly | Should -BeFalse
            $script:updateDescriptionBox.IsReadOnly | Should -BeFalse
        }

        Context 'and the focus moved off the description' {

            BeforeAll {
                $script:updateDescriptionBox.Text = 'Held back until the June servicing window.'
                $script:updateThrew = ''

                try {
                    $script:updateDescriptionBox.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                -ArgumentList ([System.Windows.Controls.TextBox]::LostFocusEvent)))
                } catch {
                    $script:updateThrew = [string] $_.Exception.Message
                }

                $script:updateWritten = [System.IO.File]::ReadAllText($script:updatePath)
            }

            It 'does not throw out of the handler and onto a message box' {
                $script:updateThrew | Should -BeNullOrEmpty
            }

            It 'writes the description into update.yaml on disk' {
                $script:updateWritten | Should -Match 'description:.*June servicing window'
            }

            It 'splices rather than re-serialising, so the comment survives' {
                $script:updateWritten | Should -Match '# Imported from the Update Catalogue\.'
                $script:updateWritten | Should -Match 'id:\s*KB5094126-x64'
                $script:updateWritten | Should -Match 'fileName:\s*windows11'
            }

            It 'echoes the command that did it, which is what DESIGN 12 promises' {
                [string] $script:updateWindow.FindName('HDTCommandText').Text |
                    Should -BeExactly ("Set-HDTWindowsUpdate -WorkspaceRoot '{0}' -Id 'KB5094126-x64' -Description 'Held back until the June servicing window.'" -f $script:updateRoot)
            }

            It 'takes the typed value as the row''s new original' {
                [string] $script:updateDescriptionBox.DataContext.Original |
                    Should -BeExactly 'Held back until the June servicing window.'
            }
        }

        Context 'and the name is renamed after it' {

            BeforeAll {
                $script:updateNameBox.Text = '2026-06 cumulative update, Windows 11 24H2'
                $script:renameThrew = ''

                try {
                    $script:updateNameBox.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                -ArgumentList ([System.Windows.Controls.TextBox]::LostFocusEvent)))
                } catch {
                    $script:renameThrew = [string] $_.Exception.Message
                }

                $script:renameWritten = [System.IO.File]::ReadAllText($script:updatePath)
            }

            # A RENAME REBUILDS THE TREE, which re-reads every open share - so
            # this is also the only test that drives that path for an update, and
            # a share that would not reopen would surface here.
            #
            # SKIPPED ON GITHUB'S RUNNER ONLY - see the file header for the
            # three-day trail and why it is not the EOL regex defect.
            It 'does not throw out of the handler and onto a message box' -Skip:([bool] $env:GITHUB_ACTIONS) {
                $script:renameThrew | Should -BeNullOrEmpty
            }

            It 'writes the new name and keeps the description it wrote before' {
                $script:renameWritten | Should -Match 'name:.*2026-06 cumulative update'
                $script:renameWritten | Should -Match 'June servicing window'
            }

            It 'leaves the id alone, because it is the folder name' {
                $script:renameWritten | Should -Match 'id:\s*KB5094126-x64'
            }
        }
    }
}
