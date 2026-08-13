# The IRegistryService contract, read subset (PROJECT constraint 4, DESIGN
# 3.2.1, DESIGN 12.2.1).
#
# Every implementation - the hand-written fake, the real Get-ItemProperty adapter
# - must pass this file unchanged. Adding an implementation is a one-row change
# to $script:HDTImplementation below, not a new test file.
#
# SCOPE, and why the method names are what they are: this is the READ subset,
# which is all fact gathering needs (the SecureBoot state key). Phase 03 extends
# the SAME interface with the write half for the autologon lifecycle in DESIGN
# 4.5 - SetValue as a recorded operation, RemoveValue, RemoveKey. TestPath and
# GetValue are named so that extension is additive: nothing here has to be
# renamed when the writes arrive.
#
# Absence is normal, not exceptional. A BIOS machine has no
# SecureBoot\State key at all, so GetValue returns $null for a missing key or a
# missing name and never throws. A fact gatherer that had to catch would be a
# fact gatherer that swallows real errors too.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.

# The skip goes on a Context INSIDE the Describe, never on the Describe itself.
# Verified against Pester 5.7.1: -Skip: on a -ForEach Describe is bound where
# Describe is called, before -ForEach binds the row's keys, so $Skip is unset
# there and every row runs regardless. $IsWindows does not exist under Windows
# PowerShell 5.1, hence [System.Environment]::OSVersion.Platform.
# WHERE THE WRITE HALF WRITES, and why it is not negotiable: the real row writes
# ONLY under HKCU:\Software\HDT-Contract-Test-<guid>, a key it creates and
# removes in AfterAll. HKLM is never written by this suite. A contract test that
# needed elevation would be a contract test that gets skipped, and a contract
# test that wrote to HKLM would be one nobody dares run on their own machine.
$script:HDTWriteRoot = 'HKCU:\Software\HDT-Contract-Test-{0}' -f ([guid]::NewGuid().ToString('N'))

$script:HDTImplementation = @(
    @{
        Name         = 'FakeRegistryService'
        Factory      = { New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' = @{ ProductName = 'FixtureOS' }
            } }
        JournalFactory = { param($Journal) New-HDTFakeRegistryService -Journal $Journal }
        KnownPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName    = 'ProductName'
        MissingPath  = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        WriteRoot    = $script:HDTWriteRoot
        Skip         = $false
    }
    @{
        Name         = 'RegistryService'
        Factory      = { New-HDTRegistryService }
        JournalFactory = { param($Journal) New-HDTRegistryService -Journal $Journal }
        KnownPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName    = 'ProductName'
        MissingPath  = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        WriteRoot    = $script:HDTWriteRoot
        Skip         = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }
)

