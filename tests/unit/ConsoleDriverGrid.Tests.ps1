# The driver grid: which rows show one, and what is in it.
#
# A DRIVER FOLDER SHOWS A LIST, NOT FIELDS. Every other row on this tree is a
# handful of fields; a folder in the driver store is forty drivers, or two
# hundred. Workbench splits the same way and for the same reason.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\S'
    $script:infText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\drivers\net-excerpt.inf'))

    function New-HDTTestGridStore {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [AllowEmptyString()] [string] $State = '')

        $file = @{
            'C:\S\Drivers\WinPE\Dell\a.inf' = $script:infText
            'C:\S\Drivers\WinPE\Dell\b.inf' = $script:infText
            'C:\S\Drivers\WinPE\HP\c.inf'   = $script:infText
        }

        if (-not [string]::IsNullOrEmpty($State)) { $file['C:\S\Control\driver-state.yaml'] = $State }

        return New-HDTFakeFileSystem -File $file
    }

    $script:pane = {
        param([string] $Kind)

        $module = Get-Module -Name Hephaestus
        return & $module { param($K) Get-HDTConsoleDetailPane -Kind $K } $Kind
    }

    $script:rows = {
        param([string] $Path, [object] $FileSystem)

        $module = Get-Module -Name Hephaestus
        return @(& $module {
                param($R, $P, $F)
                Get-HDTConsoleDriverRow -Root $R -Path $P -FileSystem $F
            } $script:root $Path $FileSystem)
    }
}

Describe 'Get-HDTConsoleDetailPane' {

    It 'gives a driver folder the grid' {
        (& $script:pane 'DriverFolder').ShowGrid | Should -BeTrue
    }

    # EVERY OTHER ROW IS FIELDS, and a share that suddenly showed a driver grid
    # would be a pane that had lost track of what was selected.
    It 'gives everything else the field list' {
        foreach ($kind in @('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem',
                'Application', 'BootImage', 'SelectionProfile', 'Step', 'Empty')) {

            (& $script:pane $kind).ShowGrid | Should -BeFalse -Because "$kind is fields"
        }
    }
}

Describe 'Get-HDTConsoleDriverRow' {

    It 'lists the drivers in the folder the row names' {
        $row = & $script:rows 'Drivers\WinPE\Dell' (New-HDTTestGridStore)

        @($row).Count | Should -Be 2
        @($row | ForEach-Object { $_.InfName }) | Should -Be @('a.inf', 'b.inf')
    }

    # THE ROW NAMES ITSELF FROM THE STORE'S ROOT and Get-HDTDriver counts from
    # inside it, so the prefix has to come off or nothing is ever found.
    It 'lists the whole store for the Drivers category' {
        @(& $script:rows 'Drivers' (New-HDTTestGridStore)).Count | Should -Be 3
    }

    It 'carries what the columns bind to' {
        $one = @(& $script:rows 'Drivers\WinPE\HP' (New-HDTTestGridStore))[0]

        $one.Name | Should -BeExactly 'Intel(R) 82576 Gigabit Dual Port Network Connection'
        $one.Class | Should -BeExactly 'Net'
        $one.Provider | Should -BeExactly 'Microsoft'
        $one.Version | Should -BeExactly '12.19.1.32'
        $one.Date | Should -BeExactly '08/03/2015'
    }

    # A TICK AND THE WORD, NOT A CHECKBOX. A tick box in a read-only grid
    # invites a click that does nothing; the state is changed in the properties
    # window, where the box sits beside the thing it affects.
    It 'marks an enabled driver with a tick' {
        (@(& $script:rows 'Drivers\WinPE\HP' (New-HDTTestGridStore))[0]).StateMark |
            Should -BeExactly ([string] ([char] 0x2713))
    }

    It 'marks a disabled driver with the word no' {
        $state = @('schemaVersion: 1', 'disabled:', '  - WinPE\HP\c.inf') -join "`r`n"

        (@(& $script:rows 'Drivers\WinPE\HP' (New-HDTTestGridStore -State $state))[0]).StateMark |
            Should -BeExactly 'no'
    }

    It 'carries the PnP ids the properties window shows' {
        (@(& $script:rows 'Drivers\WinPE\HP' (New-HDTTestGridStore))[0]).HardwareId |
            Should -Contain 'PCI\VEN_8086&DEV_10DE'
    }

    # THE GRID IS DRAWN WHILE SOMEBODY CLICKS AROUND A TREE, and a folder
    # deleted mid-session must not take the window down.
    It 'answers nothing for a folder that is not there' {
        & $script:rows 'Drivers\Gone' (New-HDTTestGridStore) | Should -BeNullOrEmpty
    }

    It 'answers nothing when the row names no share' {
        $module = Get-Module -Name Hephaestus

        @(& $module { Get-HDTConsoleDriverRow -Root '' -Path 'Drivers' }) | Should -BeNullOrEmpty
    }
}
