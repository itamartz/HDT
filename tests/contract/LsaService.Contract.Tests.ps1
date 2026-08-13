# The ILsaService contract (PROJECT constraint 4, DESIGN 4.5.2, DESIGN 12.2.1).
#
# Three methods:
#
#   SetSecret(name, value)    store LSA private data
#   GetSecret(name)  -> string | $null
#   RemoveSecret(name)        idempotent
#
# DESIGN 4.5.2: "It is stored as an LSA secret, not registry cleartext. Winlogon
# reads DefaultPassword from LSA private data as well as from the registry; this
# is the mechanism Sysinternals' Autologon.exe uses." SPIKES.md S8 observed three
# real autologons driven by that secret alone, with no registry DefaultPassword
# anywhere - so this interface is load-bearing, not decorative.
#
# THE REAL ROW IS OPT-IN, AND THE SUITE NEVER WRITES AN LSA SECRET.
#
# Storing LSA private data needs elevation and changes machine state that no
# test has any business changing on a developer's box. So the real row runs only
# when BOTH conditions hold:
#
#   * the session is elevated, and
#   * $env:HDT_ALLOW_LSA_TEST -eq '1'
#
# and even then it does nothing but check the method surface and call GetSecret
# on a name that cannot exist. SetSecret and RemoveSecret are never called
# against real LSA by this suite, on anyone's machine, ever.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9). $IsWindows does not exist under Windows
# PowerShell 5.1, hence [System.Environment]::OSVersion.Platform.

$script:HDTElevated = $false
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    $script:HDTElevated = ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:HDTAllowLsa = ($env:HDT_ALLOW_LSA_TEST -eq '1')

if (-not ($script:HDTElevated -and $script:HDTAllowLsa)) {
    Write-Warning ("ILsaService: the real adapter row is skipped. It runs only when the session is elevated (currently {0}) AND `$env:HDT_ALLOW_LSA_TEST is '1' (currently '{1}'). Even then it only reads a name that does not exist - the suite never writes an LSA secret." -f $script:HDTElevated, $env:HDT_ALLOW_LSA_TEST)
}

$script:HDTImplementation = @(
    @{
        Name           = 'FakeLsaService'
        Factory        = { New-HDTFakeLsaService }
        JournalFactory = { param($Journal) New-HDTFakeLsaService -Journal $Journal }
        FullRow        = $true
        Skip           = $false
    }
    @{
        Name           = 'LsaService'
        Factory        = { New-HDTLsaService }
        JournalFactory = { param($Journal) New-HDTLsaService -Journal $Journal }
        FullRow        = $false
        Skip           = -not ($script:HDTElevated -and $script:HDTAllowLsa)
    }
)

Describe 'ILsaService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    # Read-only, and safe on a real machine: the method surface, and a GetSecret
    # for a name that cannot exist.
    Context 'read only' -Skip:$Skip {

        BeforeEach {
            $script:lsa = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Get-Member -MemberType Method does NOT list a ScriptMethod, and the
            # real adapter is a pscustomobject carrying ScriptMethod members.
            $method = @($script:lsa | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('SetSecret', 'GetSecret', 'RemoveSecret')) {
                $method | Should -Contain $name -Because "ILsaService requires $name"
            }
        }

        It 'names itself in ServiceName' {
            $script:lsa.ServiceName | Should -BeExactly 'LsaService'
        }

        It 'returns null for a secret that does not exist' {
            $name = 'HDT-NoSuchSecret-{0}' -f ([guid]::NewGuid().ToString('N'))

            $script:lsa.GetSecret($name) | Should -BeNullOrEmpty
        }

        It 'does not throw reading a secret that does not exist' {
            $name = 'HDT-NoSuchSecret-{0}' -f ([guid]::NewGuid().ToString('N'))

            { $script:lsa.GetSecret($name) } | Should -Not -Throw
        }

        It 'records the read' {
            $name = 'HDT-NoSuchSecret-{0}' -f ([guid]::NewGuid().ToString('N'))
            $script:lsa.GetSecret($name) | Out-Null

            @($script:lsa.GetOperationName()) | Should -Be @('GetSecret')
            @($script:lsa.Operations[0].Arguments)[0] | Should -BeExactly $name
        }
    }

    # Everything that writes. The real row never reaches here - FullRow is
    # $false for it - because storing an LSA secret on the machine running the
    # suite is not something a test gets to do.
    Context 'store and remove' -Skip:(-not $FullRow) {

        BeforeEach {
            $script:lsa = & $Factory $script:repoRoot
        }

        It 'round-trips a secret' {
            $script:lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')

            $script:lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
        }

        It 'overwrites a secret' {
            $script:lsa.SetSecret('DefaultPassword', 'first')
            $script:lsa.SetSecret('DefaultPassword', 'second')

            $script:lsa.GetSecret('DefaultPassword') | Should -BeExactly 'second'
        }

        It 'removes a secret' {
            $script:lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')
            $script:lsa.RemoveSecret('DefaultPassword')

            $script:lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'removes a secret that is absent without error' {
            { $script:lsa.RemoveSecret('HDT-NoSuchSecret') } | Should -Not -Throw
        }

        It 'records every operation' {
            $script:lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')
            $script:lsa.GetSecret('DefaultPassword') | Out-Null
            $script:lsa.RemoveSecret('DefaultPassword')

            @($script:lsa.GetOperationName()) | Should -Be @('SetSecret', 'GetSecret', 'RemoveSecret')
        }

        It 'never records a secret value' {
            # $Operations is printed verbatim in a Pester failure message.
            $script:lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')

            ($script:lsa.Operations | Out-String) | Should -Not -Match 'Sw0rdfish'
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $lsa = & $JournalFactory $journal
            $lsa.SetSecret('DefaultPassword', 'Sw0rdfish!')
            $lsa.RemoveSecret('DefaultPassword')

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('LsaService.SetSecret', 'LsaService.RemoveSecret')
        }
    }
}