Describe 'IRegistryService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:registry = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapters are pscustomobjects carrying
            # ScriptMethod members. Do not "tidy" ScriptMethod away.
            $method = @($script:registry | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('TestPath', 'GetValue', 'NewKey', 'SetValue', 'RemoveValue', 'RemoveKey')) {
                $method | Should -Contain $name -Because "IRegistryService requires $name"
            }
        }

        It 'reports a key that exists' {
            $script:registry.TestPath($KnownPath) | Should -BeTrue
        }

        It 'reports a key that does not exist' {
            $script:registry.TestPath($MissingPath) | Should -BeFalse
        }

        It 'returns the value of a name that exists' {
            $script:registry.GetValue($KnownPath, $KnownName) | Should -Not -BeNullOrEmpty
        }

        It 'returns null for a name that does not exist under an existing key' {
            $script:registry.GetValue($KnownPath, 'HDTNoSuchValueName') | Should -BeNullOrEmpty
        }

        It 'returns null for a name under a key that does not exist' {
            $script:registry.GetValue($MissingPath, 'HDTNoSuchValueName') | Should -BeNullOrEmpty
        }

        It 'does not throw for a missing key' {
            # A BIOS machine genuinely has no SecureBoot\State key. Absence is a
            # fact, not a failure.
            { $script:registry.GetValue($MissingPath, 'UEFISecureBootEnabled') } | Should -Not -Throw
            { $script:registry.TestPath($MissingPath) } | Should -Not -Throw
        }

        It 'treats HKEY_LOCAL_MACHINE as a synonym for HKLM:' {
            $long = $KnownPath -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'

            $script:registry.TestPath($long) | Should -BeTrue
            $script:registry.GetValue($long, $KnownName) |
                Should -Be $script:registry.GetValue($KnownPath, $KnownName)
        }

        It 'records each call in Operations' {
            $script:registry.TestPath($KnownPath) | Out-Null
            $script:registry.GetValue($KnownPath, $KnownName) | Out-Null

            @($script:registry.Operations).Count | Should -Be 2
            @($script:registry.GetOperationName()) | Should -Be @('TestPath', 'GetValue')
        }

        It 'records a call that returned null' {
            # Provenance needs the attempt, not only the successes.
            $script:registry.GetValue($MissingPath, 'UEFISecureBootEnabled') | Out-Null

            @($script:registry.Operations).Count | Should -Be 1
            @($script:registry.Operations[0].Arguments)[0] | Should -Be $MissingPath
        }
    }

    # The write half (03-03), for the autologon lifecycle of DESIGN 4.5.
    Context 'write half' -Skip:$Skip {

        BeforeEach {
            $script:registry = & $Factory $script:repoRoot
            $script:key = '{0}\{1}' -f $WriteRoot, ([guid]::NewGuid().ToString('N'))
        }

        AfterAll {
            # Only ever removes the suite's own HKCU scratch root. The fake row
            # never created it, so this is a no-op there.
            Remove-Item -LiteralPath $WriteRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'creates a key that did not exist' {
            $script:registry.TestPath($script:key) | Should -BeFalse
            $script:registry.NewKey($script:key)

            $script:registry.TestPath($script:key) | Should -BeTrue
        }

        It 'creates a key idempotently' {
            $script:registry.NewKey($script:key)

            { $script:registry.NewKey($script:key) } | Should -Not -Throw
        }

        It 'round-trips a string value' {
            $script:registry.SetValue($script:key, 'DefaultUserName', 'Administrator', 'String')

            $script:registry.GetValue($script:key, 'DefaultUserName') | Should -BeExactly 'Administrator'
        }

        It 'round-trips a dword value' {
            # AutoLogonCount is a DWord. Winlogon ignores the string '3'.
            $script:registry.SetValue($script:key, 'AutoLogonCount', 3, 'DWord')

            $script:registry.GetValue($script:key, 'AutoLogonCount') | Should -Be 3
        }

        It 'creates the key implicitly when setting a value' {
            # New-ItemProperty fails on a key that does not exist.
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')

            $script:registry.TestPath($script:key) | Should -BeTrue
        }

        It 'overwrites an existing value' {
            $script:registry.SetValue($script:key, 'AutoLogonCount', 3, 'DWord')
            $script:registry.SetValue($script:key, 'AutoLogonCount', 2, 'DWord')

            $script:registry.GetValue($script:key, 'AutoLogonCount') | Should -Be 2
        }

        It 'reports a missing value as null' {
            $script:registry.NewKey($script:key)

            $script:registry.GetValue($script:key, 'AutoAdminLogon') | Should -BeNullOrEmpty
        }

        It 'removes a value' {
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveValue($script:key, 'AutoAdminLogon')

            $script:registry.GetValue($script:key, 'AutoAdminLogon') | Should -BeNullOrEmpty
        }

        It 'removes a value without error when it is absent' {
            # DESIGN 4.5.3 teardown runs on machines in unknown states. A
            # teardown that throws on the first absent value does not finish.
            $script:registry.NewKey($script:key)

            { $script:registry.RemoveValue($script:key, 'AutoAdminLogon') } | Should -Not -Throw
        }

        It 'removes a value without error when the key is absent' {
            { $script:registry.RemoveValue($script:key, 'AutoAdminLogon') } | Should -Not -Throw
        }

        It 'removes a key' {
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveKey($script:key, $false)

            $script:registry.TestPath($script:key) | Should -BeFalse
        }

        It 'removes a key and its children with recurse' {
            $child = '{0}\Child' -f $script:key
            $script:registry.SetValue($child, 'Leg', 1, 'DWord')
            $script:registry.RemoveKey($script:key, $true)

            $script:registry.TestPath($script:key) | Should -BeFalse
            $script:registry.TestPath($child) | Should -BeFalse
        }

        It 'removes a key without error when it is absent' {
            { $script:registry.RemoveKey($script:key, $false) } | Should -Not -Throw
        }

        It 'records every write' {
            $script:registry.NewKey($script:key)
            $script:registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $script:registry.RemoveValue($script:key, 'AutoAdminLogon')
            $script:registry.RemoveKey($script:key, $false)

            @($script:registry.GetOperationName()) | Should -Be @('NewKey', 'SetValue', 'RemoveValue', 'RemoveKey')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $registry = & $JournalFactory $journal
            $registry.SetValue($script:key, 'AutoAdminLogon', '1', 'String')
            $registry.RemoveKey($script:key, $false)

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('RegistryService.SetValue', 'RegistryService.RemoveKey')
        }

        It 'names itself in ServiceName' {
            $script:registry.ServiceName | Should -BeExactly 'RegistryService'
        }
    }
}
