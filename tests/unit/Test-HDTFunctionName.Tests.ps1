BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop

    $script:badName = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/naming/BadName.ps1'
}

Describe 'Test-HDTFunctionName' {

    Context 'valid names' {

        It 'accepts <Name>' -ForEach @(
            @{ Name = 'Get-HDTWorkspace' }
            @{ Name = 'ConvertTo-HDTReport' }
            @{ Name = 'New-HDTBootIso' }
            @{ Name = 'Import-HDTBootImageToWds' }
            @{ Name = 'Get-HDTWin32Fact' }
        ) {
            Test-HDTFunctionName -Name $Name | Should -BeTrue
        }
    }

    Context 'invalid names' {

        It 'rejects <Because>' -ForEach @(
            @{ Name = 'Get-Thing'; Because = 'an unprefixed name (Get-Thing)' }
            @{ Name = 'Get-HdtThing'; Because = 'lowercase hdt (Get-HdtThing)' }
            @{ Name = 'Get-hdtThing'; Because = 'lowercase hdt (Get-hdtThing)' }
            @{ Name = 'GetHDTThing'; Because = 'a missing hyphen (GetHDTThing)' }
            @{ Name = 'Frobnicate-HDTThing'; Because = 'a non-approved verb (Frobnicate-HDTThing)' }
            @{ Name = 'get-HDTThing'; Because = 'a lowercase verb (get-HDTThing)' }
            @{ Name = 'Get-HDT'; Because = 'an empty noun (Get-HDT)' }
            @{ Name = 'Get-HDTthing'; Because = 'a lowercase first noun letter (Get-HDTthing)' }
            @{ Name = ''; Because = 'an empty string' }
        ) {
            Test-HDTFunctionName -Name $Name | Should -BeFalse
        }

        It 'rejects $null' {
            Test-HDTFunctionName -Name $null | Should -BeFalse
        }
    }

    It 'returns a plain boolean' {
        Test-HDTFunctionName -Name 'Get-HDTWorkspace' | Should -BeOfType [bool]
        Test-HDTFunctionName -Name 'Get-Thing' | Should -BeOfType [bool]
    }
}

Describe 'Get-HDTFunctionNameViolation' {

    It 'returns nothing when every name is valid' {
        @(Get-HDTFunctionNameViolation -Name @('Get-HDTWorkspace', 'ConvertTo-HDTReport')).Count |
            Should -Be 0
    }

    It 'returns one violation per invalid name' {
        $name = @(Get-HDTSourceFunction -Path $script:badName | ForEach-Object { $_.Name })
        $name.Count | Should -Be 7
        @(Get-HDTFunctionNameViolation -Name $name).Count | Should -Be 7
    }

    It 'names the offending function in the violation' {
        $violation = @(Get-HDTFunctionNameViolation -Name @('Get-HDTWorkspace', 'Frobnicate-HDTThing'))
        $violation.Count | Should -Be 1
        $violation[0].Name | Should -BeExactly 'Frobnicate-HDTThing'
    }

    It 'explains why the name failed' {
        $verbViolation = @(Get-HDTFunctionNameViolation -Name 'Frobnicate-HDTThing')
        $verbViolation[0].Reason | Should -BeLike '*approved verb*'

        $prefixViolation = @(Get-HDTFunctionNameViolation -Name 'Get-HdtThing')
        $prefixViolation[0].Reason | Should -BeLike '*HDT*'
    }

    It 'preserves input order' {
        $violation = @(Get-HDTFunctionNameViolation -Name @('Get-Thing', 'Get-HDTWorkspace', 'GetHDTThing'))
        @($violation | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly 'Get-Thing,GetHDTThing'
    }

    It 'accepts names from the pipeline' {
        $violation = @(@('Get-Thing', 'Get-HDTWorkspace') | Get-HDTFunctionNameViolation)
        $violation.Count | Should -Be 1
        $violation[0].Name | Should -BeExactly 'Get-Thing'
    }
}
