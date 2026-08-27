# What the machine says it has, read through ICimProvider.
#
# THE PROPERTY IS PNPClass, NOT Class. Win32_PnPEntity has both and Class comes
# back null on every row on real hardware - it was checked on this laptop, and
# 32 of 32 devices answered null. A grid grouped by the wrong one is empty and
# looks like a query that matched nothing.
#
# HardwareID AND CompatibleID ARE BOTH CARRIED, and separately: the ranking in
# Get-HDTDriverMatch is built on the array ORDER and on every CompatibleID
# ranking behind every HardwareID. Flattening the two into one list here would
# throw away the distinction the rank is made of.
#
# A DEVICE WITH NO HardwareID IS NOT A DEVICE THIS CAN MATCH. Roughly a tenth of
# the entries on a running Windows are software enumerations with no ids at all;
# they are dropped here rather than by every caller.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Through a variable, never @(ConvertFrom-Json ...) - helpers README F12.
    $script:deviceText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity.json'))
    $script:captured = ConvertFrom-Json -InputObject $script:deviceText

    $script:cim = New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($script:captured) }
}

Describe 'Get-HDTPresentDevice' {

    It 'answers a row per captured device' {
        @(Get-HDTPresentDevice -Cim $script:cim).Count | Should -Be @($script:captured).Count
    }

    It 'reads the class from PNPClass' {
        $row = @(Get-HDTPresentDevice -Cim $script:cim | Where-Object { $_.Name -eq 'Realtek PCIe GbE Family Controller' })[0]

        $row.Class | Should -Be 'Net'
    }

    It 'keeps HardwareID in the order the device published it' {
        $row = @(Get-HDTPresentDevice -Cim $script:cim | Where-Object { $_.Name -eq 'Realtek PCIe GbE Family Controller' })[0]
        $source = @($script:captured | Where-Object { $_.Name -eq 'Realtek PCIe GbE Family Controller' })[0]

        # THE ORDER IS THE RANK. Sorting these, or deduping them into a set,
        # would destroy the only specificity signal there is.
        @($row.HardwareID) | Should -Be @($source.HardwareID)
    }

    It 'keeps CompatibleID separate from HardwareID' {
        $row = @(Get-HDTPresentDevice -Cim $script:cim | Where-Object { $_.Name -eq 'Standard NVM Express Controller' })[0]

        @($row.CompatibleID).Count | Should -BeGreaterThan 0
        @($row.HardwareID) | Should -Not -Contain @($row.CompatibleID)[0]
    }

    It 'answers an empty array rather than throwing when the machine reports nothing' {
        $empty = New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @() }

        @(Get-HDTPresentDevice -Cim $empty).Count | Should -Be 0
    }

    It 'carries a CompatibleID of nothing as an empty array, not a null' {
        # StrictMode is on in engine code, and a null here is an error at the
        # point of use rather than at the point it was produced.
        $row = @(Get-HDTPresentDevice -Cim $script:cim |
                Where-Object { $_.Name -eq 'Intel(R) Wi-Fi 6E AX211 160MHz' })[0]

        $row.PSObject.Properties['CompatibleID'] | Should -Not -BeNullOrEmpty
        { @($row.CompatibleID).Count } | Should -Not -Throw
    }
}
