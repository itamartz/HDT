# The driver catalog: what is in the store, and which of it is turned off.
#
# A SELECTION PROFILE NAMES FOLDERS; THIS SAYS WHAT IS INSIDE ONE. It is what
# the console's driver grid is made of and what the properties window reads.
#
# THE ENABLED FLAG IS THE ONLY FACT NOT IN THE .inf, and it is recorded as the
# set of drivers that are OFF rather than as a copy of every driver plus a flag.
# An index would duplicate the .inf, need maintaining, and leave a driver
# imported tomorrow in no state at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    # The captured excerpt, so the catalog is read out of a real .inf's shape.
    $script:infText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\drivers\net-excerpt.inf'))

    function New-HDTTestStore {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [AllowEmptyString()] [string] $State = '')

        $file = @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell\network\e1d68x64.inf' = $script:infText
            'C:\HDTLab\Share\Drivers\WinPE\Dell\network\e1d68x64.sys' = 'binary'
            'C:\HDTLab\Share\Drivers\WinPE\Dell\storage\iaStor.inf'   = $script:infText
            'C:\HDTLab\Share\Drivers\WinPE\HP\net.inf'                = $script:infText
        }

        if (-not [string]::IsNullOrEmpty($State)) {
            $file['C:\HDTLab\Share\Control\driver-state.yaml'] = $State
        }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Get-HDTDriver' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTDriver' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'finds every .inf in the store, at any depth' {
        $driver = @(Get-HDTDriver -Root $script:root -FileSystem (New-HDTTestStore))

        @($driver).Count | Should -Be 3
        @($driver | ForEach-Object { $_.InfName }) | Should -Contain 'e1d68x64.inf'
        @($driver | ForEach-Object { $_.InfName }) | Should -Contain 'iaStor.inf'
    }

    # THE .sys AND .cat BESIDE IT ARE NOT DRIVERS, they are what a driver is
    # made of - and a grid listing them would be four rows for one driver.
    It 'lists only the .inf files' {
        @(Get-HDTDriver -Root $script:root -FileSystem (New-HDTTestStore) |
                Where-Object { $_.InfName -like '*.sys' }) | Should -BeNullOrEmpty
    }

    It 'reads one folder when asked for one' {
        $driver = @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem (New-HDTTestStore))

        @($driver).Count | Should -Be 1
        $driver[0].InfName | Should -BeExactly 'net.inf'
    }

    # WHAT THE GRID'S COLUMNS BIND TO.
    It 'carries what the console shows' {
        $one = @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem (New-HDTTestStore))[0]

        $one.Name | Should -BeExactly 'Intel(R) 82576 Gigabit Dual Port Network Connection'
        $one.Class | Should -BeExactly 'Net'
        $one.Provider | Should -BeExactly 'Microsoft'
        $one.Version | Should -BeExactly '12.19.1.32'
        $one.Date | Should -BeExactly '08/03/2015'
    }

    # WHAT THE PROPERTIES WINDOW SHOWS.
    It 'carries the PnP ids' {
        $one = @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem (New-HDTTestStore))[0]

        $one.HardwareId | Should -Contain 'PCI\VEN_8086&DEV_10DE'
        $one.HardwareId | Should -Contain 'PCI\VEN_10EC&DEV_B822&SUBSYS_B82210EC'
    }

    It 'carries the path a profile and a state file name it by' {
        $one = @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem (New-HDTTestStore))[0]

        $one.Path | Should -BeExactly 'WinPE\HP\net.inf'
        $one.Folder | Should -BeExactly 'WinPE\HP'
    }

    # A SHARE NOBODY HAS DISABLED ANYTHING ON HAS NO DOCUMENT, which is the
    # ordinary case - and everything on it is on.
    It 'has every driver enabled when there is no state document' {
        @(Get-HDTDriver -Root $script:root -FileSystem (New-HDTTestStore) |
                Where-Object { -not $_.Enabled }) | Should -BeNullOrEmpty
    }

    It 'reports a driver the state document turned off' {
        $state = @(
            'schemaVersion: 1'
            'disabled:'
            '  - WinPE\HP\net.inf'
        ) -join "`r`n"

        $driver = @(Get-HDTDriver -Root $script:root -FileSystem (New-HDTTestStore -State $state))

        @($driver | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Path }) |
            Should -Be @('WinPE\HP\net.inf')
    }

    It 'answers nothing for a share with no driver store' {
        @(Get-HDTDriver -Root $script:root -FileSystem (New-HDTFakeFileSystem)) | Should -BeNullOrEmpty
    }

    # ONE BAD .inf MUST NOT EMPTY THE GRID - the rule a sequence that will not
    # load already follows in the tree.
    It 'keeps a row for a file it could not read' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\good.inf' = $script:infText
            'C:\HDTLab\Share\Drivers\WinPE\odd.inf'  = ''
        }

        $driver = @(Get-HDTDriver -Root $script:root -FileSystem $fs)

        @($driver).Count | Should -Be 2
        @($driver | Where-Object { $_.InfName -eq 'odd.inf' })[0].Name | Should -BeExactly 'odd.inf'
    }
}

