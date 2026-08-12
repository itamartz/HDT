# Behaviour that belongs to the fake itself rather than to the IRegistryService
# contract: seeding, path normalisation, call recording, and the guarantee that
# no read reaches the real registry.
#
# The fake is only ever obtained through New-HDTFakeRegistryService. The class
# name is never written as a type literal here: a type literal binds to whichever
# dynamic assembly loaded first and breaks across a module reload.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:secureBootPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
    $script:realKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
}

Describe 'New-HDTFakeRegistryService' {

    It 'starts with no keys' {
        $registry = New-HDTFakeRegistryService

        $registry.TestPath($script:secureBootPath) | Should -BeFalse
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Should -BeNullOrEmpty
    }

    It 'seeds keys and values from -Value' {
        $registry = New-HDTFakeRegistryService -Value @{
            $script:secureBootPath = @{ UEFISecureBootEnabled = 1 }
        }

        $registry.TestPath($script:secureBootPath) | Should -BeTrue
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Should -Be 1
    }

    It 'seeds a key with no values' {
        # "The key exists but the value is absent" is a different fact from "no
        # such key", and a fact gatherer has to tell them apart.
        $registry = New-HDTFakeRegistryService -Value @{ $script:secureBootPath = @{} }

        $registry.TestPath($script:secureBootPath) | Should -BeTrue
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Should -BeNullOrEmpty
    }

    It 'accepts SetValue after construction' {
        $registry = New-HDTFakeRegistryService
        $registry.SetValue($script:secureBootPath, 'UEFISecureBootEnabled', 0)

        $registry.TestPath($script:secureBootPath) | Should -BeTrue
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Should -Be 0
    }

    It 'looks a value name up case-insensitively' {
        $registry = New-HDTFakeRegistryService -Value @{
            $script:secureBootPath = @{ UEFISecureBootEnabled = 1 }
        }

        $registry.GetValue($script:secureBootPath, 'uefisecurebootenabled') | Should -Be 1
    }

    It 'treats HKEY_LOCAL_MACHINE as a synonym for HKLM:' {
        $registry = New-HDTFakeRegistryService -Value @{
            'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
        }

        $registry.TestPath($script:secureBootPath) | Should -BeTrue
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Should -Be 1
    }

    It 'does not record seeding as an operation' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:secureBootPath = @{ UEFISecureBootEnabled = 1 } }
        $registry.SetValue($script:secureBootPath, 'Other', 2)

        @($registry.Operations).Count | Should -Be 0
    }

    It 'returns operation names in order from GetOperationName' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:secureBootPath = @{ UEFISecureBootEnabled = 1 } }
        $registry.TestPath($script:secureBootPath) | Out-Null
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Out-Null
        $registry.TestPath('HKLM:\SOFTWARE\HDTNoSuchKey') | Out-Null

        $registry.GetOperationName() | Should -Be @('TestPath', 'GetValue', 'TestPath')
    }

    It 'records the path and name of each call' {
        $registry = New-HDTFakeRegistryService
        $registry.GetValue($script:secureBootPath, 'UEFISecureBootEnabled') | Out-Null

        @($registry.Operations[0].Arguments) | Should -Be @($script:secureBootPath, 'UEFISecureBootEnabled')
    }

    It 'never reads the real registry' {
        # HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion certainly exists on
        # this machine. An unseeded fake must still report it absent rather than
        # quietly returning live data.
        $registry = New-HDTFakeRegistryService

        $registry.TestPath($script:realKey) | Should -BeFalse
        $registry.GetValue($script:realKey, 'ProductName') | Should -BeNullOrEmpty
    }

    It 'is independent between instances' {
        $first = New-HDTFakeRegistryService -Value @{ $script:secureBootPath = @{ UEFISecureBootEnabled = 1 } }
        $second = New-HDTFakeRegistryService

        $first.TestPath($script:secureBootPath) | Should -BeTrue
        $second.TestPath($script:secureBootPath) | Should -BeFalse
    }
}
