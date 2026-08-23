# The task sequence editor window: what it is handed, and what its markup must
# contain for the adapter to find anything.
#
# THE ADAPTER IS NOT TESTED AND MUST THEREFORE DECIDE NOTHING. New-HDTConsoleHost
# loads the markup, assigns an ItemsSource and attaches handlers by name. Every
# decision - the title, the rows, the properties, which cmdlet each row shows -
# is made in a command and asserted here. That is what leaves the adapter
# honestly exempt from TDD (CLAUDE.md rule 1).
#
# THE CONTROL NAMES ARE A CONTRACT between HDTSequenceEditor.xaml and the host.
# Renaming one in the markup breaks FindName silently at runtime - the window
# opens and one button simply never works. Asserting the names here turns that
# into a red test on a developer machine.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:xamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/Console/HDTSequenceEditor.xaml'

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      - name: Validate
        type: Validate
        minRamMB: 2048
  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
'@

    function New-HDTFakeEditorHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Action = 'Close'
        )

        $fake = [pscustomobject] @{
            Action    = $Action
            ShowCount = 0
            Xaml      = ''
            Title     = ''
            Path      = ''
            Node      = @()
            Line      = @()
            Catalog   = @()
            Theme     = $null

            # The size the window was told to open at. The real adapter assigns
            # it to Width and Height and nothing else, so recording it here is
            # what proves the decision reached the window without one existing.
            Size      = $null
        }

        $fake | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
            param(
                [string] $Xaml, [string] $Title, [string] $Path,
                [object[]] $Node, [string[]] $Line, [object[]] $Catalog, [object] $Theme,
                [object] $Size
            )

            $this.ShowCount = $this.ShowCount + 1
            $this.Xaml = $Xaml
            $this.Title = $Title
            $this.Path = $Path
            $this.Node = $Node
            $this.Line = $Line
            $this.Catalog = $Catalog
            $this.Theme = $Theme
            $this.Size = $Size

            return [string] $this.Action
        }

        return $fake
    }

    function New-HDTEditorTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        return New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                      = $script:workspaceYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = $script:sequenceYaml
        }
    }

    function New-HDTEditorTestSequence {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        $workspace = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                          = $script:workspaceYaml
                'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'     = $script:sequenceYaml
            })

        return @($workspace.TaskSequence)[0]
    }
}

