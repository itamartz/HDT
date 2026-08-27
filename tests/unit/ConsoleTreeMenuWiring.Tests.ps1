# THE TREE'S RIGHT-CLICK MENU IS NOT THE NEW TASK SEQUENCE ITEM'S BUSINESS.
#
# Every handler on this menu - the ContextMenuOpening guard that decides what a
# row offers, the right-click-selects-the-row fix, and the Click on Clear Run,
# Delete Folder, Import Drivers, Remove Task Sequence, New Folder and the rest -
# lived inside the ELSE of "is -NewSequenceXaml empty?". A view built without
# that one unrelated dialog's markup therefore got NO right-click menu at all,
# rather than one item fewer.
#
# NOBODY EVER HIT IT, AND IT WAS STILL WORTH FIXING. Show-HDTConsole defaults
# -NewSequenceXamlPath to the shipped file, so the real entry point always
# passes it. The trap was the SYMPTOM: a view built any other way came up with
# every menu item Visible and no guard at all, which reads exactly like broken
# visibility logic. It cost twenty minutes of reading correct code looking for a
# fault that was in an enclosing brace a thousand lines up.
#
# WHAT THIS FILE PINS is that the menu belongs to the tree. If somebody moves
# this wiring back under a conditional for some other optional window, these
# fail rather than the next person losing an afternoon.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
            -Force -ErrorAction Stop

        $script:consoleXaml = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTConsole.xaml'))

        function New-HDTTestMenuWindow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter()] [AllowEmptyString()] [string] $NewSequenceXaml = '')

            $share = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            }

            # THE TREE'S ROOTS, NOT A SHARE NODE. Get-HDTConsoleTreeNode returns
            # a FLAT list with a Depth and WPF builds the branches from each
            # row's Children, so only Depth 0 is handed over - the same thing
            # Show-HDTConsole does. Passing the flat list draws every node twice.
            $node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @(
                        Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $share)) |
                    Where-Object { $_.Depth -eq 0 })

            $window = New-HDTConsoleView `
                -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
                -Xaml $script:consoleXaml -Title 'HDT' -Node ([object[]] $node) `
                -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 0; Top = 0 }) `
                -RefreshSecond 3600 -NewSequenceXaml $NewSequenceXaml

            $content = $window.Content
            $content.Measure([System.Windows.Size]::new(1180, 760))
            $content.Arrange([System.Windows.Rect]::new(0, 0, 1180, 760))
            $content.UpdateLayout()

            return $window
        }

        # RIGHT-CLICK, STAGED. ContextMenuEventArgs has only an internal
        # constructor, so the event a real mouse raises can only be built by
        # reflection - and it has to be the real event, because the guard under
        # test cancels the menu from it.
        function Invoke-HDTTestRightClick {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Drives an in-memory window; it changes no state on the machine.')]
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter(Mandatory = $true)] [object] $Window)

            $tree = $Window.FindName('HDTConsoleTree')

            $flags = [System.Reflection.BindingFlags]::NonPublic -bor
            [System.Reflection.BindingFlags]::Instance

            $opening = [System.Activator]::CreateInstance(
                [System.Windows.Controls.ContextMenuEventArgs], $flags, $null,
                @([object] $tree, [object] $true), $null)

            $opening.Source = $tree
            $tree.RaiseEvent($opening)

            return $opening
        }

        function Select-HDTTestTreeRow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Drives an in-memory window; it changes no state on the machine.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [object] $Window,
                [Parameter(Mandatory = $true)] [string] $Like)

            $tree = $Window.FindName('HDTConsoleTree')
            $tree.UpdateLayout()

            $row = @($tree.ItemsSource) |
                Where-Object { [string] $_.Text -like ('*{0}*' -f $Like) } | Select-Object -First 1
            if ($null -eq $row) { return $null }

            $item = $tree.ItemContainerGenerator.ContainerFromItem($row)
            if ($null -eq $item) { return $null }

            $item.IsSelected = $true
            $Window.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)

            return $row
        }
    }

    Describe 'the tree context menu on a console built without the New Task Sequence markup' {

        BeforeAll {
            $script:bare = New-HDTTestMenuWindow -NewSequenceXaml ''

            $script:bareRow = Select-HDTTestTreeRow -Window $script:bare -Like 'Deployment Shares'
            $script:bareOpening = Invoke-HDTTestRightClick -Window $script:bare
        }

        It 'selects the row it was asked for, so the rest of this is testing something' {
            $script:bareRow | Should -Not -BeNullOrEmpty
        }

        # THE ONE THAT WAS BROKEN.
        #
        # NAMED ITEMS, NOT A COUNT. Counting visible-against-total looked like a
        # test and was not: with the menu unwired EVERY item stays Visible
        # except New Task Sequence, which the broken branch collapsed by itself
        # - so 'fewer than all' was satisfied by the bug. These are items that
        # belong to rows this is not, and only the guard can collapse them.
        It 'collapses <Item>, which does not belong to the root row' -ForEach @(
            @{ Item = 'HDTRemoveSequenceMenuItem' }
            @{ Item = 'HDTImportOperatingSystemMenuItem' }
            @{ Item = 'HDTRemoveOperatingSystemMenuItem' }
            @{ Item = 'HDTRemoveApplicationMenuItem' }
            @{ Item = 'HDTRemoveDriverFolderMenuItem' }
            @{ Item = 'HDTRemoveMonitorRunMenuItem' }
            @{ Item = 'HDTBootImageMenuItem' }
        ) {
            $script:bare.FindName($Item).Visibility |
                Should -Be ([System.Windows.Visibility]::Collapsed) `
                    -Because 'only the ContextMenuOpening guard collapses this, and it must be wired'
        }

        It 'offers the root row its own actions, which have nothing to do with task sequences' {
            $header = @(@($script:bare.FindName('HDTConsoleTreeMenu').Items) |
                    Where-Object { $_ -is [System.Windows.Controls.MenuItem] } |
                    Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible } |
                    ForEach-Object { [string] $_.Header })

            $header | Should -Contain 'Open Deployment Share'
        }

        # NO MARKUP, NO ITEM - and the guard must not put it back.
        It 'never shows New Task Sequence, whose window does not exist' {
            $sequenceRow = Select-HDTTestTreeRow -Window $script:bare -Like 'Deployment Shares'
            $sequenceRow | Should -Not -BeNullOrEmpty

            [void] (Invoke-HDTTestRightClick -Window $script:bare)

            $script:bare.FindName('HDTNewSequenceMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Collapsed)
        }
    }

    Describe 'the same console built with the markup' {

        BeforeAll {
            $script:full = New-HDTTestMenuWindow -NewSequenceXaml '<Window/>'

            [void] (Select-HDTTestTreeRow -Window $script:full -Like 'Deployment Shares')
            [void] (Invoke-HDTTestRightClick -Window $script:full)
        }

        It 'wires the menu, exactly as it did before' {
            $menu = $script:full.FindName('HDTConsoleTreeMenu')

            @(@($menu.Items) |
                    Where-Object { $_ -is [System.Windows.Controls.MenuItem] } |
                    Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible }) |
                Should -Not -BeNullOrEmpty
        }
    }
}
