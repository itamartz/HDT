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

        # THE SAME WALK, FOR ANY CONTROL. Two of a media row's fields are drawn
        # as a ComboBox now, and Get-HDTTestTemplateBox cannot reach one - it is
        # left as it is because three other Describes here use it.
        #
        # AND THE COLLAPSED BOX IS WHY THIS IS NEEDED RATHER THAN CONVENIENT.
        # HDTDetailBox and HDTDetailChoice SHARE column 1; the HasChoice trigger
        # collapses the box, it does not remove it. A collapsed TextBox is still
        # in the visual tree, still breadth-first AHEAD of the ComboBox, and
        # still raises a real routed LostFocus the pane writes on - so a test
        # that kept taking the box would go on passing about a control no
        # technician can touch.
        function Get-HDTTestTemplateControl {
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [object] $Root,
                [Parameter(Mandatory = $true)] [type] $Kind
            )

            $queue = New-Object -TypeName System.Collections.Queue
            $queue.Enqueue($Root)

            while ($queue.Count -gt 0) {
                $node = $queue.Dequeue()
                if ($Kind.IsInstanceOfType($node)) { return $node }

                $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($i = 0; $i -lt $count; $i++) {
                    $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
                }
            }

            return $null
        }

        # THE ELEMENT THE TEMPLATE NAMED, ASKED FOR BY THAT NAME. Neither walk
        # above can find the help dot: it is a Border, and a TextBox's own
        # control template puts a Border in the tree BREADTH-FIRST AHEAD of it,
        # so a type walk returns the wrong control and every assertion about the
        # dot would be about the box's chrome.
        #
        # A DataTemplate HAS ITS OWN NAME SCOPE and the item container is the
        # ContentPresenter that applied it, which is exactly what
        # DataTemplate.FindName takes - so this is the API for the job rather
        # than a tree walk with a name test bolted on.
        function Get-HDTTestTemplateNamed {
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [object] $Container,
                [Parameter(Mandatory = $true)] [string] $Name
            )

            if ($null -eq $Container) { return $null }
            if ($null -eq $Container.ContentTemplate) { return $null }

            return $Container.ContentTemplate.FindName($Name, $Container)
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

    # THE SAME DEFECT THIS FILE EXISTS FOR, ON THE NEWEST ROW KIND. $writeRow's
    # Media branch calls & $call 'Get-HDTConsoleMediaEdit' from inside a closure
    # bound to a fresh dynamic module - a private name written any other way
    # resolves in the GLOBAL scope and throws 'is not recognized' the moment a
    # technician types into the box, the way the version defect this file's
    # header describes did for Get-HDTHandlerCall. Nothing that reads the
    # source rather than running it can catch that.
    Describe 'a field typed into the details pane of a media item' {

        BeforeAll {
            $script:mediaRoot = Join-Path -Path $TestDrive -ChildPath 'share'
            $script:mediaFolder = Join-Path -Path $script:mediaRoot -ChildPath 'Media\HYDRA'

            [void] (New-Item -Path $script:mediaFolder -ItemType Directory -Force)

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $script:mediaRoot -ChildPath 'workspace.yaml'),
                "schemaVersion: 1`nid: HDT`nname: HDT share`n")

            $script:mediaPath = Join-Path -Path $script:mediaFolder -ChildPath 'media.yaml'

            [System.IO.File]::WriteAllText($script:mediaPath, (@(
                        '# HDT standalone media definition.'
                        'schemaVersion: 1'
                        'id: HYDRA'
                        'name: Hydration - Windows 11 and Server 2025'
                        'selectionProfile: hydration'
                        'output: Media\HYDRA\HDT_HYDRA.iso'
                        'enabled: true'
                    ) -join [System.Environment]::NewLine))

            # THE REAL ROW BUILDER, NOT TWO FIELDS HAND-WRITTEN HERE. Two of a
            # media row's fields are lists now, and a hand-built row would pass
            # whatever it declared - including a box, on a pane that draws a
            # combo. This is Get-HDTConsoleMediaNode's own field list, from
            # Get-HDTMedia's own output.
            $script:mediaItem = @(Get-HDTMedia -WorkspaceRoot $script:mediaRoot)

            # THE PROFILES THIS SHARE ACTUALLY OFFERS, read the way the share
            # node reads them. It matters that these are the REAL ones:
            # Set-HDTMedia validates a pick against Get-HDTSelectionProfile, so
            # a list invented here would let the test pass on a pick the command
            # would refuse in the console. There is no selection-profiles.yaml
            # on this share, so these are the built-in fallback - and
            # 'hydration', which the document names, is NOT among them. That is
            # the stale case, and it is what the refusal Context below drives.
            $script:mediaProfile = @(Get-HDTSelectionProfile -Root $script:mediaRoot)

            $script:mediaCategory = Get-HDTConsoleMediaNode -Media $script:mediaItem `
                -Root $script:mediaRoot -SelectionProfile $script:mediaProfile `
                -Header ([pscustomobject] @{
                        Title = 'HDT'; Root = $script:mediaRoot; DeployRoot = $script:mediaRoot
                    })

            $script:mediaNode = @($script:mediaCategory.Children)[0]

            $script:mediaWindow = New-HDTConsoleView `
                -ConsoleHost ([pscustomobject] @{
                        Answer = ''; Width = 0; Height = 0; Window = $null; OpenShare = [string[]] @()
                    }) `
                -Xaml $script:consoleXaml -Title 'Hephaestus' -Node ([object[]] @($script:mediaNode)) `
                -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 0; Top = 0 })

            $content = $script:mediaWindow.Content
            $content.Measure([System.Windows.Size]::new(1800, 900))
            $content.Arrange([System.Windows.Rect]::new(0, 0, 1800, 900))
            $content.UpdateLayout()

            $tree = $script:mediaWindow.FindName('HDTConsoleTree')
            $tree.UpdateLayout()

            $item = $tree.ItemContainerGenerator.ContainerFromItem($script:mediaNode)
            $item.IsSelected = $true

            $script:mediaWindow.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)

            $detail = $script:mediaWindow.FindName('HDTDetailList')
            $detail.UpdateLayout()

            # THE ROW CONTAINERS, BY THE LABEL THEY CARRY rather than by an
            # index written down here: the field list is the row builder's, and
            # a row added to it would silently shift every index below it.
            $script:mediaLabel = @(@($script:mediaNode.Field) | ForEach-Object { [string] $_.Label })

            $script:mediaContainerFor = {
                param([string] $Label)
                $at = [array]::IndexOf([string[]] $script:mediaLabel, $Label)
                if ($at -lt 0) { return $null }
                return $detail.ItemContainerGenerator.ContainerFromIndex($at)
            }

            $script:mediaDescriptionContainer = & $script:mediaContainerFor 'Description'
            $script:mediaProfileContainer = & $script:mediaContainerFor 'Selection profile'
            $script:mediaEnabledContainer = & $script:mediaContainerFor 'Enabled'

            $script:mediaDescriptionBox = Get-HDTTestTemplateControl -Root $script:mediaDescriptionContainer `
                -Kind ([System.Windows.Controls.TextBox])

            $script:mediaProfileCombo = Get-HDTTestTemplateControl -Root $script:mediaProfileContainer `
                -Kind ([System.Windows.Controls.ComboBox])

            $script:mediaEnabledCombo = Get-HDTTestTemplateControl -Root $script:mediaEnabledContainer `
                -Kind ([System.Windows.Controls.ComboBox])

            # THE COLLAPSED BOXES BEHIND THE TWO LISTS, taken so the drawing
            # assertions can read BOTH controls off the one container. Asserting
            # only that a ComboBox exists in the subtree would pass on a row
            # where the two were stacked in the same column.
            $script:mediaProfileBox = Get-HDTTestTemplateControl -Root $script:mediaProfileContainer `
                -Kind ([System.Windows.Controls.TextBox])

            $script:mediaEnabledBox = Get-HDTTestTemplateControl -Root $script:mediaEnabledContainer `
                -Kind ([System.Windows.Controls.TextBox])

            # THE OUTPUT ROW AND THE THREE THAT MUST NOT GROW A BUTTON. The
            # read-only ones are taken as a SET rather than one of them, because
            # the browse button is collapsed by default and the failure being
            # guarded against - a trigger bound to the wrong property - would
            # show it on every row at once.
            $script:mediaOutputContainer = & $script:mediaContainerFor 'Output'

            $script:mediaOutputBox = Get-HDTTestTemplateControl -Root $script:mediaOutputContainer `
                -Kind ([System.Windows.Controls.TextBox])

            $script:mediaOutputButton = Get-HDTTestTemplateNamed -Container $script:mediaOutputContainer `
                -Name 'HDTDetailBrowseButton'

            $script:mediaOutputDot = Get-HDTTestTemplateNamed -Container $script:mediaOutputContainer `
                -Name 'HDTDetailHelpDot'

            $script:mediaQuietRow = @('Id', 'Last build', 'Document') | ForEach-Object {
                [pscustomobject] @{
                    Label  = $_
                    Button = (Get-HDTTestTemplateNamed -Container (& $script:mediaContainerFor $_) `
                            -Name 'HDTDetailBrowseButton')
                    Dot    = (Get-HDTTestTemplateNamed -Container (& $script:mediaContainerFor $_) `
                            -Name 'HDTDetailHelpDot')
                }
            }

            $script:mediaDescriptionButton = Get-HDTTestTemplateNamed -Container $script:mediaDescriptionContainer `
                -Name 'HDTDetailBrowseButton'

            # THE DROP-DOWN'S OWN ARROW, which is a ToggleButton - the control
            # whose Click bubbles up to the browse handler on every open.
            $script:mediaEnabledToggle = Get-HDTTestTemplateControl -Root $script:mediaEnabledContainer `
                -Kind ([System.Windows.Controls.Primitives.ToggleButton])

            $script:mediaProfileToggle = Get-HDTTestTemplateControl -Root $script:mediaProfileContainer `
                -Kind ([System.Windows.Controls.Primitives.ToggleButton])
        }

        # THE INDEX-TO-LABEL MAPPING, ASSERTED. Every Context below reaches its
        # control through the label; this is the one place that proves a label
        # names the row somebody thinks it does, so a reordered field list fails
        # here loudly instead of testing the wrong row quietly.
        It 'takes each control off the row its label names' {
            $script:mediaDescriptionBox.DataContext.Property | Should -BeExactly 'description'
            $script:mediaProfileCombo.DataContext.Property | Should -BeExactly 'selectionProfile'
            $script:mediaEnabledCombo.DataContext.Property | Should -BeExactly 'enabled'
        }

        Context 'the pane as it is drawn' {

            # VISIBILITY, NOT PRESENCE - see Get-HDTTestTemplateControl. Both
            # controls are in the tree on every row; which one a technician can
            # reach is the whole question.
            It 'draws the selection profile as a list, not a box' {
                [string] $script:mediaProfileCombo.Visibility | Should -BeExactly 'Visible'
                [string] $script:mediaProfileBox.Visibility | Should -BeExactly 'Collapsed'
            }

            It 'draws enabled as a list, not a box' {
                [string] $script:mediaEnabledCombo.Visibility | Should -BeExactly 'Visible'
                [string] $script:mediaEnabledBox.Visibility | Should -BeExactly 'Collapsed'
            }

            It 'draws the description as a box, because a description is not a closed set' {
                [string] $script:mediaDescriptionBox.Visibility | Should -BeExactly 'Visible'
                $script:mediaDescriptionBox.IsReadOnly | Should -BeFalse
            }

            It 'fills the profile list from the share and shows the media''s own profile selected' {
                $offered = @(@($script:mediaProfileCombo.ItemsSource) | ForEach-Object { [string] $_ })

                foreach ($offering in @($script:mediaProfile)) {
                    $offered | Should -Contain ([string] $offering.Id)
                }

                # THE DOCUMENT'S OWN, FIRST, because this share no longer offers
                # it. An empty combo here would read as "no profile set".
                [string] @($offered)[0] | Should -BeExactly 'hydration'
                [string] $script:mediaProfileCombo.SelectedItem | Should -BeExactly 'hydration'
            }

            It 'offers exactly true and false on the enabled list' {
                @(@($script:mediaEnabledCombo.ItemsSource) | ForEach-Object { [string] $_ }) |
                    Should -Be @('true', 'false')

                [string] $script:mediaEnabledCombo.SelectedItem | Should -BeExactly 'true'
            }
        }

        Context 'the description, typed and focus moved off it' {

            BeforeAll {
                $script:mediaDescriptionThrew = ''
                $script:mediaDescriptionBox.Text = 'The bench disc.'

                try {
                    $script:mediaDescriptionBox.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                -ArgumentList ([System.Windows.Controls.TextBox]::LostFocusEvent)))
                } catch {
                    $script:mediaDescriptionThrew = [string] $_.Exception.Message
                }

                $script:mediaDescriptionWritten = [System.IO.File]::ReadAllText($script:mediaPath)
            }

            It 'does not throw Get-HDTConsoleMediaEdit is not recognized, or anything else' {
                $script:mediaDescriptionThrew | Should -BeNullOrEmpty
            }

            It 'writes the description into media.yaml on disk, through Set-HDTMedia' {
                $script:mediaDescriptionWritten | Should -Match 'description:.*The bench disc\.'
            }

            It 'splices rather than re-serialising, so the comment survives' {
                $script:mediaDescriptionWritten | Should -Match '# HDT standalone media definition\.'
                $script:mediaDescriptionWritten | Should -Match 'id:\s*HYDRA'
                $script:mediaDescriptionWritten | Should -Match 'selectionProfile:\s*hydration'
            }
        }

        # THE PICK, ALL THE WAY TO DISK AND BACK. This replaces
        # 'enabled, typed as no and focus moved off it', which drove the TEXT
        # box - collapsed under the list since the row became a Choice, and so
        # green about a control nobody can reach. Strictly stronger: that one
        # stopped at a regex on the file, this one hands the file to
        # Assert-HDTMediaDocument and reads it back through Get-HDTMedia.
        Context 'false picked from the enabled list' {

            BeforeAll {
                $script:enabledPickThrew = ''

                # SETTING SelectedItem IS THE PICK. Selector raises a real
                # bubbling SelectionChanged from it, which is the routed event
                # the pane's handler is registered for - calling the handler
                # directly would prove nothing about the wiring.
                try {
                    $script:mediaEnabledCombo.SelectedItem = 'false'

                    $script:mediaWindow.Dispatcher.Invoke([action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background)
                } catch {
                    $script:enabledPickThrew = [string] $_.Exception.Message
                }

                $script:enabledPickWritten = [System.IO.File]::ReadAllText($script:mediaPath)
            }

            It 'does not throw out of the handler and onto a message box' {
                $script:enabledPickThrew | Should -BeNullOrEmpty
            }

            It 'writes a bare enabled: false into media.yaml, not a quoted string' {
                # A QUOTED BOOLEAN IS A STRING, and a string is not a tick box -
                # Assert-HDTMediaDocument refuses one, so the pane picking a
                # word that arrived quoted would write a file the share cannot
                # read back.
                $script:enabledPickWritten | Should -Match '(?m)^enabled:\s*false\s*$'
            }

            It 'is accepted by Assert-HDTMediaDocument' {
                # THE SAME READER Get-HDTMedia USES, so this is not asserting
                # against a second parser that might be kinder than the real one.
                $document = ConvertFrom-HDTYaml -Yaml $script:enabledPickWritten -Path $script:mediaPath

                { Assert-HDTMediaDocument -Document $document -Path $script:mediaPath -Id 'HYDRA' } |
                    Should -Not -Throw
            }

            It 'is read back by Get-HDTMedia as a real [bool] that is false' {
                $read = @(Get-HDTMedia -WorkspaceRoot $script:mediaRoot -Id 'HYDRA')[0]

                $read.Enabled | Should -BeOfType ([bool])
                $read.Enabled | Should -BeFalse
            }

            It 'leaves the comment at the top of media.yaml alone' {
                $script:enabledPickWritten | Should -Match '# HDT standalone media definition\.'
            }

            It 'leaves every other key alone' {
                $script:enabledPickWritten | Should -Match '(?m)^id:\s*HYDRA\s*$'
                $script:enabledPickWritten | Should -Match '(?m)^selectionProfile:\s*hydration\s*$'
                $script:enabledPickWritten | Should -Match 'output:.*HDT_HYDRA\.iso'
                $script:enabledPickWritten | Should -Match 'name:\s*Hydration'
            }
        }

        Context 'a selection profile picked from the list' {

            BeforeAll {
                # ONE THE SHARE ACTUALLY OFFERS, which is also one Set-HDTMedia
                # will accept - the list and the command read the same source.
                $script:profilePicked = [string] @($script:mediaProfile)[0].Id
                $script:profilePickThrew = ''

                # IT MUST DIFFER FROM Original, or Test-HDTConsoleRowCommit
                # refuses the pick and this Context passes by never committing.
                $script:profilePicked | Should -Not -BeExactly ([string] $script:mediaProfileCombo.DataContext.Original)

                try {
                    $script:mediaProfileCombo.SelectedItem = $script:profilePicked

                    $script:mediaWindow.Dispatcher.Invoke([action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background)
                } catch {
                    $script:profilePickThrew = [string] $_.Exception.Message
                }

                $script:profilePickWritten = [System.IO.File]::ReadAllText($script:mediaPath)
            }

            It 'does not throw out of the handler' {
                $script:profilePickThrew | Should -BeNullOrEmpty
            }

            # NO ANGLE BRACKETS IN THE NAME. Pester expands <id> as a data
            # placeholder and this It has no -ForEach to fill it, so the name
            # alone threw 'the variable $id cannot be retrieved'.
            It 'writes the picked profile id into media.yaml, as a bare unquoted value' {
                $script:profilePickWritten |
                    Should -Match ('(?m)^selectionProfile:\s*{0}\s*$' -f [regex]::Escape($script:profilePicked))
            }

            It 'is read back by Get-HDTMedia as that profile' {
                $read = @(Get-HDTMedia -WorkspaceRoot $script:mediaRoot -Id 'HYDRA')[0]

                [string] $read.SelectionProfile | Should -BeExactly $script:profilePicked
            }

            It 'leaves the comment and the other keys alone' {
                $script:profilePickWritten | Should -Match '# HDT standalone media definition\.'
                $script:profilePickWritten | Should -Match '(?m)^id:\s*HYDRA\s*$'
                $script:profilePickWritten | Should -Match '(?m)^enabled:\s*false\s*$'
                $script:profilePickWritten | Should -Match 'output:.*HDT_HYDRA\.iso'
            }
        }

        # THE PANE'S REFUSAL PATH, which no closed list can otherwise produce
        # any more: 'maybe' cannot be picked off a list of true and false, so
        # the Context that typed it is gone. This is what replaces it, and it is
        # the only refusal left - the stale profile the row shows FIRST is on
        # the list precisely because the document names it, and Set-HDTMedia
        # validates against the share and refuses it.
        Context 'a profile the share no longer offers, picked' {

            BeforeAll {
                $script:staleBefore = [System.IO.File]::ReadAllBytes($script:mediaPath)
                $script:staleThrew = ''

                'hydration' | Should -Not -BeExactly ([string] $script:mediaProfileCombo.DataContext.Original)

                try {
                    $script:mediaProfileCombo.SelectedItem = 'hydration'

                    $script:mediaWindow.Dispatcher.Invoke([action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background)
                } catch {
                    $script:staleThrew = [string] $_.Exception.Message
                }

                $script:staleAfter = [System.IO.File]::ReadAllBytes($script:mediaPath)
            }

            It 'does not throw out of the handler and onto a message box' {
                $script:staleThrew | Should -BeNullOrEmpty
            }

            It 'writes nothing to media.yaml - the file is unchanged byte for byte' {
                [System.Convert]::ToBase64String($script:staleAfter) |
                    Should -BeExactly ([System.Convert]::ToBase64String($script:staleBefore))
            }

            It 'puts the control back to the profile the document actually names' {
                [string] $script:mediaProfileCombo.SelectedItem | Should -BeExactly $script:profilePicked
            }

            It 'says what was wrong in the footer, rather than in a message box' {
                [string] $script:mediaWindow.FindName('HDTCommandText').Text |
                    Should -BeLike '*hydration*'

                [string] $script:mediaWindow.FindName('HDTCommandText').Text |
                    Should -BeLike '*no selection profile*'
            }
        }

        # REBUILDING THE PANE RAISES SelectionChanged WITH NOTHING SELECTED,
        # before the binding has settled - and writing that would clear the key
        # on every click of the tree. -Picked is the guard, and this is the only
        # test that drives it through a real window.
        Context 'the pane rebuilt, which raises SelectionChanged with nothing selected' {

            BeforeAll {
                $script:nullPickBefore = [System.IO.File]::ReadAllBytes($script:mediaPath)
                $script:nullPickThrew = ''

                try {
                    $script:mediaProfileCombo.SelectedItem = $null

                    $script:mediaWindow.Dispatcher.Invoke([action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background)
                } catch {
                    $script:nullPickThrew = [string] $_.Exception.Message
                }

                $script:nullPickAfter = [System.IO.File]::ReadAllBytes($script:mediaPath)
            }

            It 'does not throw out of the handler' {
                $script:nullPickThrew | Should -BeNullOrEmpty
            }

            It 'writes nothing when SelectedItem is null - the -Picked guard' {
                [System.Convert]::ToBase64String($script:nullPickAfter) |
                    Should -BeExactly ([System.Convert]::ToBase64String($script:nullPickBefore))
            }
        }

        # THE DIALOG ITSELF IS NOT EXERCISED BY ANY TEST IN THIS FILE, AND THAT
        # GAP IS ON RECORD RATHER THAN AN OVERSIGHT. SaveFileDialog.ShowDialog
        # is modal and there is no desktop under Pester, so what these three
        # Contexts prove is the WIRING - that the button is drawn on the right
        # row and points at the right box - and the WRITE - that a path put into
        # that box reaches media.yaml. 07-05-03's live probe is what proves the
        # dialog opens, is filtered and cancels cleanly.
        Context 'the Output row, drawn' {

            It 'draws a Browse button on it' {
                # VISIBILITY, NOT PRESENCE. HasBrowse SHOWS a button that is
                # collapsed by default - it does not add one - so every row in
                # this pane has one in its visual tree and only this row's can
                # be clicked.
                $script:mediaOutputButton | Should -Not -BeNullOrEmpty
                [string] $script:mediaOutputButton.Visibility | Should -BeExactly 'Visible'
            }

            It 'points that button at the box on its own row, so a click knows which field it is filling' {
                # ElementName WITHIN THE TEMPLATE'S OWN NAME SCOPE, which is why
                # this resolves to the box beside it and not to some other row's.
                # The alternative - walking up to the Grid and back down for a
                # TextBox - finds the wrong control the day the template gains a
                # second one.
                $script:mediaOutputButton.Tag | Should -BeOfType ([System.Windows.Controls.TextBox])
                [object]::ReferenceEquals($script:mediaOutputButton.Tag, $script:mediaOutputBox) |
                    Should -BeTrue -Because 'the button must fill the box on its own row'

                [string] $script:mediaOutputButton.DataContext.Property | Should -BeExactly 'output'
                [string] $script:mediaOutputButton.DataContext.Browse | Should -BeExactly 'IsoFile'

                # AND IT CARRIES THE NAME THE HANDLER GUARDS ON. x:Name in a
                # DataTemplate sets the instance's Name too, which is how a
                # click arriving by a routed event can say which control it came
                # from - FindName cannot reach into a template's name scope.
                [string] $script:mediaOutputButton.Name | Should -BeExactly 'HDTDetailBrowseButton'
            }

            It 'draws no Browse button on the description row' {
                [string] $script:mediaDescriptionButton.Visibility | Should -BeExactly 'Collapsed'
            }

            It 'draws no Browse button on the read-only rows' {
                foreach ($quiet in @($script:mediaQuietRow)) {
                    [string] $quiet.Button.Visibility |
                        Should -BeExactly 'Collapsed' -Because ('{0} picks nothing off a disk' -f $quiet.Label)
                }
            }

            It 'still draws the help dot beside it, rather than losing it to the new column' {
                # THE RE-PARENT, ASSERTED. The dot moved out of the Grid column
                # and into a StackPanel to share it with the button, and a
                # template trigger finds its TargetName wherever it sits - but a
                # silently dead trigger looks exactly like a row that has no
                # hint, so it is checked BOTH ways: shown where there is a hint,
                # collapsed where there is not.
                [string] $script:mediaOutputDot.Visibility | Should -BeExactly 'Visible'

                foreach ($quiet in @($script:mediaQuietRow)) {
                    [string] $quiet.Dot.Visibility |
                        Should -BeExactly 'Collapsed' -Because ('{0} carries no hint' -f $quiet.Label)
                }
            }
        }

        # ButtonBase.Click IS A BUBBLING ROUTED EVENT AND A ComboBox's ARROW IS
        # A ToggleButton, so 07-05-01's two lists raise the browse handler on
        # every open. Without this Context, widening the handler's
        # OriginalSource guard from Button to ButtonBase - which reads like
        # being safe - would go green here and route a click on the Enabled list
        # into $writeRow.
        Context 'a click on a drop-down, which bubbles the same Click event' {

            BeforeAll {
                $script:bubbleBefore = [System.IO.File]::ReadAllBytes($script:mediaPath)
                $script:bubbleOutputBefore = [string] $script:mediaOutputBox.Text
                $script:bubbleThrew = ''

                try {
                    # WHAT ToggleButton.OnClick ITSELF RAISES. Driving the arrow
                    # through UI Automation would not do it - a Toggle pattern
                    # call does not raise Click - so the routed event is raised
                    # from the control that raises it in the product.
                    foreach ($arrow in @($script:mediaEnabledToggle, $script:mediaProfileToggle)) {
                        $arrow.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                    -ArgumentList ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                    }

                    $script:mediaWindow.Dispatcher.Invoke([action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background)
                } catch {
                    $script:bubbleThrew = [string] $_.Exception.Message
                }

                $script:bubbleAfter = [System.IO.File]::ReadAllBytes($script:mediaPath)
            }

            It 'is ignored - the enabled list opens and nothing is written' {
                $script:bubbleThrew | Should -BeNullOrEmpty

                [System.Convert]::ToBase64String($script:bubbleAfter) |
                    Should -BeExactly ([System.Convert]::ToBase64String($script:bubbleBefore))
            }

            It 'is ignored on the selection profile list too' {
                # BOTH ARROWS WERE CLICKED ABOVE, and this says so rather than
                # leaving the second one covered by the first one's assertion.
                $script:mediaProfileToggle | Should -Not -BeNullOrEmpty
                $script:mediaEnabledToggle | Should -Not -BeNullOrEmpty

                [string] $script:mediaProfileToggle.GetType().Name | Should -Not -BeExactly 'Button'
            }

            It 'leaves the Output box exactly as it was' {
                [string] $script:mediaOutputBox.Text | Should -BeExactly $script:bubbleOutputBefore
            }
        }

        # THE WRITE THE BUTTON ENDS IN, driven by putting a path into the box
        # the way a pick puts one there. A SPACE IN THE PATH ON PURPOSE: it is
        # what a picked path off a real disk looks like, and it is where a
        # splice that quoted or split on whitespace would show.
        Context 'a path put into the Output box the way a pick puts it there' {

            BeforeAll {
                $script:pickedPath = 'D:\Builds\field kit.iso'
                $script:outputThrew = ''

                $script:mediaOutputBox.Text = $script:pickedPath

                $binding = $script:mediaOutputBox.GetBindingExpression(
                    [System.Windows.Controls.TextBox]::TextProperty)

                if ($null -ne $binding) { [void] $binding.UpdateSource() }

                try {
                    $script:mediaOutputBox.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                                -ArgumentList ([System.Windows.Controls.TextBox]::LostFocusEvent)))
                } catch {
                    $script:outputThrew = [string] $_.Exception.Message
                }

                $script:outputWritten = [System.IO.File]::ReadAllText($script:mediaPath)
            }

            It 'writes the picked path into media.yaml' {
                $script:outputThrew | Should -BeNullOrEmpty

                $script:outputWritten |
                    Should -Match ('(?m)^output:\s*''?{0}''?\s*$' -f [regex]::Escape($script:pickedPath))
            }

            It 'is accepted by Assert-HDTMediaDocument' {
                $document = ConvertFrom-HDTYaml -Yaml $script:outputWritten -Path $script:mediaPath

                { Assert-HDTMediaDocument -Document $document -Path $script:mediaPath -Id 'HYDRA' } |
                    Should -Not -Throw
            }

            It 'is read back by Get-HDTMedia as that path' {
                $read = @(Get-HDTMedia -WorkspaceRoot $script:mediaRoot -Id 'HYDRA')[0]

                [string] $read.OutputPath | Should -BeExactly $script:pickedPath
            }

            It 'leaves the comment at the top of media.yaml alone' {
                $script:outputWritten | Should -Match '# HDT standalone media definition\.'
                $script:outputWritten | Should -Match '(?m)^id:\s*HYDRA\s*$'
            }
        }
    }
}
