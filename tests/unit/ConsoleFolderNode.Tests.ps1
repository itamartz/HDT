# THE FOLDERS THE CONSOLE DRAWS, worked out without a window.
#
# Deployment Workbench nests task sequences, operating systems and applications
# into folders, and a share with thirty of anything is unreadable without it.
# HDT's folders are labels on the documents rather than real directories - see
# Import-HDTSequenceDocument's note - so the TREE is the only place they exist,
# and this is the function that builds them.
#
# ONE FUNCTION FOR ALL THREE CATEGORIES. Task sequences, operating systems and
# applications differ in what a row SAYS and not at all in how a folder path
# becomes a level, so a second copy of this would be a second place for the two
# to disagree about what 'Clients\Laptops' means.
#
# IT TAKES ROWS AND RETURNS ROWS. Nothing here reads a document or decides what
# a row shows: it is handed built rows, each carrying the folder its subject
# named, and it returns the nodes the category should hold.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTTestRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an object in a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Text, [string] $Folder)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ T = $Text; F = $Folder } {
            param($T, $F)

            $row = New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status 'Ok' -Text $T `
                -Field @() -Command 'Get-HDTConsoleWorkspace' -Header ([pscustomobject] @{ Title = ''; Root = ''; DeployRoot = '' })

            $row | Add-Member -MemberType NoteProperty -Name 'Folder' -Value $F -Force
            $row
        }
    }

    function Group-HDTTestRow {
        [CmdletBinding()]
        [OutputType([object])]
        param([object[]] $Row, [string[]] $EmptyFolder = @())

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ R = $Row; E = $EmptyFolder } {
            param($R, $E)

            Group-HDTConsoleFolderRow -Row ([object[]] $R) -Depth 3 -Declared ([string[]] $E) `
                -Header ([pscustomobject] @{ Title = ''; Root = ''; DeployRoot = '' })
        }
    }
}

Describe 'Group-HDTConsoleFolderRow' {

    Context 'nothing is in a folder' {

        It 'hands the rows straight back, at the depth they came in at' {
            # A SHARE THAT NEVER USED FOLDERS MUST LOOK EXACTLY AS IT DID, which
            # is every share that exists today.
            $row = @(
                (New-HDTTestRow -Text 'DEMO-04' -Folder '')
                (New-HDTTestRow -Text 'DEMO-05' -Folder '')
            )

            $grouped = Group-HDTTestRow -Row $row

            @($grouped.TopLevel | ForEach-Object { [string] $_.Text }) | Should -Be @('DEMO-04', 'DEMO-05')
            @($grouped.TopLevel | ForEach-Object { [int] $_.Depth }) | Should -Be @(3, 3)
        }
    }

    Context 'one level' {

        BeforeAll {
            $script:oneLevel = Group-HDTTestRow -Row @(
                (New-HDTTestRow -Text 'DEMO-04' -Folder 'Clients')
                (New-HDTTestRow -Text 'DEMO-05' -Folder 'Clients')
                (New-HDTTestRow -Text 'SRV-01' -Folder 'Servers')
            )
        }

        It 'draws one node per folder, in name order' {
            @($script:oneLevel.TopLevel | ForEach-Object { [string] $_.Text }) | Should -Be @('Clients', 'Servers')
        }

        It 'calls them folders, so the window can offer folder actions on them' {
            @($script:oneLevel.TopLevel | ForEach-Object { [string] $_.Kind }) |
                Should -Be @('Folder', 'Folder')
        }

        It 'puts each row under its own folder' {
            $clients = @($script:oneLevel.TopLevel)[0]

            @($clients.Children | ForEach-Object { [string] $_.Text }) | Should -Be @('DEMO-04', 'DEMO-05')
        }

        It 'indents what it moved' {
            $clients = @($script:oneLevel.TopLevel)[0]

            [int] $clients.Depth | Should -Be 3
            @($clients.Children | ForEach-Object { [int] $_.Depth }) | Should -Be @(4, 4)
        }
    }

    Context 'a folder inside a folder' {

        BeforeAll {
            $script:nested = Group-HDTTestRow -Row @(
                (New-HDTTestRow -Text 'LAP-01' -Folder 'Clients\Laptops')
                (New-HDTTestRow -Text 'DESK-01' -Folder 'Clients\Desktops')
                (New-HDTTestRow -Text 'LOOSE' -Folder '')
            )
        }

        It 'draws the parent once, whatever is under it' {
            @($script:nested.TopLevel | Where-Object { $_.Kind -eq 'Folder' } |
                    ForEach-Object { [string] $_.Text }) | Should -Be @('Clients')
        }

        It 'nests the children of that parent' {
            $clients = @($script:nested.TopLevel | Where-Object { $_.Kind -eq 'Folder' })[0]

            @($clients.Children | ForEach-Object { [string] $_.Text }) | Should -Be @('Desktops', 'Laptops')
            @($clients.Children | ForEach-Object { [int] $_.Depth }) | Should -Be @(4, 4)
        }

        It 'keeps a row that is in no folder beside the folders, not inside one' {
            # AND AFTER THEM, which is where Workbench puts loose items.
            @($script:nested.TopLevel | ForEach-Object { [string] $_.Text }) |
                Should -Be @('Clients', 'LOOSE')
        }
    }

    Context 'a folder with nothing in it' {

        # RIGHT-CLICK, NEW FOLDER, TYPE A NAME - and nothing is in it yet. The
        # rows cannot produce that folder, so the share declares it: see
        # Add-HDTWorkspaceFolder.

        It 'draws a declared folder that no row named' {
            $grouped = Group-HDTTestRow -Row @((New-HDTTestRow -Text 'DEMO-04' -Folder '')) `
                -EmptyFolder @('Kiosks')

            @($grouped.TopLevel | ForEach-Object { [string] $_.Text }) | Should -Be @('Kiosks', 'DEMO-04')
        }

        It 'draws it once when a row names it too' {
            # A FOLDER MADE HERE AND THEN FILLED is declared and named, and two
            # folders of the same name side by side is the tree saying the share
            # has two.
            $grouped = Group-HDTTestRow -Row @((New-HDTTestRow -Text 'DEMO-04' -Folder 'Clients')) `
                -EmptyFolder @('Clients')

            @($grouped.TopLevel | ForEach-Object { [string] $_.Text }) | Should -Be @('Clients')
            @(@($grouped.TopLevel)[0].Children | ForEach-Object { [string] $_.Text }) | Should -Be @('DEMO-04')
        }

        It 'nests a declared folder under its declared parent' {
            $grouped = Group-HDTTestRow -Row @() -EmptyFolder @('Clients', 'Clients\Kiosks')

            @($grouped.Node | ForEach-Object { [string] $_.Text }) | Should -Be @('Clients', 'Kiosks')
        }
    }

    Context 'the flat list the tree binds to' {

        It 'returns every node once, parents before their children' {
            $grouped = Group-HDTTestRow -Row @(
                (New-HDTTestRow -Text 'LAP-01' -Folder 'Clients\Laptops')
                (New-HDTTestRow -Text 'LOOSE' -Folder '')
            )

            @($grouped.Node | ForEach-Object { [string] $_.Text }) |
                Should -Be @('Clients', 'Laptops', 'LAP-01', 'LOOSE')
        }
    }
}
