# The driver properties window, built and wired without being shown.
#
# WHAT IS ASSERTED HERE IS THE WIRING. What each field says is
# ConvertFrom-HDTDriverInf's and Get-HDTConsoleDriverRow's, each with its own
# tests. What those cannot show is whether the markup still carries the control
# the view looks up by name, and whether the handler on it reaches the command
# it writes through.
#
# EVERY CONTROL IS FOUND BY NAME AND EVERY BUTTON IS PRESSED. A window here has
# no code-behind: a renamed x:Name is a null reference at the moment somebody
# clicks, and a green view-model suite says nothing about it.
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

        # THE SHIPPED MARKUP, so this window and the one the console opens
        # cannot drift apart.
        $script:driverXaml = [System.IO.File]::ReadAllText(
            (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTDriverProperties.xaml'))

        $script:root = 'C:\ws'

        # A REAL .inf HEADER, captured. An invented one would parse and prove
        # nothing about the files this has to read.
        $script:inf = @(
            '[Version]'
            'Signature   = "$Windows NT$"'
            'Class       = Net'
            'ClassGUID   = {4d36e972-e325-11ce-bfc1-08002be10318}'
            'Provider    = %Intel%'
            'DriverVer   = 01/18/2024,12.19.2.60'
            'CatalogFile = e1d68x64.cat'
            ''
            '[Manufacturer]'
            '%Intel% = Intel, NTamd64.10.0...16299'
            ''
            '[Intel.NTamd64.10.0...16299]'
            '%E1000.DeviceDesc% = E1000, PCI\VEN_8086&DEV_15BB'
            '%E1001.DeviceDesc% = E1000, PCI\VEN_8086&DEV_15BE'
            ''
            '[Strings]'
            'Intel = "Intel"'
            'E1000.DeviceDesc = "Intel(R) Ethernet Connection I219-LM"'
            'E1001.DeviceDesc = "Intel(R) Ethernet Connection I219-V"'
        ) -join "`r`n"

        function New-HDTTestDriverFileSystem {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory fake; it touches no disk.')]
            [CmdletBinding()]
            [OutputType([object])]
            param()

            return New-HDTFakeFileSystem -File @{
                'C:\ws\Drivers\WinPE\Dell\network\e1d68x64.inf' = $script:inf
            }
        }

        function New-HDTTestDriverHostDouble {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test double; it changes no state.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param()

            return [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }
        }

        function New-HDTTestDriverWindow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter()] [object] $ConsoleHost,
                [Parameter()] [AllowNull()] [object] $FileSystem
            )

            if ($null -eq $FileSystem) { $FileSystem = New-HDTTestDriverFileSystem }

            # THE ROW THE GRID HANDS OVER, not a hand-written shape: the window
            # opens on what a double-click carries, so the test opens on the
            # same thing.
            $row = @(Get-HDTConsoleDriverRow -Root $script:root -Path 'Drivers\WinPE\Dell' -FileSystem $FileSystem)

            return New-HDTConsoleDriverView -ConsoleHost $ConsoleHost -Xaml $script:driverXaml `
                -Root $script:root -Driver $row[0] -FileSystem $FileSystem `
                -Theme (Get-HDTConsoleTheme) `
                -Size ([pscustomobject] @{ Width = 1000; Height = 700; Left = 40; Top = 20 })
        }
    }

    Describe 'New-HDTConsoleDriverView' {

        Context 'the window it builds' {

            BeforeAll {
                $script:hostDouble = New-HDTTestDriverHostDouble
                $script:window = New-HDTTestDriverWindow -ConsoleHost $script:hostDouble
            }

            It 'builds a window without a desktop' {
                $script:window | Should -Not -BeNullOrEmpty
                $script:window.GetType().Name | Should -BeExactly 'Window'
            }

            It 'wears the anvil rather than the shell that started it' {
                $script:window.Icon | Should -Not -BeNullOrEmpty
            }

            It 'finds every control the view wires by name' {
                foreach ($name in @('HDTDriverTitleText', 'HDTDriverPathText', 'HDTDriverEnabledCheck',
                        'HDTDriverEnabledHint', 'HDTDriverClassText', 'HDTDriverVendorText',
                        'HDTDriverVersionText', 'HDTDriverDateText', 'HDTDriverArchText',
                        'HDTDriverModelText', 'HDTDriverPnpLabel', 'HDTDriverPnpGrid',
                        'HDTDriverCommandText', 'HDTDriverDeleteButton', 'HDTDriverSaveButton',
                        'HDTDriverCloseButton')) {

                    $script:window.FindName($name) |
                        Should -Not -BeNullOrEmpty -Because "the markup promises $name"
                }
            }

            It 'paints the palette onto the window' {
                $script:window.Resources['HDTErrorBrush'] | Should -Not -BeNullOrEmpty
            }

            It 'names the driver by what the .inf calls it' {
                [string] $script:window.FindName('HDTDriverTitleText').Text |
                    Should -BeExactly 'Intel(R) Ethernet Connection I219-LM'
            }

            It 'says where on the share it sits' {
                [string] $script:window.FindName('HDTDriverPathText').Text |
                    Should -BeExactly 'Drivers\WinPE\Dell\network\e1d68x64.inf'
            }

            It 'fills the fields from the .inf rather than leaving them blank' {
                [string] $script:window.FindName('HDTDriverClassText').Text | Should -BeExactly 'Net'
                [string] $script:window.FindName('HDTDriverVendorText').Text | Should -BeExactly 'Intel'
                [string] $script:window.FindName('HDTDriverVersionText').Text | Should -BeExactly '12.19.2.60'
                [string] $script:window.FindName('HDTDriverDateText').Text | Should -BeExactly '01/18/2024'
            }

            # THE PnP IDS ARE THE POINT OF THE WINDOW. A grid that binds to a
            # property the rows do not have draws the right number of empty
            # lines, which is why this reads one back rather than counting.
            It 'lists the PnP ids the driver claims' {
                $grid = $script:window.FindName('HDTDriverPnpGrid')

                @($grid.ItemsSource).Count | Should -Be 2
                @($grid.ItemsSource | ForEach-Object { $_.HardwareId }) |
                    Should -Contain 'PCI\VEN_8086&DEV_15BB'
            }

            It 'opens with the driver enabled, because nothing disabled it' {
                [bool] $script:window.FindName('HDTDriverEnabledCheck').IsChecked | Should -BeTrue
            }

            # TWO FIELDS SHOWING THE SAME NUMBER UNDER TWO LABELS is what the
            # first render of this window actually did - an 'Architecture' field
            # reading '230 PnP id(s)' beside 'Drivers in file' reading '230
            # device section(s)'. Both were true and neither was the label.
            It 'names the .inf and counts the ids, and does not say the same thing twice' {
                [string] $script:window.FindName('HDTDriverArchText').Text |
                    Should -BeExactly 'e1d68x64.inf'
                [string] $script:window.FindName('HDTDriverModelText').Text | Should -BeExactly '2'
            }

            # A TASK BAR HOLDING TWO OF THESE has to tell them apart, and the
            # friendly name does not - three .inf files in one vendor pack
            # describe themselves identically.
            It 'is titled for the file rather than the word Driver' {
                [string] $script:window.Title | Should -BeExactly 'e1d68x64.inf Properties'
            }

            It 'shows the command the Save would run' {
                [string] $script:window.FindName('HDTDriverCommandText').Text |
                    Should -BeLike 'Set-HDTDriverState *'
            }
        }

        # SAVE IS THE ONLY WRITE, AND IT WRITES ONE BOOLEAN. This is the test
        # that would have caught -Confirm bound to the door scriptblock rather
        # than to Set-HDTDriverState: the button throws, and only pressing it
        # finds out.
        Context 'when Save is pressed with the box cleared' {

            BeforeAll {
                $script:saveFileSystem = New-HDTTestDriverFileSystem
                $script:saveHost = New-HDTTestDriverHostDouble
                $script:saveWindow = New-HDTTestDriverWindow -ConsoleHost $script:saveHost `
                    -FileSystem $script:saveFileSystem

                $script:saveWindow.FindName('HDTDriverEnabledCheck').IsChecked = $false
                $script:saveWindow.FindName('HDTDriverSaveButton').RaiseEvent(
                    (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }

            It 'writes the disabled state to the share' {
                $script:saveFileSystem.TestPath('C:\ws\Control\driver-state.yaml') | Should -BeTrue
            }

            It 'names the driver in the document it wrote' {
                [string] $script:saveFileSystem.ReadAllText('C:\ws\Control\driver-state.yaml') |
                    Should -BeLike '*e1d68x64.inf*'
            }

            It 'tells the console it saved' {
                [string] $script:saveHost.Answer | Should -BeExactly 'saved'
            }

            # THE CATALOG IS THE PROOF, not the document: a state file the
            # catalog does not read back is a write that changed nothing.
            It 'and the catalog reads the driver back as disabled' {
                $again = @(Get-HDTDriver -Root 'C:\ws' -FileSystem $script:saveFileSystem)

                [bool] $again[0].Enabled | Should -BeFalse
            }
        }

        Context 'when Delete is pressed' {

            BeforeAll {
                $script:deleteFileSystem = New-HDTTestDriverFileSystem
                $script:deleteHost = New-HDTTestDriverHostDouble
                $script:deleteWindow = New-HDTTestDriverWindow -ConsoleHost $script:deleteHost `
                    -FileSystem $script:deleteFileSystem

                $script:deleteWindow.FindName('HDTDriverDeleteButton').RaiseEvent(
                    (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }

            It 'tells the console it deleted' {
                [string] $script:deleteHost.Answer | Should -BeExactly 'deleted'
            }

            It 'takes the folder the .inf sat in, not the .inf alone' {
                $script:deleteFileSystem.TestPath('C:\ws\Drivers\WinPE\Dell\network\e1d68x64.inf') |
                    Should -BeFalse
            }

            # IT LEAVES THE STORE STANDING. Remove-HDTDriverFolder refuses the
            # store itself, and a Delete that walked up to it would empty the
            # share.
            It 'leaves the driver store itself alone' {
                $script:deleteFileSystem.TestPath('C:\ws\Drivers') | Should -BeTrue
            }
        }

        Context 'when Close is pressed on a window that was never shown' {

            BeforeAll {
                $script:closeHost = New-HDTTestDriverHostDouble
                $script:closeWindow = New-HDTTestDriverWindow -ConsoleHost $script:closeHost
            }

            # A HANDLER THAT THROWS HERE THROWS IN THE CONSOLE. Close on an
            # unshown window is exactly what Pester does, and the handler has to
            # survive it for any of the rest of this file to run.
            It 'closes without throwing' {
                { $script:closeWindow.FindName('HDTDriverCloseButton').RaiseEvent(
                        (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } |
                    Should -Not -Throw
            }

            It 'and answers nothing, because nothing was written' {
                [string] $script:closeHost.Answer | Should -BeExactly ''
            }
        }
    }
}
