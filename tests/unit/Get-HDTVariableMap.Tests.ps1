# Get-HDTVariableMap is DESIGN 3.2's MDT-to-HDT translation table as data rather
# than as prose: "Get-HDTVariableMap prints this table at runtime, and a contract
# test asserts every documented MDT name has exactly one HDT counterpart, so the
# mapping cannot silently drift."
#
# This file covers the cmdlet's own behaviour - shape, filtering, help. The
# drift-proofing lives in tests/contract/VariableNamespace.Contract.Tests.ps1.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTVariableMap' {

    It 'returns one object per variable' {
        $map = @(Get-HDTVariableMap)

        $map.Count | Should -BeGreaterThan 30
        @($map | Select-Object -ExpandProperty HDTName | Sort-Object -Unique).Count | Should -Be $map.Count
    }

    It 'returns objects carrying HDTName, MdtName, Writable, Origin and Description' {
        $map = @(Get-HDTVariableMap)
        $property = @($map[0].PSObject.Properties.Name)

        foreach ($name in @('HDTName', 'MdtName', 'Writable', 'Origin', 'Description')) {
            $property | Should -Contain $name
        }
    }

    It 'filters by -Name' {
        $one = @(Get-HDTVariableMap -Name 'HDTModel')

        $one.Count | Should -Be 1
        $one[0].HDTName | Should -BeExactly 'HDTModel'
        $one[0].MdtName | Should -BeExactly 'Model'
    }

    It 'accepts a wildcard in -Name' {
        $flag = @(Get-HDTVariableMap -Name 'HDTIs*' | Select-Object -ExpandProperty HDTName | Sort-Object)

        $flag | Should -Be @('HDTIsDesktop', 'HDTIsLaptop', 'HDTIsServer', 'HDTIsUEFI', 'HDTIsVM')
    }

    It 'accepts more than one name' {
        $some = @(Get-HDTVariableMap -Name 'HDTMake', 'HDTModel' | Select-Object -ExpandProperty HDTName | Sort-Object)

        $some | Should -Be @('HDTMake', 'HDTModel')
    }

    It 'returns nothing for a name that is not mapped' {
        @(Get-HDTVariableMap -Name 'HDTNoSuchVariable').Count | Should -Be 0
    }

    It 'reports an engine variable as not writable' {
        $engine = @(Get-HDTVariableMap -Name '_HDTLogPath')

        $engine.Count | Should -Be 1
        $engine[0].Writable | Should -BeFalse
        $engine[0].MdtName | Should -BeExactly '_SMSTSLogPath'
    }

    It 'reports no MDT counterpart for an HDT-only variable' {
        $only = @(Get-HDTVariableMap -Name 'HDTTPMVersion')

        $only.Count | Should -Be 1
        $only[0].MdtName | Should -BeNullOrEmpty
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTVariableMap -ErrorAction Stop

        # The Name assertion is not decoration. Get-Help falls back to a fuzzy
        # search when no command matches exactly, so for a command that does not
        # exist yet it happily returns ANOTHER command's help and a synopsis
        # assertion passes against it. Observed while writing this plan.
        $help.Name | Should -BeExactly 'Get-HDTVariableMap'
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Get-HDTVariableMap \['
    }

    It 'has at least one example in its help' {
        $help = Get-Help -Name Get-HDTVariableMap -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTVariableMap'
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}
