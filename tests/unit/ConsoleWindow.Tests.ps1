# C1's window, asserted on a machine with no display.
#
# THE WINDOW IS NOT UNIT TESTED AND MUST NOT BE. Show-HDTConsole holds the
# decisions; an injected IConsoleHost holds the WPF. That is the same split
# Show-HDTWizard uses (.planning/WPF-FIRST.md, DESIGN 12.2.1), and it is why
# New-HDTConsoleHost may be branch-free and untested while everything that
# reaches the screen is asserted here.
#
# WHY THE CONSOLE NORMALISES A DISMISSED WINDOW TO 'Close' AND THE WIZARD
# NORMALISES IT TO 'Cancel'. The wizard's Next leads to a task sequence that
# partitions a disk, so silence there must never read as approval. C1 of the
# console reads the share and writes nothing at all, so there is no approval to
# withhold: an empty answer is a window that was shut. The asymmetry is
# deliberate, and it is written down here so nobody later "fixes" one to match
# the other.
#
# WHAT IS ASSERTED ABOUT THE XAML IS WHAT CAN BE WRONG WITHOUT LOOKING AT IT:
# it is there, it parses, it carries the control names the host will FindName,
# and it carries no x:Class - a code-behind attribute would bind the file to a
# compiler, and XamlReader::Load is a markup parser with no compiler behind it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\ws'
    $script:xamlPath = 'C:\ws\UI\HDTConsole.xaml'

    # The shipped window, read off disk rather than retyped, so the file the
    # console really loads and the file these tests exercise cannot drift.
    $script:shippedXamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src\HDT.Console\UI\HDTConsole.xaml'

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
bootImage:
  name: HDTPE_x64
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
steps:
  - name: Validate
    type: Validate