Describe 'Set-HDTDriverState' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Set-HDTDriverState' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'turns one driver off and leaves it on the share' {
        $fs = New-HDTTestStore

        $result = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $false `
            -FileSystem $fs -Confirm:$false

        $result.Changed | Should -BeTrue
        $fs.TestPath('C:\HDTLab\Share\Drivers\WinPE\HP\net.inf') | Should -BeTrue
        @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem $fs)[0].Enabled | Should -BeFalse
    }

    It 'turns it back on' {
        $fs = New-HDTTestStore

        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $false -FileSystem $fs -Confirm:$false
        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $true -FileSystem $fs -Confirm:$false

        @(Get-HDTDriver -Root $script:root -Path 'WinPE\HP' -FileSystem $fs)[0].Enabled | Should -BeTrue
    }

    # AN EMPTY LIST AND NO FILE SAY THE SAME THING, and two spellings of one
    # state is one more thing to keep in step.
    It 'removes the document when the last disabled driver is enabled' {
        $fs = New-HDTTestStore

        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $false -FileSystem $fs -Confirm:$false
        $fs.TestPath('C:\HDTLab\Share\Control\driver-state.yaml') | Should -BeTrue

        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $true -FileSystem $fs -Confirm:$false
        $fs.TestPath('C:\HDTLab\Share\Control\driver-state.yaml') | Should -BeFalse
    }

    It 'leaves the other disabled drivers alone' {
        $fs = New-HDTTestStore

        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $false -FileSystem $fs -Confirm:$false
        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\Dell\storage\iaStor.inf' -Enabled $false -FileSystem $fs -Confirm:$false

        @(Get-HDTDriver -Root $script:root -FileSystem $fs | Where-Object { -not $_.Enabled }).Count |
            Should -Be 2
    }

    It 'says nothing changed when it already says that' {
        $fs = New-HDTTestStore

        (Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $true `
                -FileSystem $fs -Confirm:$false).Changed | Should -BeFalse
    }

    # A STALE CONSOLE HOLDING A PATH SOMEBODY HAS SINCE DELETED is the commonest
    # way here, and recording it would leave a document naming a file nobody can
    # find.
    It 'refuses a driver that is not on the share' {
        { Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\gone.inf' -Enabled $false `
                -FileSystem (New-HDTTestStore) -Confirm:$false } | Should -Throw
    }

    It 'writes nothing under -WhatIf' {
        $fs = New-HDTTestStore

        $null = Set-HDTDriverState -Root $script:root -Path 'WinPE\HP\net.inf' -Enabled $false -FileSystem $fs -WhatIf

        $fs.TestPath('C:\HDTLab\Share\Control\driver-state.yaml') | Should -BeFalse
    }
}
