# Behaviour that belongs to the fake itself rather than to the
# IEnvironmentProvider contract: seeding, lookup recording, and the guarantee
# that no lookup reaches the real process environment.
#
# The fake is only ever obtained through New-HDTFakeEnvironmentProvider. The
# class name is never written as a type literal here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakeEnvironmentProvider' {

    It 'returns null for every variable when given no seed' {
        $environment = New-HDTFakeEnvironmentProvider

        $environment.GetVariable('firmware_type') | Should -BeNullOrEmpty
        $environment.GetVariable('PROCESSOR_ARCHITECTURE') | Should -BeNullOrEmpty
    }

    It 'seeds variables from -Variable' {
        $environment = New-HDTFakeEnvironmentProvider -Variable @{
            firmware_type          = 'UEFI'
            PROCESSOR_ARCHITECTURE = 'AMD64'
        }

        $environment.GetVariable('firmware_type') | Should -BeExactly 'UEFI'
        $environment.GetVariable('PROCESSOR_ARCHITECTURE') | Should -BeExactly 'AMD64'
    }

    It 'looks a variable up case-insensitively' {
        # Windows environment variables are case-insensitive, and DESIGN 3.2.1
        # reads firmware_type in lower case while everything else is upper.
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'UEFI' }

        $environment.GetVariable('FIRMWARE_TYPE') | Should -BeExactly 'UEFI'
    }

    It 'records each lookup in Operations' {
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'UEFI' }
        $environment.GetVariable('firmware_type') | Out-Null
        $environment.GetVariable('HDT_NO_SUCH_VARIABLE') | Out-Null

        @($environment.Operations).Count | Should -Be 2
        $environment.GetOperationName() | Should -Be @('GetVariable', 'GetVariable')
    }

    It 'records the variable name of each lookup' {
        $environment = New-HDTFakeEnvironmentProvider
        $environment.GetVariable('firmware_type') | Out-Null

        @($environment.Operations[0].Arguments) | Should -Be @('firmware_type')
    }

    It 'does not record seeding as an operation' {
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'UEFI' }

        @($environment.Operations).Count | Should -Be 0
    }

    It 'never reads the real environment' {
        # PROCESSOR_ARCHITECTURE is set on this machine. An unseeded fake must
        # still report it unset rather than quietly returning live data.
        $environment = New-HDTFakeEnvironmentProvider

        $environment.GetVariable('PROCESSOR_ARCHITECTURE') | Should -BeNullOrEmpty
        [System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') | Should -Not -BeNullOrEmpty
    }

    It 'is independent between instances' {
        $first = New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'UEFI' }
        $second = New-HDTFakeEnvironmentProvider

        $first.GetVariable('firmware_type') | Should -BeExactly 'UEFI'
        $second.GetVariable('firmware_type') | Should -BeNullOrEmpty
    }
}