'@

    function New-HDTFakeConsoleHost {
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
            Node      = @()
        }

        $fake | Add-Member -MemberType ScriptMethod -Name Show -Value {
            param([string] $Xaml, [string] $Title, [object[]] $Node)

            $this.ShowCount = $this.ShowCount + 1
            $this.Xaml = $Xaml
            $this.Title = $Title
            $this.Node = $Node

            return [string] $this.Action
        }

        return $fake
    }

    function New-HDTConsoleWindowTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Xaml = '<Window />',

            [Parameter()]
            [string] $XamlPath = $script:xamlPath,

            [Parameter()]
            [switch] $Missing
        )

        $file = @{
            'C:\ws\workspace.yaml'                      = $script:workspaceYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = $script:sequenceYaml
        }

        if (-not $Missing) { $file[$XamlPath] = $Xaml }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Show-HDTConsole' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by HDT.Console' {
            Get-Command -Name 'Show-HDTConsole' -Module 'HDT.Console' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected console host, so it can run with no display' {
            (Get-Command -Name 'Show-HDTConsole').Parameters.ContainsKey('ConsoleHost') | Should -BeTrue
        }

        It 'takes an injected file system, so it can run with no share' {
            (Get-Command -Name 'Show-HDTConsole').Parameters.ContainsKey('FileSystem') | Should -BeTrue
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Show-HDTConsole').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the window file, checked before anything is shown' {

        It 'refuses a window that is not there, by name' {
            $fs = New-HDTConsoleWindowTestFileSystem -Missing
            $consoleHost = New-HDTFakeConsoleHost

            { Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath -ConsoleHost $consoleHost -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*HDTConsole.xaml*'

            $consoleHost.ShowCount | Should -Be 0
        }

        It 'refuses an empty window file, which [xml] would otherwise accept' {
            # [xml] '' yields an empty document rather than throwing, so a
            # zero-byte file - the shape a bad copy produces - would reach
            # XamlReader and fail there instead, with an error about a missing
            # root element that reads like a XAML mistake.
            $fs = New-HDTConsoleWindowTestFileSystem -Xaml ''
            $consoleHost = New-HDTFakeConsoleHost

            { Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath -ConsoleHost $consoleHost -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*HDTConsole.xaml*'

            $consoleHost.ShowCount | Should -Be 0
        }

        It 'refuses a window that is not well-formed XML, by name' {
            $fs = New-HDTConsoleWindowTestFileSystem -Xaml '<Window><Grid></Window>'
            $consoleHost = New-HDTFakeConsoleHost

            { Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath -ConsoleHost $consoleHost -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*HDTConsole.xaml*'

            $consoleHost.ShowCount | Should -Be 0
        }

        It 'defaults to the window that ships beside the module' {
            $shipped = [System.IO.File]::ReadAllText($script:shippedXamlPath)
            $fs = New-HDTConsoleWindowTestFileSystem -Xaml $shipped -XamlPath $script:shippedXamlPath
            $consoleHost = New-HDTFakeConsoleHost

            $answer = Show-HDTConsole -Path $script:root -ConsoleHost $consoleHost -FileSystem $fs

            $answer.XamlPath | Should -BeExactly $script:shippedXamlPath
            $consoleHost.Xaml | Should -BeExactly $shipped
        }
    }

    Context 'what reaches the host' {

        BeforeAll {
            $script:consoleHost = New-HDTFakeConsoleHost
            $script:answer = Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                -Title 'HDT Console' -ConsoleHost $script:consoleHost `
                -FileSystem (New-HDTConsoleWindowTestFileSystem)
        }

        It 'shows the window exactly once' {
            $script:consoleHost.ShowCount | Should -Be 1
        }

        It 'passes the title through' {
            $script:consoleHost.Title | Should -BeExactly 'HDT Console'
        }

        It 'passes the same rows Get-HDTConsoleTreeNode decided on' {
            $expected = @(Get-HDTConsoleTreeNode -Workspace $script:answer.Workspace)

            @($script:consoleHost.Node).Count | Should -Be $expected.Count
            @($script:consoleHost.Node | ForEach-Object { $_.Display }) |
                Should -Be @($expected | ForEach-Object { $_.Display })
        }

        It 'passes rows carrying both the path it opened and the deployRoot the share declares' {
            $share = @($script:consoleHost.Node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.HeaderRoot | Should -BeExactly 'C:\ws'
            $share.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            $share.HeaderTitle | Should -Match 'HDT deployment share'
        }
    }

    Context 'the apartment WPF needs' {

        It 'refuses to show a window on an MTA thread, naming the switch that fixes it' {
            # A WPF window created on an MTA thread fails in the worst way a UI
            # can - no window, and nothing said. Windows PowerShell 5.1 and
            # pwsh 7.5 both start STA, so this is not the common path; 'pwsh
            # -MTA' and any host that runs on an MTA thread are, and there the
            # difference between a sentence and silence is the whole difference.
            $consoleHost = New-HDTFakeConsoleHost

            { Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem) `
                    -ApartmentState ([System.Threading.ApartmentState]::MTA) } |
                Should -Throw -ExpectedMessage '*-STA*'

            $consoleHost.ShowCount | Should -Be 0
        }

        It 'shows the window on an STA thread' {
            $consoleHost = New-HDTFakeConsoleHost

            $answer = Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem) `
                -ApartmentState ([System.Threading.ApartmentState]::STA)

            $answer.Action | Should -BeExactly 'Close'
            $consoleHost.ShowCount | Should -Be 1
        }
    }

    Context 'more than one deployment share' {

        It 'opens them all in one window' {
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'   = $script:workspaceYaml
                'C:\prod\workspace.yaml' = $script:workspaceYaml.Replace('HDT-LAB-SMB', 'HDT-PROD')
                $script:xamlPath         = '<Window />'
            }
            $consoleHost = New-HDTFakeConsoleHost

            $answer = Show-HDTConsole -Path 'C:\ws', 'C:\prod' -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem $fs

            @($answer.Workspace).Count | Should -Be 2
            @($consoleHost.Node | Where-Object { $_.Kind -eq 'Share' }).Count | Should -Be 2
        }

        It 'shows a share that would not open as a row, and still shows the others' {
            # Three good shares must not vanish because of a fourth. The
            # per-share command still throws when it is called on its own - that
            # is right for a command - but a window is not a command.
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
                $script:xamlPath       = '<Window />'
            }
            $consoleHost = New-HDTFakeConsoleHost

            $answer = Show-HDTConsole -Path 'C:\ws', 'C:\gone' -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem $fs

            @($answer.Workspace).Count | Should -Be 2
            @($answer.Workspace | Where-Object { $_.Status -eq 'Error' })[0].Root | Should -BeExactly 'C:\gone'

            $failed = @($consoleHost.Node | Where-Object { $_.Status -eq 'Error' -and $_.Kind -eq 'Share' })[0]
            $failed.Text | Should -Match ([regex]::Escape('C:\gone'))
            $failed.Detail | Should -Match 'workspace.yaml'

            @($consoleHost.Node | Where-Object { $_.Kind -eq 'Share' -and $_.Status -eq 'Ok' }).Count | Should -Be 1
        }
    }

    Context 'what comes back' {

        It 'returns what the host answered, with the workspace it showed' {
            $consoleHost = New-HDTFakeConsoleHost -Action 'Close'

            $answer = Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem)

            $answer.Action | Should -BeExactly 'Close'
            $answer.XamlPath | Should -BeExactly $script:xamlPath
            @($answer.Workspace)[0].Id | Should -BeExactly 'HDT-LAB-SMB'
            $answer.NodeCount | Should -BeGreaterThan 0
        }

        It 'reads a dismissed window as a close, because C1 writes nothing there is anything to approve' {
            $consoleHost = New-HDTFakeConsoleHost -Action ''

            $answer = Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem)

            $answer.Action | Should -BeExactly 'Close'
        }

        It 'shows a workspace it was handed rather than re-reading the share' {
            $fs = New-HDTConsoleWindowTestFileSystem
            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs
            $consoleHost = New-HDTFakeConsoleHost

            $answer = Show-HDTConsole -Workspace $model -XamlPath $script:xamlPath `
                -ConsoleHost $consoleHost -FileSystem $fs

            @($answer.Workspace)[0].Id | Should -BeExactly 'HDT-LAB-SMB'
            $consoleHost.ShowCount | Should -Be 1
        }
    }
}

Describe 'the shipped console window' {

    BeforeAll {
        $script:shippedXaml = [System.IO.File]::ReadAllText($script:shippedXamlPath)
    }

    It 'is there' {
        Test-Path -LiteralPath $script:shippedXamlPath -PathType Leaf | Should -BeTrue
    }

    It 'is well-formed XML' {
        { [void] ([xml] $script:shippedXaml) } | Should -Not -Throw
    }

    It 'carries no x:Class, because XamlReader parses markup and there is no compiler behind it' {
        # Asserted against the PARSED document, not the text: the file's header
        # explains why there is no x:Class, and a raw text scan would fail on the
        # explanation. Comments may discuss the rule; markup may not break it -
        # the same split tests/contract/ProtectedPath.Contract.Tests.ps1 makes.
        $document = [xml] $script:shippedXaml

        @($document.DocumentElement.Attributes | ForEach-Object { $_.Name }) |
            Should -Not -Contain 'x:Class'
    }

    It 'names <_>, which New-HDTConsoleHost finds by name' -ForEach @(
        'HDTConsoleList', 'HDTDetailText', 'HDTCommandText',
        'HDTShareText', 'HDTDeployRootText', 'HDTRootText', 'HDTCloseButton') {

        $script:shippedXaml | Should -Match ('x:Name="{0}"' -f $PSItem)
    }

    It 'binds the list to the Display member the node command produces' {
        $script:shippedXaml | Should -Match 'DisplayMemberPath="Display"'
    }
}
