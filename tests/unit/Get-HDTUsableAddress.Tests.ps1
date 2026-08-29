# "HAVE I GOT AN ADDRESS I CAN REACH A SHARE FROM?"
#
# FOUND ON A LIVE MACHINE, FROM THE LOG. A VM in WinPE printed
#
#     waiting for an address, attempt 1: '192.168.2.39' 'fe80::7796:...'
#     ...
#     waiting for an address, attempt 7: '192.168.2.39' ...
#
# while holding 192.168.2.39 the entire time. The payload did this:
#
#     foreach ($candidate in (([string] $fact['HDTIPAddress']) -split ','))
#
# and HDTIPAddress is a [string[]] (Get-HDTMachineFact). Casting an array to a
# string SPACE-joins it, so the comma split returned ONE element -
# '192.168.2.39 fe80::7796:...' - which never matches an IPv4 pattern. The
# machine waited the whole timeout for an address it already had, then warned
# and connected anyway.
#
# IT WAS INLINE IN THE PAYLOAD, WHICH IS WHY NOTHING CAUGHT IT. The payload is
# asserted by an AST test that reads its shape, not by running it; a decision
# with a bug in it has to be a command before a test can find the bug.
#
# APIPA IS NOT AN ADDRESS. 169.254.* is exactly the case where a machine looks
# connected and can reach nothing (SPIKES S9.2).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTUsableAddress' {

    Context 'the command exists' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTUsableAddress' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'the shape Get-HDTMachineFact actually produces' {

        It 'reads a string array, which is what HDTIPAddress is' {
            # THE REGRESSION. This exact value was on a machine that waited two
            # minutes for it.
            $fact = @{ HDTIPAddress = [string[]] @('192.168.2.39', 'fe80::7796:8b0d:3eb5:8610') }

            Get-HDTUsableAddress -Fact $fact | Should -BeExactly '192.168.2.39'
        }

        It 'takes the first usable one when a machine has several' {
            $fact = @{ HDTIPAddress = [string[]] @('10.0.0.5', '192.168.2.39') }

            Get-HDTUsableAddress -Fact $fact | Should -BeExactly '10.0.0.5'
        }

        It 'still reads a single string' {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = '192.168.2.39' } | Should -BeExactly '192.168.2.39'
        }

        It 'still reads a comma-joined string, because a fact set can arrive either way' {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = '192.168.2.39,fe80::1' } | Should -BeExactly '192.168.2.39'
        }

        It 'reads a space-joined string, which is what the cast that caused this produces' {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = '192.168.2.39 fe80::7796:8b0d:3eb5:8610' } |
                Should -BeExactly '192.168.2.39'
        }
    }

    Context 'what is not an address' {

        It 'refuses APIPA, which looks connected and reaches nothing' {
            # SPIKES S9.2 saw 169.254.* on the isolated lab switch.
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = [string[]] @('169.254.11.22') } | Should -BeNullOrEmpty
        }

        It 'takes the real one when APIPA is listed beside it' {
            $fact = @{ HDTIPAddress = [string[]] @('169.254.11.22', '192.168.2.39') }

            Get-HDTUsableAddress -Fact $fact | Should -BeExactly '192.168.2.39'
        }

        It 'refuses IPv6 on its own, because the share is reached over IPv4 here' {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = [string[]] @('fe80::7796:8b0d:3eb5:8610') } |
                Should -BeNullOrEmpty
        }

        It 'refuses <_>' -ForEach @('', '   ', '0.0.0.0', 'not an address', '192.168.2') {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = [string[]] @($PSItem) } | Should -BeNullOrEmpty
        }

        It 'survives a fact set with no address at all' {
            Get-HDTUsableAddress -Fact @{} | Should -BeNullOrEmpty
        }

        It 'survives a null fact set' {
            Get-HDTUsableAddress -Fact $null | Should -BeNullOrEmpty
        }

        It 'survives a null address' {
            Get-HDTUsableAddress -Fact @{ HDTIPAddress = $null } | Should -BeNullOrEmpty
        }
    }

    Context 'against what Get-HDTMachineFact really produces' {

        # A HAND-WRITTEN HASHTABLE IS NOT THE FACT TABLE. Every assertion above
        # states a shape this command should accept; this one gathers the fact
        # through the real command from a captured multi-homed machine - nine IP
        # enabled adapters, twenty-seven addresses - and asks the same question.
        # The incident was a reader and a producer disagreeing about a type, and
        # only running both can catch that.

        BeforeAll {
            $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
            $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'

            Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

            $instance = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
                $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
            }

            $cim = New-HDTFakeCimProvider -Instance $instance `
                -NamespaceFixturePath @{ 'root/cimv2/security/microsofttpm' = $script:tpmFixturePath }

            $script:gathered = Get-HDTMachineFact -CimProvider $cim `
                -RegistryService (New-HDTFakeRegistryService) `
                -EnvironmentProvider (New-HDTFakeEnvironmentProvider)
        }

        It 'is reading a machine with more than one address' {
            @($script:gathered['HDTIPAddress']).Count | Should -BeGreaterThan 1
        }

        It 'finds the first IPv4 address of a multi-homed machine' {
            $expected = @(@($script:gathered['HDTIPAddress']) |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and -not $_.StartsWith('169.254.') })[0]

            Get-HDTUsableAddress -Fact $script:gathered | Should -BeExactly $expected
        }

        It 'skips the IPv6 addresses interleaved between them' {
            Get-HDTUsableAddress -Fact $script:gathered | Should -Not -Match ':'
        }
    }
}
