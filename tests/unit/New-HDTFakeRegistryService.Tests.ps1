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

    It 'accepts SeedValue after construction' {
        $registry = New-HDTFakeRegistryService
        $registry.SeedValue($script:secureBootPath, 'UEFISecureBootEnabled', 0)

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
        $registry.SeedValue($script:secureBootPath, 'Other', 2)

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

# The write half, added in 03-03 for the autologon lifecycle of DESIGN 4.5.
#
# Four methods, all recorded, because the arming and teardown tests assert on
# what was written and in what order:
#
#   NewKey(path)                          idempotent
#   SetValue(path, name, value, type)     creates the key implicitly
#   RemoveValue(path, name)               idempotent
#   RemoveKey(path, recurse)              idempotent
#
# Removing something that is not there is deliberately not an error. Teardown
# runs on machines in unknown states, and a teardown that throws on the first
# absent value is a teardown that does not finish (DESIGN 4.5.3).
Describe 'New-HDTFakeRegistryService write half' {

    BeforeEach {
        $script:winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    }

    Context 'NewKey' {

        It 'creates a key that did not exist' {
            $registry = New-HDTFakeRegistryService
            $registry.NewKey($script:winlogon)

            $registry.TestPath($script:winlogon) | Should -BeTrue
        }

        It 'is idempotent for a key that exists' {
            $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{ AutoAdminLogon = '1' } }
            { $registry.NewKey($script:winlogon) } | Should -Not -Throw

            $registry.GetValue($script:winlogon, 'AutoAdminLogon') | Should -Be '1'
        }
    }

    Context 'SetValue' {

        It 'sets a value' {
            $registry = New-HDTFakeRegistryService
            $registry.SetValue($script:winlogon, 'DefaultUserName', 'Administrator', 'String')

            $registry.GetValue($script:winlogon, 'DefaultUserName') | Should -Be 'Administrator'
        }

        It 'overwrites an existing value' {
            $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{ AutoLogonCount = 3 } }
            $registry.SetValue($script:winlogon, 'AutoLogonCount', 2, 'DWord')

            $registry.GetValue($script:winlogon, 'AutoLogonCount') | Should -Be 2
        }

        It 'creates the key implicitly when setting a value' {
            # New-ItemProperty fails on a key that does not exist, so the real
            # adapter creates it first. The fake must not be more forgiving.
            $registry = New-HDTFakeRegistryService
            $registry.SetValue('HKLM:\SOFTWARE\HDT\Deep\Deeper', 'Leg', 1, 'DWord')

            $registry.TestPath('HKLM:\SOFTWARE\HDT\Deep\Deeper') | Should -BeTrue
        }

        It 'stores the value type' {
            # So a test can prove AutoLogonCount was written as a DWord rather
            # than as the string '3', which Winlogon would ignore.
            $registry = New-HDTFakeRegistryService
            $registry.SetValue($script:winlogon, 'AutoLogonCount', 3, 'DWord')
            $registry.SetValue($script:winlogon, 'AutoAdminLogon', '1', 'String')

            $registry.GetValueType($script:winlogon, 'AutoLogonCount') | Should -BeExactly 'DWord'
            $registry.GetValueType($script:winlogon, 'AutoAdminLogon') | Should -BeExactly 'String'
        }

        It 'returns null for the type of a value that is not there' {
            $registry = New-HDTFakeRegistryService

            $registry.GetValueType($script:winlogon, 'AutoLogonCount') | Should -BeNullOrEmpty
        }

        It 'rejects a value type the registry does not have' {
            # Fake-only strictness: New-ItemProperty -PropertyType would only
            # fail on a real machine, which is too late.
            $registry = New-HDTFakeRegistryService

            { $registry.SetValue($script:winlogon, 'AutoLogonCount', 3, 'Integer') } |
                Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }

    Context 'RemoveValue' {

        It 'removes a value' {
            $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{ AutoAdminLogon = '1'; DefaultUserName = 'Administrator' } }
            $registry.RemoveValue($script:winlogon, 'AutoAdminLogon')

            $registry.GetValue($script:winlogon, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $registry.GetValue($script:winlogon, 'DefaultUserName') | Should -Be 'Administrator'
        }

        It 'does not throw removing a value that is absent' {
            $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{} }

            { $registry.RemoveValue($script:winlogon, 'AutoAdminLogon') } | Should -Not -Throw
        }

        It 'does not throw removing a value in a key that is absent' {
            $registry = New-HDTFakeRegistryService

            { $registry.RemoveValue($script:winlogon, 'AutoAdminLogon') } | Should -Not -Throw
        }
    }

    Context 'RemoveKey' {

        It 'removes a key' {
            $registry = New-HDTFakeRegistryService -Value @{ 'HKLM:\SOFTWARE\HDT' = @{ Leg = 1 } }
            $registry.RemoveKey('HKLM:\SOFTWARE\HDT', $false)

            $registry.TestPath('HKLM:\SOFTWARE\HDT') | Should -BeFalse
        }

        It 'removes child keys with -Recurse' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\HDT'       = @{ Leg = 1 }
                'HKLM:\SOFTWARE\HDT\Child' = @{ Leg = 2 }
            }
            $registry.RemoveKey('HKLM:\SOFTWARE\HDT', $true)

            $registry.TestPath('HKLM:\SOFTWARE\HDT') | Should -BeFalse
            $registry.TestPath('HKLM:\SOFTWARE\HDT\Child') | Should -BeFalse
        }

        It 'throws removing a non-empty key without -Recurse' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\HDT'       = @{}
                'HKLM:\SOFTWARE\HDT\Child' = @{}
            }

            { $registry.RemoveKey('HKLM:\SOFTWARE\HDT', $false) } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }

        It 'does not throw removing a key that is absent' {
            $registry = New-HDTFakeRegistryService

            { $registry.RemoveKey('HKLM:\SOFTWARE\HDT', $false) } | Should -Not -Throw
        }
    }

    Context 'recording' {

        It 'records NewKey, SetValue, RemoveValue and RemoveKey' {
            $registry = New-HDTFakeRegistryService
            $registry.NewKey($script:winlogon)
            $registry.SetValue($script:winlogon, 'AutoAdminLogon', '1', 'String')
            $registry.RemoveValue($script:winlogon, 'AutoAdminLogon')
            $registry.RemoveKey($script:winlogon, $false)

            $registry.GetOperationName() | Should -Be @('NewKey', 'SetValue', 'RemoveValue', 'RemoveKey')
        }

        It 'records the arguments of a write in declaration order' {
            $registry = New-HDTFakeRegistryService
            $registry.SetValue($script:winlogon, 'AutoLogonCount', 3, 'DWord')

            @($registry.Operations[0].Arguments) | Should -Be @($script:winlogon, 'AutoLogonCount', 3, 'DWord')
        }

        It 'does not record SeedValue or SeedKey' {
            $registry = New-HDTFakeRegistryService
            $registry.SeedKey($script:winlogon)
            $registry.SeedValue($script:winlogon, 'AutoAdminLogon', '1')

            @($registry.Operations).Count | Should -Be 0
        }

        It 'does not record GetValueType' {
            # An inspection helper for assertions, not part of IRegistryService.
            $registry = New-HDTFakeRegistryService
            $registry.SeedValue($script:winlogon, 'AutoAdminLogon', '1')
            $registry.GetValueType($script:winlogon, 'AutoAdminLogon') | Out-Null

            @($registry.Operations).Count | Should -Be 0
        }

        It 'appends writes to the shared journal' {
            $journal = [System.Collections.ArrayList]::new()
            $registry = New-HDTFakeRegistryService -Journal $journal
            $registry.SetValue($script:winlogon, 'AutoAdminLogon', '1', 'String')

            @($journal).Count | Should -Be 1
            $journal[0].Service | Should -BeExactly 'RegistryService'
            $journal[0].Operation | Should -BeExactly 'SetValue'
        }
    }

    It 'never touches the real registry' {
        # HKLM:\SOFTWARE\HDT-does-not-exist must still not exist afterwards.
        $registry = New-HDTFakeRegistryService
        $registry.NewKey('HKLM:\SOFTWARE\HDT-does-not-exist')
        $registry.SetValue('HKLM:\SOFTWARE\HDT-does-not-exist', 'Proof', '1', 'String')

        $registry.TestPath('HKLM:\SOFTWARE\HDT-does-not-exist') | Should -BeTrue
        Test-Path -LiteralPath 'HKLM:\SOFTWARE\HDT-does-not-exist' | Should -BeFalse
    }
}
