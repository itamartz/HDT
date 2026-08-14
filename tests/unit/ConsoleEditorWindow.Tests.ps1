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
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:xamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/UI/HDTSequenceEditor.xaml'

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
            Theme     = $null
        }

        $fake | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
            param([string] $Xaml, [string] $Title, [string] $Path, [object[]] $Node, [object] $Theme)

            $this.ShowCount = $this.ShowCount + 1
            $this.Xaml = $Xaml
            $this.Title = $Title
            $this.Path = $Path
            $this.Node = $Node
            $this.Theme = $Theme

            return [string] $this.Action
        }

        return $fake
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
    ) {
        $script:markup | Should -Match ('x:Name="{0}"' -f $Name)
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
}

Describe 'Show-HDTSequenceEditor' {

    It 'is exported by HDT.Console' {
        Get-Command -Name 'Show-HDTSequenceEditor' -Module 'HDT.Console' -ErrorAction SilentlyContinue |
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
}
