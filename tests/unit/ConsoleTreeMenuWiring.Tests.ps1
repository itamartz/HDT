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
            param(
                [Parameter()] [AllowEmptyString()] [string] $NewSequenceXaml = '',
                [Parameter()] [AllowEmptyString()] [string] $ImportWindowsUpdateXaml = '')

            # AN UPDATE ON THE SHARE, so the release group and the update row
            # exist to be right-clicked at all. Without one the Windows Updates
            # category draws a (none) placeholder and the two rows this is about
            # are never built.
            $share = New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
                'C:\ws\WindowsUpdates\KB5094126-x64\update.yaml' = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: 2026-06 Cumulative Update for Windows 11 24H2
release: Win11-24H2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64_1b7f.msu
'@
                'C:\ws\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64_1b7f.msu' = 'not a real msu'
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
                -RefreshSecond 3600 -NewSequenceXaml $NewSequenceXaml `
                -ImportWindowsUpdateXaml $ImportWindowsUpdateXaml

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

        # A ROW THAT IS NOT A ROOT, WHICH IS WHERE THE DEFECT LIVED. The tree's
        # ItemsSource is only the Depth 0 roots and WPF generates every branch
        # below them lazily, so Select-HDTTestTreeRow above can only reach a
        # root - and the rows nobody could right-click were four levels down.
        # This walks the Children the tree itself binds to, expanding each
        # ancestor and letting the container generator run, which is what a
        # person with a mouse does before they right-click anything.
        function Select-HDTTestTreeBranch {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Drives an in-memory window; it changes no state on the machine.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [object] $Window,
                [Parameter(Mandatory = $true)] [string[]] $Path)

            $tree = $Window.FindName('HDTConsoleTree')

            # THE SAME PASS New-HDTTestMenuWindow RUNS, and it has to run again
            # after every expansion - see the note in the loop below.
            $layout = {
                $content = $Window.Content
                $content.Measure([System.Windows.Size]::new(1180, 760))
                $content.Arrange([System.Windows.Rect]::new(0, 0, 1180, 760))
                $content.UpdateLayout()
            }.GetNewClosure()

            & $layout

            $parent = $tree
            $row = @($tree.ItemsSource)
            $item = $null

            foreach ($like in $Path) {

                $wanted = @($row) | Where-Object { [string] $_.Text -like ('*{0}*' -f $like) } |
                    Select-Object -First 1

                if ($null -eq $wanted) { return $null }

                # THE CONTAINER HAS TO EXIST BEFORE IT CAN BE ASKED FOR. An
                # unexpanded TreeViewItem has generated no children, so the
                # template is applied and the layout run before the next hop.
                [void] $parent.ApplyTemplate()
                $parent.UpdateLayout()

                $item = $parent.ItemContainerGenerator.ContainerFromItem($wanted)
                if ($null -eq $item) { return $null }

                $item.IsExpanded = $true
                [void] $item.ApplyTemplate()

                # A FULL PASS OVER THE WHOLE TREE, NOT UpdateLayout ON THE ROW.
                # This window is never shown, so it has no PresentationSource
                # driving layout - and UpdateLayout on an element inside one that
                # was never measured does nothing at all. Expanding a row then
                # produces NO child containers, ContainerFromItem returns null
                # one level down, and the walk stops at the category with every
                # row below it unreachable. Measure and Arrange from the content
                # root is what actually realises them.
                & $layout

                $parent = $item
                $row = @($wanted.Children)
            }

            $item.IsSelected = $true
            $Window.Dispatcher.Invoke([action] {},
                [System.Windows.Threading.DispatcherPriority]::Background)

            return $tree.SelectedItem
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

    # -----------------------------------------------------------------------
    #
    # THE WINDOWS UPDATES NODE, AND THE ONLY PROOF THAT MEANS ANYTHING HERE.
    #
    # A CLOSED CONTEXT MENU PHOTOGRAPHS EXACTLY LIKE A BROKEN ONE, which is why
    # this defect survived every screenshot this console has ever been in: the
    # tree looked perfect, and right-clicking three of its rows did nothing. A
    # picture could not have caught it and cannot prove it fixed.
    #
    # SO THE REAL EVENT IS RAISED ON THE REAL WINDOW. ContextMenuEventArgs has
    # only an internal constructor, so this builds the one a mouse would build,
    # by reflection, and hands it to the tree WPF would hand it to. Handled is
    # the whole defect: the guard sets it for a kind it has not been told about,
    # and a Handled ContextMenuOpening is a menu that never opens - no matter
    # how Visible the items on it are.
    Describe 'right-clicking the Windows Updates rows' {

        BeforeAll {
            $script:updates = New-HDTTestMenuWindow -NewSequenceXaml '<Window/>' `
                -ImportWindowsUpdateXaml '<Window/>'
        }

        # THE ROWS EXIST BEFORE ANY OF THIS MEANS ANYTHING.
        It 'reaches the <Row> row, levels down where nothing could select one before' -ForEach @(
            @{ Row = 'Windows Updates'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates') }
            @{ Row = 'Win11-24H2'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2') }
            @{ Row = 'KB5094126'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2', 'KB5094126') }
        ) {
            Select-HDTTestTreeBranch -Window $script:updates -Path $Path | Should -Not -BeNullOrEmpty
        }

        # THE ONE THAT WAS BROKEN. Handled means the menu never opens.
        It 'opens a menu on <Row> at all, which it did not' -ForEach @(
            @{ Row = 'the Windows Updates category'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates') }
            @{ Row = 'a release group'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2') }
            @{ Row = 'an update'; Path = @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2', 'KB5094126') }
        ) {
            [void] (Select-HDTTestTreeBranch -Window $script:updates -Path $Path)

            $opening = Invoke-HDTTestRightClick -Window $script:updates

            $opening.Handled | Should -BeFalse `
                -Because 'a Handled ContextMenuOpening is a menu that never opens, however Visible its items are'
        }

        # AND IT IS NOT AN EMPTY POPUP. A menu that opens with nothing on it is
        # the same experience as one that does not open, and it is what the
        # blanket 'Category' entry in the guard would have produced here on its
        # own - so the items are NAMED, never counted.
        It 'offers Import Windows Update on the category' {
            [void] (Select-HDTTestTreeBranch -Window $script:updates `
                    -Path @('Deployment Shares', 'HDT share', 'Windows Updates'))

            [void] (Invoke-HDTTestRightClick -Window $script:updates)

            $script:updates.FindName('HDTImportWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Visible)

            # REMOVE IS NOT OFFERED ON A CATEGORY. There is no one update to
            # remove there, and an item that removed the lot is not the press
            # anybody thinks they are making.
            $script:updates.FindName('HDTRemoveWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Collapsed)
        }

        # THE ROW YOU RIGHT-CLICK IS THE RELEASE YOU MEANT, which is the driver
        # store's rule and the reason Import hangs off the group as well.
        It 'offers Import Windows Update on a release group, and not Remove' {
            [void] (Select-HDTTestTreeBranch -Window $script:updates `
                    -Path @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2'))

            [void] (Invoke-HDTTestRightClick -Window $script:updates)

            $script:updates.FindName('HDTImportWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Visible)

            # A RELEASE IS COMPUTED, NOT CREATED. Nothing made it and nothing
            # can remove it.
            $script:updates.FindName('HDTRemoveWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Collapsed)
        }

        It 'offers Remove Windows Update on an update, and not Import' {
            [void] (Select-HDTTestTreeBranch -Window $script:updates `
                    -Path @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2', 'KB5094126'))

            [void] (Invoke-HDTTestRightClick -Window $script:updates)

            $script:updates.FindName('HDTRemoveWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Visible)

            $script:updates.FindName('HDTImportWindowsUpdateMenuItem').Visibility |
                Should -Be ([System.Windows.Visibility]::Collapsed)
        }

        # WHAT THE ADMINISTRATOR ACTUALLY READS. The header comes from the
        # string table, and an item whose Header never got filled draws as a
        # blank strip nobody can identify - which is the same dead end by
        # another route.
        It 'puts a readable name on the item it shows' {
            [void] (Select-HDTTestTreeBranch -Window $script:updates `
                    -Path @('Deployment Shares', 'HDT share', 'Windows Updates', 'Win11-24H2', 'KB5094126'))

            [void] (Invoke-HDTTestRightClick -Window $script:updates)

            $visible = @(@($script:updates.FindName('HDTConsoleTreeMenu').Items) |
                    Where-Object { $_ -is [System.Windows.Controls.MenuItem] } |
                    Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible } |
                    ForEach-Object { [string] $_.Header })

            $visible | Should -Contain 'Remove Windows Update'
        }

        # NO MARKUP, NO ITEM - the rule every other dialog on this menu follows.
        # An item that cannot open its window is one somebody presses to find
        # out nothing happens, which is the failure this whole file is about.
        It 'never shows Import Windows Update when its window does not exist' {
            $bare = New-HDTTestMenuWindow -NewSequenceXaml '<Window/>' -ImportWindowsUpdateXaml ''

            [void] (Select-HDTTestTreeBranch -Window $bare `
                    -Path @('Deployment Shares', 'HDT share', 'Windows Updates'))

            [void] (Invoke-HDTTestRightClick -Window $bare)

            $bare.FindName('HDTImportWindowsUpdateMenuItem').Visibility |
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
