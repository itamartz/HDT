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

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
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
        @{ Name = 'HDTEditorCloseButton' }

        # The Add menu, and the Options tab.
        @{ Name = 'HDTAddMenu' }
        @{ Name = 'HDTOptionTab' }
        @{ Name = 'HDTDisableCheck' }
        @{ Name = 'HDTContinueCheck' }
        @{ Name = 'HDTConditionText' }
        @{ Name = 'HDTConditionApplyButton' }
        @{ Name = 'HDTConditionClearButton' }
        @{ Name = 'HDTRunInText' }

        # The Properties tab, which now writes.
        @{ Name = 'HDTPropertyApplyButton' }
        @{ Name = 'HDTPropertyRevertButton' }
    ) {
        $script:markup | Should -Match ('x:Name="{0}"' -f $Name)
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
        $script:markup | Should -Match 'Header="Properties"'
        $script:markup | Should -Match 'Header="Options"'
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

    It 'still centres on the window that opened it' {
        # The editor is opened from a row in the browser, so the console is
        # where the administrator is looking. CenterScreen would put it over
        # whichever monitor Windows calls the primary one.
        $script:markup | Should -Match 'WindowStartupLocation="CenterOwner"'
    }
}

Describe 'Show-HDTSequenceEditor' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Show-HDTSequenceEditor' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'hands the host the editor rows, not the whole document' {
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost)

        $editorHost.ShowCount | Should -Be 1
        @($editorHost.Node | ForEach-Object { $_.Text }) | Should -Be @('Preinstall', 'Install')
    }

    It 'names the task sequence in the title' {
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost)

        $editorHost.Title | Should -Match 'DEMO-M4'
    }

    It 'tells the window which document it is editing' {
        # Both of this lab's shares hold a DEMO-M4. Two editors open at once
        # would otherwise be identical windows over different files.
        $editorHost = New-HDTFakeEditorHost

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost)

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

        [void] (Show-HDTSequenceEditor -Sequence (New-HDTEditorTestSequence) `
                -XamlPath $script:xamlPath -ConsoleHost $editorHost -Theme 'Dark')

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
}