Describe 'HDTSequenceEditor.xaml' {

    BeforeAll {
        $script:markup = [System.IO.File]::ReadAllText($script:xamlPath)
    }

    It 'is there' {
        Test-Path -LiteralPath $script:xamlPath | Should -BeTrue
    }

    It 'is loadable XAML' {
        { [xml] $script:markup } | Should -Not -Throw
    }

    It 'is loadable by WPF, which is a stricter reader than the XML parser' {
        # [xml] only proves the angle brackets balance. XamlReader is what the
        # host actually calls, and it is the one that rejects a binding to a
        # converter the window cannot instantiate, a property a control does not
        # have, or a StaticResource that was never declared - all of which parse
        # as XML perfectly well and then produce a window that never opens.
        #
        # This was written after IsReadOnly was bound through a
        # {StaticResource HDTNotConverter} that could not exist: the markup has
        # no code-behind and no assembly to point an xmlns at, so there is
        # nowhere for a converter to come from. Every name-and-shape assertion
        # above passed on that file.
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $script:markup)

        { [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
    }

    It 'declares <Name>, which the host finds by name' -ForEach @(
        @{ Name = 'HDTEditorTitleText' }
        @{ Name = 'HDTEditorPathText' }
        @{ Name = 'HDTStepTree' }
        @{ Name = 'HDTStepDetail' }
        @{ Name = 'HDTEditorCommandText' }
        @{ Name = 'HDTAddButton' }
        @{ Name = 'HDTRemoveButton' }
        @{ Name = 'HDTUpButton' }
        @{ Name = 'HDTDownButton' }
        @{ Name = 'HDTCopyButton' }
        @{ Name = 'HDTPasteButton' }
        @{ Name = 'HDTSaveButton' }
        @{ Name = 'HDTVariableButton' }
        @{ Name = 'HDTVariableGrid' }
        @{ Name = 'HDTVariableNameBox' }
        @{ Name = 'HDTVariableValueBox' }
        @{ Name = 'HDTVariableSetButton' }
        @{ Name = 'HDTVariableRemoveButton' }
        @{ Name = 'HDTEditorCloseButton' }

        # The Add menu, and the Options tab.
        @{ Name = 'HDTAddMenu' }
        @{ Name = 'HDTOptionTab' }
        @{ Name = 'HDTDisableCheck' }
        @{ Name = 'HDTContinueCheck' }
        @{ Name = 'HDTConditionText' }
        @{ Name = 'HDTConditionClearButton' }
        @{ Name = 'HDTRunInText' }

        # The Properties tab, which now writes - and is named, because a step
        # with a page of its own does not get one.
        @{ Name = 'HDTPropertyTab' }

        # The name, above the tabs as MDT has it: renaming a step cannot depend
        # on a tab that is not always there.
        @{ Name = 'HDTStepNameBox' }

        # The Disk tab - MDT's Format and Partition Disk page. Which disk and
        # how it is laid out at the top, then the volume list and its buttons.
        @{ Name = 'HDTDiskTab' }
        @{ Name = 'HDTDiskNumberBox' }
        @{ Name = 'HDTDiskStyleBox' }
        @{ Name = 'HDTDiskWipeCheck' }
        @{ Name = 'HDTPartitionList' }
        @{ Name = 'HDTPartitionStyleText' }
        @{ Name = 'HDTPartitionAddButton' }
        @{ Name = 'HDTPartitionEditButton' }
        @{ Name = 'HDTPartitionRemoveButton' }
        @{ Name = 'HDTPartitionUpButton' }
        @{ Name = 'HDTPartitionDownButton' }

        # The Operating System page - MDT's Install Operating System dialog.
        @{ Name = 'HDTImageTab' }
        @{ Name = 'HDTImageBox' }
        @{ Name = 'HDTImageIndexBox' }
        @{ Name = 'HDTImageTargetBox' }
        @{ Name = 'HDTImageTimeoutBox' }

        # The Run Command Line page - MDT's dialog for that step, minus the
        # run-as account HDT has no equivalent for. Start in is why it exists:
        # the engine has always read workingDirectory and nothing in the console
        # could write one.
        @{ Name = 'HDTCommandTab' }
        @{ Name = 'HDTCommandLineBox' }
        @{ Name = 'HDTCommandLineLabel' }
        @{ Name = 'HDTCommandFileBox' }
        @{ Name = 'HDTCommandFileLabel' }
        @{ Name = 'HDTCommandArgumentsBox' }
        @{ Name = 'HDTCommandArgumentsLabel' }
        @{ Name = 'HDTCommandStartInBox' }
        @{ Name = 'HDTCommandSuccessBox' }
        @{ Name = 'HDTCommandRebootBox' }
        @{ Name = 'HDTCommandNoteText' }

        # The Applications page - MDT's Install Application dialog, which asks
        # which of its two answers the step is before it asks anything else.
        @{ Name = 'HDTApplicationTab' }
        @{ Name = 'HDTApplicationVariableRadio' }
        @{ Name = 'HDTApplicationVariableBox' }
        @{ Name = 'HDTApplicationFixedRadio' }
        @{ Name = 'HDTApplicationList' }
        @{ Name = 'HDTApplicationEmptyText' }
        @{ Name = 'HDTApplicationNoteText' }
    ) {
        $script:markup | Should -Match ('x:Name="{0}"' -f $Name)
    }
}

Describe 'the Partition Properties dialog' {

    # MDT OPENS A MODAL FOR New AND Edit, and so does this. The names here are
    # the same kind of contract the editor's are: renaming one in the markup
    # breaks FindName silently, and the dialog opens with one box that never
    # fills and an OK that hands back nothing.

    BeforeAll {
        $script:dialogPath = Join-Path -Path $script:repoRoot `
            -ChildPath 'src/Hephaestus/UI/Console/HDTPartitionProperties.xaml'

        $script:dialogMarkup = [System.IO.File]::ReadAllText($script:dialogPath)
    }

    It 'is shipped beside the editor it is opened from' {
        Test-Path -LiteralPath $script:dialogPath | Should -BeTrue
    }

    It 'is markup WPF can load' {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $script:dialogMarkup)

        { [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
    }

    It 'declares <Name>, which the host finds by name' -ForEach @(
        @{ Name = 'HDTVolumeNameBox' }
        @{ Name = 'HDTVolumeTypeBox' }
        @{ Name = 'HDTVolumeSizeBox' }
        @{ Name = 'HDTVolumeUnitBox' }
        @{ Name = 'HDTVolumeFileSystemBox' }
        @{ Name = 'HDTVolumeVariableBox' }
        @{ Name = 'HDTVolumeQuickFormatCheck' }
        @{ Name = 'HDTVolumeBootableCheck' }
        @{ Name = 'HDTVolumeMessageText' }
        @{ Name = 'HDTVolumeOkButton' }
    ) {
        $script:dialogMarkup | Should -Match ('x:Name="{0}"' -f $Name)
    }

    It 'has no code-behind, like every other window here' {
        $script:dialogMarkup | Should -Not -Match 'x:Class='
    }

    It 'paints from the console theme rather than from its own colours' {
        # One decision repaints every window. A dialog with literal colours is
        # the one that stays light when the console goes dark.
        $script:dialogMarkup | Should -Match 'DynamicResource HDTPanelBrush'
        $script:dialogMarkup | Should -Match 'DynamicResource HDTBorderBrush'
    }

    It 'lets each properties row decide its own box rather than keeping a list of labels' {
        # Get-HDTConsoleStepNode named the YAML key each row writes, and set
        # ReadOnly from that. A window with its own opinion about which labels
        # are typeable is a window that can disagree with the splice.
        $script:markup | Should -Match 'IsReadOnly="\{Binding ReadOnly\}"'
    }

    It 'commits typing to the row on the keystroke, not on losing focus' {
        # The row object IS the edit buffer and Apply diffs it against Original.
        # LostFocus - TextBox's default - would drop whatever was typed into the
        # last box before Apply was pressed, because pressing it is what moves
        # the focus.
        $script:markup | Should -Match 'UpdateSourceTrigger=PropertyChanged'
    }

    It 'hangs a menu off Add rather than a plain button, which is how Workbench offers a step type' {
        # Get-HDTConsoleStepCatalog decides what is in it; this only asserts
        # there is somewhere to put it. An Add that opened no menu would leave
        # the catalog built, tested and unreachable.
        $script:markup | Should -Match '(?s)<ContextMenu[^>]*x:Name="HDTAddMenu"'
    }

    It 'splits the right-hand pane into Properties and Options, the way MDT does' {
        # THE TABS ARE IN THE MARKUP, THEIR HEADERS ARE IN THE STRING TABLE.
        # Asserting the words here would assert them in English, and the window
        # carries no text of its own any more.
        $script:markup | Should -Match 'x:Name="HDTPropertyTab"'
        $script:markup | Should -Match 'x:Name="HDTOptionsTab"'

        $string = Get-HDTStringTable -Page 'SequenceEditor'
        [string] $string['HDTPropertyTab.Header'] | Should -BeExactly 'Properties'
        [string] $string['HDTOptionsTab.Header'] | Should -BeExactly 'Options'
    }

    It 'draws the actions as a toolbar rather than as a row of filled buttons' {
        # MDT and ConfigMgr both use a flat toolbar; a row of solid blue pills
        # is the one part of this window that would not read as Workbench.
        $script:markup | Should -Match 'x:Key="HDTToolButton"'
        $script:markup | Should -Match 'Style="\{StaticResource HDTToolButton\}"'
    }

    It 'has no code-behind, like every other window in the toolkit' {
        # The ATTRIBUTE, not the words: the file's own comment explains why
        # there is no x:Class, and matching that prose passes for the wrong
        # reason and would keep passing if somebody added the attribute.
        $script:markup | Should -Not -Match 'x:Class\s*='
    }

    It 'paints every colour through a DynamicResource, so one theme serves both windows' {
        # A hard-coded colour survives the theme swap and shows up as one pale
        # panel in an otherwise dark window.
        $script:markup | Should -Not -Match 'Background="#'
    }

    It 'declares the same size the module falls back to when nothing opened it' {
        # Two files hold these numbers - the markup, for a window loaded on its
        # own, and the module, because Resolve-HDTConsoleEditorSize has to
        # answer with a size when there is no console to copy. Drift between
        # them is invisible: the editor would open at one size from the browser
        # and another from the command line.
        $document = [xml] $script:markup
        $module = Get-Module -Name 'Hephaestus'

        [double] $document.DocumentElement.GetAttribute('Width') |
            Should -Be (& $module { $script:HDTConsoleEditorDefaultWidth })
        [double] $document.DocumentElement.GetAttribute('Height') |
            Should -Be (& $module { $script:HDTConsoleEditorDefaultHeight })
        [double] $document.DocumentElement.GetAttribute('MinWidth') |
            Should -Be (& $module { $script:HDTConsoleEditorMinimumWidth })
        [double] $document.DocumentElement.GetAttribute('MinHeight') |
            Should -Be (& $module { $script:HDTConsoleEditorMinimumHeight })
    }

    It 'takes the position it is given rather than centring itself' {
        # The editor opens at the work area's origin, filling it, exactly as the
        # console does - and WPF honours an assigned Left and Top only under
        # Manual. Under CenterOwner it would recentre over the console and the
        # two numbers Resolve-HDTConsoleWindowPosition worked out would be
        # silently ignored.
        $script:markup | Should -Match 'WindowStartupLocation="Manual"'
    }
}

Describe 'Show-HDTSequenceEditor' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Show-HDTSequenceEditor' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'hands the host the editor rows, not the whole document' {
        $editorHost = New-HDTFakeEditorHost

        # THE FILE SYSTEM IS NOT OPTIONAL ANY MORE, and that is the fix rather
        # than an inconvenience. The editor's tree is built from the DOCUMENT it
        # is about to edit; a test that withheld the document was asserting
        # against the console's cached projection, which is exactly the stale
        # picture a technician was shown after saving.
        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        $editorHost.ShowCount | Should -Be 1
        @($editorHost.Node | ForEach-Object { $_.Text }) | Should -Be @('Preinstall', 'Install')
    }

    It 'names the task sequence in the title' {
        $editorHost = New-HDTFakeEditorHost

        # THE FILE SYSTEM IS NOT OPTIONAL ANY MORE, and that is the fix rather
        # than an inconvenience. The editor's tree is built from the DOCUMENT it
        # is about to edit; a test that withheld the document was asserting
        # against the console's cached projection, which is exactly the stale
        # picture a technician was shown after saving.
        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        $editorHost.Title | Should -Match 'DEMO-M4'
    }

    It 'tells the window which document it is editing' {
        # Both of this lab's shares hold a DEMO-M4. Two editors open at once
        # would otherwise be identical windows over different files.
        $editorHost = New-HDTFakeEditorHost

        # THE FILE SYSTEM IS NOT OPTIONAL ANY MORE, and that is the fix rather
        # than an inconvenience. The editor's tree is built from the DOCUMENT it
        # is about to edit; a test that withheld the document was asserting
        # against the console's cached projection, which is exactly the stale
        # picture a technician was shown after saving.
        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        $editorHost.Path | Should -BeExactly 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
    }

    It 'hands the window the document''s own lines, which are what an edit splices' {
        # Not the parsed document: a round trip through ConvertFrom-HDTYaml
        # returns a dictionary, and a dictionary has no comments in it.
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        $editorHost.Line | Should -Contain 'id: DEMO-M4'
        $editorHost.Line | Should -Contain '      - name: Apply OS'
    }

    It 'builds the tree from the FILE, not from the row the console cached' {
        # WATCHED IN THE CONSOLE, AND IT MADE THE WHOLE WINDOW UNTRUSTWORTHY. A
        # technician removed a step, saved, closed the editor and opened it
        # again - and the step was back. The file was right the whole time; the
        # window was not.
        #
        # THE EDITOR READ THE DOCUMENT TWICE, FROM TWO PLACES. The LINES it
        # edits came from the file, freshly. The TREE it drew came from
        # $Sequence - the row Get-HDTConsoleWorkspace built when the console
        # first opened, which knows nothing about anything saved since.
        #
        # So the rows on screen and the text under them were two different
        # documents, and every edit spliced the right file while showing the
        # wrong picture of it.
        $editorHost = New-HDTFakeEditorHost

        # The file has moved on: a share whose sequence lost a step, exactly as
        # a Save leaves it.
        $shorter = @($script:sequenceYaml -split "`r?`n" |
                Where-Object { $_ -notmatch 'Apply OS' -and $_ -notmatch 'ApplyImage' -and $_ -notmatch 'index:' }) -join "`r`n"

        $moved = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                      = $script:workspaceYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = $shorter
        }

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost -FileSystem $moved)

        $shown = @($editorHost.Node | ForEach-Object { @($_.Children) } | ForEach-Object { [string] $_.Name })

        $shown | Should -Not -Contain 'Apply OS' -Because (
            'the file no longer holds it, and the file is what the editor edits')
    }

    It 'hands the window the step catalog, so Add can offer what this engine can run' {
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        @($editorHost.Catalog).Count | Should -BeGreaterThan 1
        @($editorHost.Catalog)[0].Item[0].Text | Should -BeExactly 'New Group'
    }

    It 'passes the palette, so the editor matches the console it was opened from' {
        $editorHost = New-HDTFakeEditorHost

        # THE FILE SYSTEM IS NOT OPTIONAL ANY MORE, and that is the fix rather
        # than an inconvenience. The editor's tree is built from the DOCUMENT it
        # is about to edit; a test that withheld the document was asserting
        # against the console's cached projection, which is exactly the stale
        # picture a technician was shown after saving.
        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -FileSystem (New-HDTEditorTestFileSystem))

        $editorHost.Theme | Should -Not -BeNullOrEmpty
        $editorHost.Theme.Keys | Should -Contain 'HDTWindowBrush'
    }

    It 'reports how the window was closed' {
        $answer = Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
            -XamlPath $script:xamlPath -ConsoleHost (New-HDTFakeEditorHost -Action 'Close')

        $answer.Action | Should -BeExactly 'Close'
        $answer.Id | Should -BeExactly 'DEMO-M4'
    }

    It 'opens the editor at the size of the console that opened it' {
        # The window the administrator is looking at, not the number in the
        # markup: a console dragged wide to read a long step name opens an
        # editor just as wide.
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -OwnerWidth 1600 -OwnerHeight 1000 -Screen (New-HDTFakeScreen -Width 2560 -Height 1400))

        [int] $editorHost.Size.Width | Should -Be 1600
        [int] $editorHost.Size.Height | Should -Be 1000
    }

    It 'opens at its own size when nothing opened it' {
        # Show-HDTSequenceEditor is a command an administrator can run on its
        # own, with no console anywhere. There is no owner to copy then, and the
        # markup's own numbers are the answer.
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -Screen (New-HDTFakeScreen -Width 2560 -Height 1400))

        [int] $editorHost.Size.Width | Should -Be 1180
        [int] $editorHost.Size.Height | Should -Be 760
    }

    It 'never opens the editor larger than the desktop it has to appear on' {
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -OwnerWidth 2400 -OwnerHeight 1300 -Screen (New-HDTFakeScreen -Width 1280 -Height 770))

        [int] $editorHost.Size.Width | Should -Be 1280
        [int] $editorHost.Size.Height | Should -Be 770
    }

    It 'opens the editor at the corner of the work area, like the console' {
        # Not over the console it came from: both windows fill the work area, so
        # a centred editor would sit a few pixels off the console it covers and
        # read as a window that failed to line up.
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost `
                -OwnerWidth 1600 -OwnerHeight 1000 `
                -Screen (New-HDTFakeScreen -Width 2464 -Height 1340 -Left 96 -Top 60))

        [int] $editorHost.Size.Left | Should -Be 96
        [int] $editorHost.Size.Top | Should -Be 60
    }
}

Describe 'Resolve-HDTConsoleEditorSize' {

    # WHY THE DECISION IS NOT IN THE ADAPTER. New-HDTConsoleHost is exempt from
    # TDD only while it stays branch-free, so "how big should this window be" -
    # which has a fallback, a floor and a ceiling in it - cannot live there. The
    # host assigns two numbers this command worked out.

    It 'takes the owner''s size, which is what the administrator can see' {
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Width 2560 -Height 1400) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 1000 -Screen $Screen

            [int] $size.Width | Should -Be 1600
            [int] $size.Height | Should -Be 1000
        }
    }

    It 'answers with the editor''s own first-run size when there is no owner' {
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Width 2560 -Height 1400) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 0 -OwnerHeight 0 -Screen $Screen

            [int] $size.Width | Should -Be 1180
            [int] $size.Height | Should -Be 760
        }
    }

    It 'falls back one dimension at a time' {
        # A window can report a width and not a height while it is still being
        # laid out, and half an answer must not throw away the other half.
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Width 2560 -Height 1400) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 0 -Screen $Screen

            [int] $size.Width | Should -Be 1600
            [int] $size.Height | Should -Be 760
        }
    }

    It 'lowers a size the desktop cannot show, which is the console''s own rule' {
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Width 1280 -Height 770) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 2400 -OwnerHeight 1300 -Screen $Screen

            [int] $size.Width | Should -Be 1280
            [int] $size.Height | Should -Be 770
        }
    }

    It 'never answers below the minimum the editor markup declares' {
        # WPF enforces MinWidth and MinHeight whatever it is told, so a smaller
        # number would be one that lies about the window it produces.
        InModuleScope Hephaestus {
            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 300 -OwnerHeight 200 -Screen $null

            [int] $size.Width | Should -Be 820
            [int] $size.Height | Should -Be 480
        }
    }

    It 'leaves the size alone when the desktop cannot be measured' {
        # A display query throws in a session with no desktop. That may never be
        # the reason a window fails to open.
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Throw) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 1000 -Screen $Screen

            [int] $size.Width | Should -Be 1600
            [int] $size.Height | Should -Be 1000
        }
    }

    It 'answers the work area origin, so the editor opens where the console does' {
        InModuleScope Hephaestus -Parameters @{ Screen = (New-HDTFakeScreen -Width 2464 -Height 1340 -Left 96 -Top 60) } {
            param($Screen)

            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 1000 -Screen $Screen

            [int] $size.Left | Should -Be 96
            [int] $size.Top | Should -Be 60
        }
    }

    It 'answers the corner when there is no screen to measure' {
        InModuleScope Hephaestus {
            $size = Resolve-HDTConsoleEditorSize -OwnerWidth 1600 -OwnerHeight 1000 -Screen $null

            [int] $size.Left | Should -Be 0
            [int] $size.Top | Should -Be 0
        }
    }
}

Describe 'every brush the markup names' {

    # AN UNDEFINED DynamicResource DOES NOT FAIL. WPF silently paints the
    # control's default instead, so a window whose theme is missing a key looks
    # almost right - which is how the editor's hint text came out the same
    # weight as the labels above it, and an error message came out black.
    #
    # THE MARKUP IS THE LIST. Reading the keys out of the XAML rather than
    # naming them here means a brush added to a window tomorrow is checked
    # tomorrow, without anybody remembering to.

    It 'is defined in the <Name> theme' -ForEach @(
        @{ Name = 'Light' }
    ) {
        $theme = Get-HDTConsoleTheme

        $named = @([regex]::Matches($script:markup, 'DynamicResource\s+(HDT\w+)') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        @($named).Count | Should -BeGreaterThan 5

        foreach ($key in $named) {
            $theme.Contains($key) | Should -BeTrue -Because ("the editor's markup paints with {0}" -f $key)
        }
    }
}


}
