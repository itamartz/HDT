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
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\ws'
    $script:xamlPath = 'C:\ws\UI\HDTConsole.xaml'

    # The shipped window, read off disk rather than retyped, so the file the
    # console really loads and the file these tests exercise cannot drift.
    $script:shippedXamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTConsole.xaml'

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
            Action     = $Action
            ShowCount  = 0
            Xaml       = ''
            Title      = ''
            Node       = @()
            Theme      = $null
            OpenedSize = $null

            # What the real host reports back after the window closes.
            Width      = 1640
            Height     = 880

            # WHAT THE WINDOW OPENED WITH, before the share was read, and how
            # many times it was asked to read one.
            PendingNode = @()
            FillCount   = 0
            Handed      = [ordered] @{}
        }

        $fake | Add-Member -MemberType ScriptMethod -Name Show -Value {
            param([string] $Xaml, [string] $Title, [object[]] $Node, [object] $Theme, [object] $Size,
                [string] $ThemeName, [int] $RefreshSecond, [string] $NewSequenceXaml,
                [string] $ImportOperatingSystemXaml, [string] $ImportApplicationXaml,
                [string] $ApplicationDependencyXaml, [string] $ApplicationDetectionXaml,
                [object] $Fill = $null)

            $this.ShowCount = $this.ShowCount + 1
            $this.Xaml = $Xaml
            $this.Title = $Title
            $this.Node = $Node
            $this.Theme = $Theme
            $this.OpenedSize = $Size

            # RECORDED, NOT IGNORED - the same rule the wizard's fake states: a
            # fake that accepts a parameter and drops it is a
            # PSReviewUnusedParameter warning that breaks lint, and a
            # SuppressMessageAttribute inside a SCRIPT BLOCK param block is
            # ignored outright. Keeping them is also the more useful double,
            # since which markup each dialog was handed is then assertable.
            $this.Handed = [ordered] @{
                ThemeName                 = $ThemeName
                RefreshSecond             = $RefreshSecond
                NewSequenceXaml           = $NewSequenceXaml
                ImportOperatingSystemXaml = $ImportOperatingSystemXaml
                ImportApplicationXaml     = $ImportApplicationXaml
                ApplicationDependencyXaml = $ApplicationDependencyXaml
                ApplicationDetectionXaml  = $ApplicationDetectionXaml
            }

            # THE REAL HOST READS THE SHARE ONCE ITS WINDOW IS UP, and so does
            # this: the window opens holding a row that says it is reading, and
            # what it shows afterwards is whatever the block returns. A fake
            # that ignored the block would be a fake that never sees a share -
            # which is exactly how this contract announced itself, as six tests
            # asserting rows against a tree nobody had filled.
            #
            # The unfilled rows are kept too, because "what the window opened
            # with" is a thing to be able to assert.
            $this.PendingNode = $Node

            if ($null -ne $Fill) {
                $this.Node = @(& $Fill)
                $this.FillCount = $this.FillCount + 1
            }

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

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Show-HDTConsole' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
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

        It 'passes the tree ROOTS, because WPF builds the branches from Children' {
            $expected = @(Get-HDTConsoleTreeNode -Workspace $script:answer.Workspace)

            @($script:consoleHost.Node).Count | Should -Be 1
            @($script:consoleHost.Node)[0].Kind | Should -BeExactly 'Root'
            @($script:consoleHost.Node)[0].Text |
                Should -BeExactly @($expected | Where-Object { $_.Depth -eq 0 })[0].Text
        }

        It 'passes roots whose Children reach every row the tree decided on' {
            # The adapter is handed one row; the window must still be able to
            # show all of them. Walking Children here is what proves the tree
            # is actually linked rather than merely ordered.
            $reached = New-Object -TypeName System.Collections.ArrayList
            $pending = New-Object -TypeName System.Collections.Queue

            foreach ($row in @($script:consoleHost.Node)) { $pending.Enqueue($row) }

            while ($pending.Count -gt 0) {
                $row = $pending.Dequeue()
                [void] $reached.Add($row.Text)
                foreach ($child in @($row.Children)) { $pending.Enqueue($child) }
            }

            $expected = @(Get-HDTConsoleTreeNode -Workspace $script:answer.Workspace)

            @($reached).Count | Should -Be $expected.Count
        }

        It 'passes rows carrying both the path it opened and the deployRoot the share declares' {
            $share = @(@($script:consoleHost.Node)[0].Children)[0]

            $share.HeaderRoot | Should -BeExactly 'C:\ws'
            $share.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            $share.HeaderTitle | Should -Match 'HDT deployment share'
        }
    }

    Context 'the palette' {

        BeforeAll {
            function Get-HDTContrastRatio {
                <#
                    .SYNOPSIS
                        The WCAG contrast ratio between two #AARRGGBB colours.
                    .DESCRIPTION
                        Written here rather than eyeballed, because "white on a
                        light blue wash" looks fine in a palette listing and
                        disappears on a screen. 4.5:1 is WCAG AA for body text.
                #>
                [CmdletBinding()]
                [OutputType([double])]
                param(
                    [Parameter(Mandatory = $true, Position = 0)] [string] $First,
                    [Parameter(Mandatory = $true, Position = 1)] [string] $Second
                )

                function Get-HDTRelativeLuminance {
                    [CmdletBinding()]
                    [OutputType([double])]
                    param([Parameter(Mandatory = $true)] [string] $Colour)

                    $hex = $Colour.TrimStart('#')
                    if ($hex.Length -eq 8) { $hex = $hex.Substring(2) }

                    $channel = foreach ($offset in 0, 2, 4) {
                        $value = [Convert]::ToInt32($hex.Substring($offset, 2), 16) / 255.0
                        if ($value -le 0.03928) {
                            $value / 12.92
                        } else {
                            [Math]::Pow((($value + 0.055) / 1.055), 2.4)
                        }
                    }

                    return (0.2126 * $channel[0]) + (0.7152 * $channel[1]) + (0.0722 * $channel[2])
                }

                $one = Get-HDTRelativeLuminance -Colour $First
                $two = Get-HDTRelativeLuminance -Colour $Second

                $lighter = [Math]::Max($one, $two)
                $darker = [Math]::Min($one, $two)

                return (($lighter + 0.05) / ($darker + 0.05))
            }
        }

        It 'keeps <_> readable when the pointer is over the button' -ForEach @('Light', 'Dark') {
            # THE BUG THIS EXISTS FOR: the light theme's hover is a pale wash,
            # and white-on-pale is a button that empties as the pointer reaches
            # it. Measured rather than trusted, in both palettes, because the
            # right answer differs between them.
            $palette = Get-HDTConsoleTheme -Name $PSItem

            $ratio = Get-HDTContrastRatio $palette['HDTButtonHoverBrush'] $palette['HDTButtonHoverTextBrush']

            $ratio | Should -BeGreaterThan 4.5 -Because "$PSItem hover text on hover background"
        }

        It 'keeps the <_> button readable at rest too' -ForEach @('Light', 'Dark') {
            $palette = Get-HDTConsoleTheme -Name $PSItem

            $ratio = Get-HDTContrastRatio $palette['HDTButtonBrush'] $palette['HDTButtonTextBrush']

            $ratio | Should -BeGreaterThan 4.5 -Because "$PSItem button text on button background"
        }

        It 'keeps the <_> detail pane readable' -ForEach @('Light', 'Dark') {
            $palette = Get-HDTConsoleTheme -Name $PSItem

            $ratio = Get-HDTContrastRatio $palette['HDTFieldBrush'] $palette['HDTPanelTextBrush']

            $ratio | Should -BeGreaterThan 4.5 -Because "$PSItem field text on field background"
        }

        It 'does not say "this went wrong" and "this is what ran" in the same <_> colour' -ForEach @('Light', 'Dark') {
            # THEY WERE THE SAME RED IN LIGHT - #FFA31515 for both - and the two
            # lines sit one above the other on every dialog that has them: the
            # refusal and the command it would have run. A technician cannot
            # tell a complaint from a preview when they are the same colour, and
            # the ones that matter get read as decoration.
            #
            # The console itself has no error line, which is why red reads
            # correctly there and this went unnoticed.
            $palette = Get-HDTConsoleTheme -Name $PSItem

            $palette['HDTCommandTextBrush'] | Should -Not -BeExactly $palette['HDTErrorBrush'] `
                -Because "$PSItem must not paint a refusal and a command preview alike"
        }

        It 'keeps the <_> command preview readable where it is shown' -ForEach @('Light', 'Dark') {
            $palette = Get-HDTConsoleTheme -Name $PSItem

            $ratio = Get-HDTContrastRatio $palette['HDTWindowBrush'] $palette['HDTCommandTextBrush']

            $ratio | Should -BeGreaterThan 4.5 -Because "$PSItem command text on the window"
        }


        It 'opens light, because the console is a desktop application and not a bench tool' {
            $consoleHost = New-HDTFakeConsoleHost

            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem))

            $consoleHost.Theme['HDTPanelBrush'] |
                Should -BeExactly (Get-HDTConsoleTheme -Name Light)['HDTPanelBrush']
        }

        It 'hands the dark palette over when it is asked for' {
            $consoleHost = New-HDTFakeConsoleHost

            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath -Theme Dark `
                    -ConsoleHost $consoleHost -FileSystem (New-HDTConsoleWindowTestFileSystem))

            $consoleHost.Theme['HDTPanelBrush'] |
                Should -BeExactly (Get-HDTConsoleTheme -Name Dark)['HDTPanelBrush']
        }
    }

    Context 'the size it was left at' {

        BeforeAll {
            $script:appData = 'C:\Users\tech\AppData\Roaming'
            $script:settingPath = 'C:\Users\tech\AppData\Roaming\HDT\console.json'
        }

        It 'opens at the remembered size' {
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
                $script:xamlPath       = '<Window />'
                $script:settingPath    = '{ "width": 1440, "height": 820 }'
            }
            $consoleHost = New-HDTFakeConsoleHost

            # A DESKTOP BIG ENOUGH TO BE OUT OF THE WAY. Without it this reads the
            # real monitor and asserts a remembered size that a small screen would
            # legitimately have clamped - passing at one desk and failing at another.
            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost $consoleHost -FileSystem $fs `
                    -Environment (New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = $script:appData }) `
                    -Screen (New-HDTFakeScreen -Width 3840 -Height 2160))

            $consoleHost.OpenedSize.Width | Should -Be 1440
            $consoleHost.OpenedSize.Height | Should -Be 820
        }

        It 'opens at the corner of the usable desktop, under no taskbar' {
            # The position is not remembered and is not in the preference file:
            # every console opens at the work area's origin. What varies between
            # machines is where that origin is, and this states one.
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
                $script:xamlPath       = '<Window />'
            }
            $consoleHost = New-HDTFakeConsoleHost

            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost $consoleHost -FileSystem $fs `
                    -Environment (New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = $script:appData }) `
                    -Screen (New-HDTFakeScreen -Width 3744 -Height 2100 -Left 96 -Top 60))

            $consoleHost.OpenedSize.Left | Should -Be 96
            $consoleHost.OpenedSize.Top | Should -Be 60
        }

        It 'remembers the size the window was closed at' {
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
                $script:xamlPath       = '<Window />'
            }
            $consoleHost = New-HDTFakeConsoleHost
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = $script:appData }

            $roomy = New-HDTFakeScreen -Width 3840 -Height 2160

            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost $consoleHost -FileSystem $fs -Environment $environment `
                    -Screen $roomy)

            $saved = Get-HDTConsoleSetting -FileSystem $fs -Environment $environment -Screen $roomy

            $saved.Width | Should -Be 1640
            $saved.Height | Should -Be 880
        }

        It 'writes that nowhere near the deployment share' {
            # C1 reads a live share and writes nothing to it. A window size is a
            # preference of one administrator on one workstation anyway.
            $fs = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
                $script:xamlPath       = '<Window />'
            }

            [void] (Show-HDTConsole -Path $script:root -XamlPath $script:xamlPath `
                    -ConsoleHost (New-HDTFakeConsoleHost) -FileSystem $fs `
                    -Environment (New-HDTFakeEnvironmentProvider -Variable @{ APPDATA = $script:appData }))

            foreach ($write in @($fs.Operations | Where-Object { $_.Operation -in 'WriteAllText', 'AppendAllText', 'RemoveItem', 'CopyItem' })) {
                $write.Arguments[0] | Should -Not -Match ([regex]::Escape('C:\ws'))
            }
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
            @(@($consoleHost.Node)[0].Children).Count | Should -Be 2
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

            $shown = @(@($consoleHost.Node)[0].Children)

            $failed = @($shown | Where-Object { $_.Status -eq 'Error' })[0]
            $failed.Text | Should -Match ([regex]::Escape('C:\gone'))
            $failed.Detail | Should -Match 'workspace.yaml'

            @($shown | Where-Object { $_.Status -eq 'Ok' }).Count | Should -Be 1
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

    It 'takes the position it is given rather than centring itself' {
        # The console opens at the origin of the work area, filling it. WPF
        # honours an assigned Left and Top only under Manual: under CenterScreen
        # it recentres on the primary monitor after the assignment, so the two
        # numbers Resolve-HDTConsoleWindowPosition worked out would be computed,
        # assigned and then thrown away - and on a desktop whose work area
        # already starts at 0,0 the difference would be invisible until somebody
        # docked their taskbar at the top.
        $script:shippedXaml | Should -Match 'WindowStartupLocation="Manual"'
    }

    It 'names <_>, which New-HDTConsoleHost finds by name' -ForEach @(
        'HDTConsoleTree', 'HDTDetailList', 'HDTCommandText',
        'HDTShareText', 'HDTDeployRootText', 'HDTRootText', 'HDTCloseButton') {

        $script:shippedXaml | Should -Match ('x:Name="{0}"' -f $PSItem)
    }

    It 'shows the detail as labelled boxes rather than one block of text' {
        # A properties sheet: each value selectable and copyable on its own, and
        # already the shape an editor needs when C2 makes them writable.
        $script:shippedXaml | Should -Match '\{Binding Label'
        $script:shippedXaml | Should -Match '\{Binding Value'
        $script:shippedXaml | Should -Match 'ItemsControl x:Name="HDTDetailList"'
    }

    It 'lets the row decide which of those boxes can be typed into' {
        # THE ROW KNOWS, NOT THE WINDOW. New-HDTConsoleField sets ReadOnly from
        # whether the row names a key in the document, so the name and the
        # description of a task sequence are typeable and a step count is not -
        # without the markup keeping a list of labels it would then have to be
        # kept in step with.
        $document = [xml] $script:shippedXaml

        $box = @($document.SelectNodes("//*[local-name()='TextBox']"))

        @($box).Count | Should -BeGreaterThan 0
        foreach ($current in $box) {
            $current.GetAttribute('IsReadOnly') | Should -BeIn @('True', '{Binding ReadOnly}')
        }

        $script:shippedXaml | Should -Match 'IsReadOnly="\{Binding ReadOnly\}"'
    }

    It 'paints a box that can be typed into white and washes out the ones that cannot' {
        # WHICH BOXES TAKE TYPING IS OTHERWISE INVISIBLE: seven identical boxes,
        # two of which quietly accept a rename. The editor already answers this
        # the same way - white by default, the read-only wash through a trigger -
        # and TargetName inside a DataTemplate is what lets a trigger beat the
        # local value, which a Style trigger would not.
        $document = [xml] $script:shippedXaml

        $box = @($document.SelectNodes("//*[local-name()='TextBox']") |
                Where-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') -eq 'HDTDetailBox' })

        @($box).Count | Should -Be 1
        $box[0].GetAttribute('Background') | Should -BeExactly '{DynamicResource HDTPanelBrush}'

        $script:shippedXaml | Should -Match '(?s)<DataTrigger Binding="\{Binding ReadOnly\}" Value="True">.*?TargetName="HDTDetailBox".*?HDTFieldBrush'
    }

    It 'sets no local Foreground on a button, which would beat the hover trigger' {
        # The trap the wizard workstream hit: a local value wins over a style
        # trigger in WPF, so the hover rule compiles, runs, and does nothing.
        $document = [xml] $script:shippedXaml

        foreach ($button in @($document.SelectNodes("//*[local-name()='Button']"))) {
            $button.GetAttribute('Foreground') | Should -BeNullOrEmpty
            $button.GetAttribute('Background') | Should -BeNullOrEmpty
        }
    }

    It 'puts a draggable splitter between the tree and the detail pane' {
        # The detail pane holds descriptions and 64-character hashes, and how
        # much room each side needs is the reader's business rather than a
        # number chosen here.
        $document = [xml] $script:shippedXaml

        $splitter = @($document.SelectNodes("//*[local-name()='GridSplitter']"))

        @($splitter).Count | Should -Be 1
        $splitter[0].GetAttribute('Column', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation') |
            Should -BeNullOrEmpty -Because 'the attached property is written Grid.Column'
        $script:shippedXaml | Should -Match 'GridSplitter[\s\S]*Grid\.Column="1"'
    }

    It 'lets the splitter give width to either side' {
        # A fixed left column and a star right column would let the splitter
        # grow the tree and never the pane, which is the direction nobody needs.
        $document = [xml] $script:shippedXaml

        $width = @($document.SelectNodes("//*[local-name()='ColumnDefinition']") |
                ForEach-Object { $_.GetAttribute('Width') } |
                Where-Object { $_ -match '\*' })

        @($width).Count | Should -BeGreaterOrEqual 2
    }

    It 'never scrolls the tree sideways, which would take the icons off the edge' {
        $script:shippedXaml | Should -Match 'ScrollViewer\.HorizontalScrollBarVisibility="Disabled"'
    }

    It 'declares a default for every key Get-HDTConsoleTheme sets, and sets none it does not' {
        # A key the markup names and the theme omits keeps a stale colour from
        # the other palette; a key the theme sets and the markup never names is
        # a colour nobody can see. Either way it only shows up in the theme
        # nobody had open.
        $document = [xml] $script:shippedXaml

        $declared = @($document.SelectNodes("//*[local-name()='SolidColorBrush']") |
                ForEach-Object { $_.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml') })

        foreach ($name in @('Light', 'Dark')) {
            $key = @((Get-HDTConsoleTheme -Name $name).Keys)

            @($key).Count | Should -BeGreaterThan 0
            @($key | Sort-Object) | Should -Be @($declared | Sort-Object) -Because "the $name palette"
        }
    }

    It 'paints every colour through a DynamicResource, so a palette swap repaints it' {
        # A literal colour left in the markup is one that stays put when the
        # theme changes - the single hardest thing to notice by looking, because
        # it only looks wrong in the palette you did not open.
        $literal = [regex]::Matches($script:shippedXaml, '(?<!Color=)"#[0-9A-Fa-f]{8}"')

        @($literal).Count | Should -Be 0 -Because (
            'only the SolidColorBrush defaults may name a colour: ' + (@($literal | ForEach-Object { $_.Value }) -join ', '))
    }

    It 'builds its nesting from the Children member, so the host builds none of it' {
        $script:shippedXaml | Should -Match 'HierarchicalDataTemplate ItemsSource="\{Binding Children\}"'
    }

    It 'opens tall enough for the boot image pane, which is the longest one' {
        # Measured, not guessed: seventeen fields, two of them 64-character
        # hashes, want 866 units of window. Anything less hides a hash behind a
        # scrollbar nobody notices.
        $document = [xml] $script:shippedXaml

        [double] $document.DocumentElement.GetAttribute('Height') | Should -BeGreaterOrEqual 866
    }

    It 'declares the same first-run size the module defaults to' {
        # Two files hold these numbers - the markup, for a window loaded on its
        # own, and the module, for the reader and writer of the remembered size.
        # They must not drift, and drift is invisible: the console would open at
        # one size on a fresh profile and another the moment anything is saved.
        $document = [xml] $script:shippedXaml
        $module = Get-Module -Name 'Hephaestus'

        [double] $document.DocumentElement.GetAttribute('Width') |
            Should -Be (& $module { $script:HDTConsoleDefaultWidth })
        [double] $document.DocumentElement.GetAttribute('Height') |
            Should -Be (& $module { $script:HDTConsoleDefaultHeight })
        [double] $document.DocumentElement.GetAttribute('MinWidth') |
            Should -Be (& $module { $script:HDTConsoleMinimumWidth })
        [double] $document.DocumentElement.GetAttribute('MinHeight') |
            Should -Be (& $module { $script:HDTConsoleMinimumHeight })
    }

    It 'gives each tree row an accessible name, so it is not announced as an object dump' {
        # A TreeViewItem with no AutomationProperties.Name falls back to the
        # bound item's ToString(), and a PSCustomObject's ToString() is every
        # property it has - including the whole Detail text. Nothing on screen
        # looks wrong; a screen reader reads the blob.
        $script:shippedXaml | Should -Match 'AutomationProperties\.Name" Value="\{Binding Text\}"'
    }

    It 'binds <_> off the row rather than reading it from anywhere else' -ForEach @(
        'Icon', 'Text', 'IsExpanded') {

        # Concatenated, not -f: the pattern contains a literal brace and the
        # format operator would try to read it as a placeholder.
        $script:shippedXaml | Should -Match ('\{Binding ' + $PSItem)
    }
}
