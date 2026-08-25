# The Selection Profiles window, built and wired without being shown.
#
# WHAT IS ASSERTED HERE IS THE WIRING. What each control decides is
# Get-HDTConsoleSelectionProfileSetting's and Get-HDTConsoleSelectionProfileTree's,
# each with its own tests. What those cannot show is whether the markup still
# carries the control the host looks up by name, and whether the handler on it
# reaches the object it writes to.
#
# THIS FILE EXISTS BECAUSE OPENING THE WINDOW FOUND TWO DEFECTS AND NOTHING ELSE
# COULD HAVE. $refresh assigned SelectedItem, which re-raised SelectionChanged,
# which called $refresh - the window could not be built at all, and every view
# model test was green. The first It below is the one that catches that class of
# fault, and it catches it by doing nothing more than constructing the thing.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # THE SHIPPED MARKUP, so this window and the one the console opens cannot
    # drift apart.
    $script:profileXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTSelectionProfile.xaml'))

    $script:root = 'C:\ws'
    $script:documentPath = 'C:\ws\Control\selection-profiles.yaml'

    $script:profileLine = [string[]] @(
        '# Both vendor packs, because the floor is mixed.'
        'schemaVersion: 1'
        'profiles:'
        '  - id: boot-critical'
        '    name: Boot critical - Dell and HP'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Drivers\WinPE\HP WinPE 11 x64'
    )

    function New-HDTTestProfileHostDouble {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        return [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }
    }

    function New-HDTTestProfileWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()] [object] $ConsoleHost,
            [Parameter()] [AllowNull()] [object] $FileSystem,
            [Parameter()] [AllowNull()] [string[]] $Line
        )

        if ($null -eq $Line) { $Line = $script:profileLine }

        $folder = Get-HDTShareContentFolder -Root $script:root -FileSystem (New-HDTFakeFileSystem -File @{
                'C:\ws\Drivers\WinPE\Dell WinPE 11 x64\e.inf' = '[Version]'
                'C:\ws\Drivers\WinPE\HP WinPE 11 x64\s.inf'   = '[Version]'
                'C:\ws\Applications\7Zip\app.yaml'            = 'schemaVersion: 1'
            })

        $selection = @(Get-HDTSelectionProfileFromLine -Line $Line -Path $script:documentPath)

        return New-HDTConsoleSelectionProfileView -ConsoleHost $ConsoleHost -Xaml $script:profileXaml `
            -Root $script:root -Line $Line -SelectionProfile ([object[]] $selection) `
            -Folder ([object[]] $folder) -FileSystem $FileSystem `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1120; Height = 720; Left = 40; Top = 20 })
    }
}

Describe 'New-HDTConsoleSelectionProfileView' {

    Context 'the window it builds' {

        BeforeAll {
            $script:hostDouble = New-HDTTestProfileHostDouble
            $script:window = New-HDTTestProfileWindow -ConsoleHost $script:hostDouble
        }

        # THE ONE THAT CATCHES A RE-ENTRANT REFRESH. $refresh assigns ItemsSource
        # and SelectedItem, both of which raise SelectionChanged; a handler that
        # calls $refresh back recurses until PowerShell gives up. That is not a
        # subtle failure - the window cannot be constructed - but nothing except
        # constructing it will find it.
        It 'builds a window without a desktop, and without recursing' {
            $script:window | Should -Not -BeNullOrEmpty
            $script:window.GetType().Name | Should -BeExactly 'Window'
        }

        It 'wears the anvil rather than the shell that started it' {
            $script:window.Icon | Should -Not -BeNullOrEmpty
        }

        It 'finds every control the host wires by name' {
            foreach ($name in @('HDTSelectionProfileTitleText', 'HDTSelectionProfilePathText',
                    'HDTSelectionProfileList', 'HDTSelectionProfileNameBox', 'HDTSelectionProfileIdText',
                    'HDTSelectionProfileNewButton', 'HDTSelectionProfileRenameButton',
                    'HDTSelectionProfileDeleteButton', 'HDTSelectionProfileTree',
                    'HDTSelectionProfileSummaryText', 'HDTSelectionProfileCommandText',
                    'HDTSelectionProfileSaveButton', 'HDTSelectionProfileCloseButton')) {

                $script:window.FindName($name) |
                    Should -Not -BeNullOrEmpty -Because "the markup promises $name"
            }
        }

        It 'paints the palette onto the window' {
            $script:window.Resources['HDTErrorBrush'] | Should -Not -BeNullOrEmpty
        }

        It 'offers the built-ins and the authored profile together' {
            $list = $script:window.FindName('HDTSelectionProfileList')

            @($list.ItemsSource | ForEach-Object { $_.Id }) | Should -Contain 'boot-critical'
            @($list.ItemsSource | ForEach-Object { $_.Id }) | Should -Contain 'everything'
        }

        # IT OPENS ON SOMETHING EDITABLE. Selecting a built-in first would open
        # the window with every button grey.
        It 'selects the authored profile rather than a built-in' {
            $list = $script:window.FindName('HDTSelectionProfileList')

            [string] $list.SelectedItem.Id | Should -BeExactly 'boot-critical'
        }

        It 'hands the tree its roots, not the flat list' {
            $tree = $script:window.FindName('HDTSelectionProfileTree')

            @($tree.ItemsSource | ForEach-Object { $_.Name }) |
                Should -Be @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
        }

        # THE ID IS THE PROFILE'S OWN, NOT ONE DERIVED FROM ITS NAME. Deriving
        # would print 'boot-critical-dell-and-hp' beside a profile whose id is
        # 'boot-critical' - a string somebody could paste into workspace.yaml
        # where it would match nothing.
        It 'shows the selected profile''s real id' {
            [string] $script:window.FindName('HDTSelectionProfileIdText').Text |
                Should -BeExactly 'id: boot-critical'
        }
    }

    Context 'New, pressed with a name typed' {

        BeforeAll {
            $script:newHost = New-HDTTestProfileHostDouble
            $script:newWindow = New-HDTTestProfileWindow -ConsoleHost $script:newHost

            $script:newWindow.FindName('HDTSelectionProfileNameBox').Text = 'HP WinPE 11 x64'
            $script:newWindow.FindName('HDTSelectionProfileNewButton').RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        }

        It 'adds the profile to the list' {
            $list = $script:newWindow.FindName('HDTSelectionProfileList')

            @($list.ItemsSource | ForEach-Object { $_.Id }) | Should -Contain 'hp-winpe-11-x64'
        }

        It 'selects what it just made, so the tree is about it' {
            $list = $script:newWindow.FindName('HDTSelectionProfileList')

            [string] $list.SelectedItem.Id | Should -BeExactly 'hp-winpe-11-x64'
        }

        It 'shows the call it ran' {
            [string] $script:newWindow.FindName('HDTSelectionProfileCommandText').Text |
                Should -BeLike '*New-HDTSelectionProfile*hp-winpe-11-x64*'
        }
    }

    Context 'New, pressed with nothing usable in the box' {

        BeforeAll {
            $script:emptyHost = New-HDTTestProfileHostDouble
            $script:emptyWindow = New-HDTTestProfileWindow -ConsoleHost $script:emptyHost

            $script:emptyWindow.FindName('HDTSelectionProfileNameBox').Text = '???'
            $script:emptyWindow.FindName('HDTSelectionProfileNewButton').RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        }

        # IT SAYS SO RATHER THAN INVENTING A NAME. A generated 'profile-1' would
        # be a name nobody chose appearing in somebody's document.
        It 'adds nothing and says why' {
            $list = $script:emptyWindow.FindName('HDTSelectionProfileList')

            @($list.ItemsSource).Count | Should -Be 4
            [string] $script:emptyWindow.FindName('HDTSelectionProfileCommandText').Text |
                Should -BeLike '*type a name*'
        }
    }

    Context 'a built-in, selected' {

        BeforeAll {
            $script:builtInHost = New-HDTTestProfileHostDouble
            $script:builtInWindow = New-HDTTestProfileWindow -ConsoleHost $script:builtInHost

            $list = $script:builtInWindow.FindName('HDTSelectionProfileList')
            $list.SelectedItem = @($list.ItemsSource | Where-Object { $_.Id -eq 'everything' })[0]
        }

        # THE BUTTONS GO GREY RATHER THAN REFUSING AFTER THE CLICK. all-drivers,
        # everything and nothing have no lines in any document.
        It 'greys Rename, Delete and Save' {
            $script:builtInWindow.FindName('HDTSelectionProfileRenameButton').IsEnabled | Should -BeFalse
            $script:builtInWindow.FindName('HDTSelectionProfileDeleteButton').IsEnabled | Should -BeFalse
            $script:builtInWindow.FindName('HDTSelectionProfileSaveButton').IsEnabled | Should -BeFalse
        }

        It 'leaves New alone, because a built-in being selected does not stop you making one' {
            $script:builtInWindow.FindName('HDTSelectionProfileNewButton').IsEnabled | Should -BeTrue
        }
    }

    Context 'Delete, pressed' {

        BeforeAll {
            $script:deleteHost = New-HDTTestProfileHostDouble
            $script:deleteWindow = New-HDTTestProfileWindow -ConsoleHost $script:deleteHost

            $script:deleteWindow.FindName('HDTSelectionProfileDeleteButton').RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        }

        It 'takes the profile out of the list' {
            $list = $script:deleteWindow.FindName('HDTSelectionProfileList')

            @($list.ItemsSource | ForEach-Object { $_.Id }) | Should -Not -Contain 'boot-critical'
        }

        It 'leaves the built-ins, which it cannot remove' {
            $list = $script:deleteWindow.FindName('HDTSelectionProfileList')

            @($list.ItemsSource).Count | Should -Be 3
        }
    }

    Context 'Save, pressed' {

        BeforeAll {
            $script:saveFs = New-HDTFakeFileSystem
            $script:saveHost = New-HDTTestProfileHostDouble
            $script:saveWindow = New-HDTTestProfileWindow -ConsoleHost $script:saveHost -FileSystem $script:saveFs

            # Untick the HP pack, which is what an administrator retiring a
            # vendor would do.
            $tree = $script:saveWindow.FindName('HDTSelectionProfileTree')
            $drivers = @($tree.ItemsSource | Where-Object { $_.Name -eq 'Drivers' })[0]
            $winpe = @($drivers.Children | Where-Object { $_.Name -eq 'WinPE' })[0]
            @($winpe.Children | Where-Object { $_.Name -eq 'HP WinPE 11 x64' })[0].State = $false

            $script:saveWindow.FindName('HDTSelectionProfileSaveButton').RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent)))
        }

        It 'writes the document, and only through the injected file system' {
            $script:saveFs.TestPath($script:documentPath) | Should -BeTrue
        }

        It 'writes what is ticked NOW rather than what it opened with' {
            $written = [string] $script:saveFs.ReadAllText($script:documentPath)

            $written | Should -BeLike '*Dell WinPE 11 x64*'
            $written | Should -Not -BeLike '*HP WinPE 11 x64*'
        }

        # THE COMMENT SURVIVES A SAVE, which is the whole reason these editors
        # splice instead of re-serialising.
        It 'keeps the sentence the administrator wrote at the top' {
            [string] $script:saveFs.ReadAllText($script:documentPath) |
                Should -BeLike '*Both vendor packs, because the floor is mixed.*'
        }

        It 'tells the host it saved' {
            [string] $script:saveHost.Answer | Should -BeExactly 'saved'
        }

        It 'shows both calls a Save is' {
            $text = [string] $script:saveWindow.FindName('HDTSelectionProfileCommandText').Text

            $text | Should -BeLike '*Set-HDTSelectionProfile*'
            $text | Should -BeLike '*Save-HDTSelectionProfileDocument*'
        }
    }

    Context 'a share with no document at all' {

        BeforeAll {
            $script:freshHost = New-HDTTestProfileHostDouble
            $script:freshWindow = New-HDTTestProfileWindow -ConsoleHost $script:freshHost -Line ([string[]] @())
        }

        # THE ORDINARY FIRST RUN. New-HDTWorkspace writes no
        # selection-profiles.yaml, so this is what every new share opens on.
        It 'opens on the built-ins alone' {
            $list = $script:freshWindow.FindName('HDTSelectionProfileList')

            @($list.ItemsSource).Count | Should -Be 3
        }

        It 'has nothing selected, and says what to do about it' {
            [string] $script:freshWindow.FindName('HDTSelectionProfileSummaryText').Text |
                Should -BeLike '*press New*'
        }
    }
}

}
