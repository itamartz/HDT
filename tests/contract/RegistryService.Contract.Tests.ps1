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
$script:HDTImplementation = @(
    @{
        Name        = 'FakeRegistryService'
        Factory     = { New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' = @{ ProductName = 'FixtureOS' }
            } }
        KnownPath   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName   = 'ProductName'
        MissingPath = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        Skip        = $false
    }
    @{
        Name        = 'RegistryService'
        Factory     = { New-HDTRegistryService }
        KnownPath   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        KnownName   = 'ProductName'
        MissingPath = 'HKLM:\SOFTWARE\HDTNoSuchKey'
        Skip        = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
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

            foreach ($name in @('TestPath', 'GetValue')) {
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
}
