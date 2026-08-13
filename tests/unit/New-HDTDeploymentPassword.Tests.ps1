# The per-deployment Administrator password (DESIGN 4.5.2, ROADMAP M2).
#
# "The Administrator password used during deployment is generated at run start
# (high entropy, stored only in the state document on the machine being built),
# not a fixed corporate password reused across the fleet. If it leaks it is worth
# one machine, mid-build."
#
# Three properties this file exists to pin down:
#
#   1. It is different on every run. That is the whole point.
#   2. It survives being handled. The alphabet excludes every character that
#      breaks unattend.xml, a command line, or %Var% expansion.
#   3. It is drawn from a CSPRNG with rejection sampling, never Get-Random and
#      never byte % length. RandomNumberGenerator::GetInt32 does not exist under
#      Windows PowerShell 5.1 (it is .NET Core only), which is the other reason
#      the mapping is written out by hand.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:sourcePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTDeploymentPassword.ps1'

    # A long, fixed byte stream: long enough that neither a 24 nor a 127
    # character password exhausts it, so the fake never has to wrap.
    $script:stream = [byte[]] @(0..255 + 0..255 + 0..255)
}

Describe 'New-HDTDeploymentPassword' {

    Context 'length' {

        It 'returns a string of the requested length' {
            (New-HDTDeploymentPassword -Length 32).Length | Should -Be 32
        }

        It 'defaults to 24 characters' {
            (New-HDTDeploymentPassword).Length | Should -Be 24
        }

        It 'rejects a length below 16' {
            { New-HDTDeploymentPassword -Length 15 } | Should -Throw
        }

        It 'rejects a length above 127' {
            { New-HDTDeploymentPassword -Length 128 } | Should -Throw
        }

        It 'accepts the boundaries' {
            (New-HDTDeploymentPassword -Length 16).Length | Should -Be 16
            (New-HDTDeploymentPassword -Length 127).Length | Should -Be 127
        }
    }

    Context 'complexity, over 50 generated passwords' {

        # A class that is merely likely is not a class that is guaranteed. Fifty
        # samples of each, so a generator that satisfies Windows complexity by
        # chance rather than by construction goes red.
        It 'contains an upper case letter (sample <_>)' -ForEach (1..50) {
            New-HDTDeploymentPassword | Should -Match '[A-Z]'
        }

        It 'contains a lower case letter (sample <_>)' -ForEach (1..50) {
            New-HDTDeploymentPassword | Should -Match '[a-z]'
        }

        It 'contains a digit (sample <_>)' -ForEach (1..50) {
            New-HDTDeploymentPassword | Should -Match '[0-9]'
        }

        It 'contains a symbol (sample <_>)' -ForEach (1..50) {
            New-HDTDeploymentPassword | Should -Match '[!#$*+\-=?@_]'
        }
    }

    Context 'the alphabet' {

        It 'contains no character outside the alphabet (sample <_>)' -ForEach (1..50) {
            New-HDTDeploymentPassword -Length 40 | Should -Match '^[A-Za-z0-9!#$*+\-=?@_]+$'
        }

        It 'contains no character that breaks XML or a command line' {
            # & < > " ' break unattend.xml; % breaks %Var% expansion; ^ | \ / and
            # space break a command line. A password that cannot survive being
            # handled is worse than a shorter one.
            $forbidden = @('&', '<', '>', '"', "'", '%', '^', '|', '\', '/', ' ')

            foreach ($sample in 1..50) {
                $password = New-HDTDeploymentPassword -Length 64
                foreach ($character in $forbidden) {
                    $password.Contains($character) | Should -BeFalse -Because "'$character' breaks unattend.xml, a command line or %Var% expansion"
                }
            }
        }
    }

    Context 'uniqueness' {

        It 'is different on every run' {
            # ROADMAP M2: "the password is different on every run".
            $password = 1..200 | ForEach-Object { New-HDTDeploymentPassword }

            @($password | Sort-Object -Unique).Count | Should -Be 200
        }
    }

    Context 'the random number generator' {

        It 'draws from the injected random number generator' {
            $rng = New-HDTFakeRandomNumberGenerator -Byte $script:stream
            New-HDTDeploymentPassword -RandomNumberGenerator $rng | Out-Null

            @($rng.Operations).Count | Should -BeGreaterThan 0
            $rng.GetOperationName() | Should -Contain 'GetBytes'
        }

        It 'is deterministic for a deterministic generator' {
            $first = New-HDTDeploymentPassword -RandomNumberGenerator (New-HDTFakeRandomNumberGenerator -Byte $script:stream)
            $second = New-HDTDeploymentPassword -RandomNumberGenerator (New-HDTFakeRandomNumberGenerator -Byte $script:stream)

            $first | Should -BeExactly $second
        }

        It 'rejects a byte that would bias the alphabet' {
            # The alphabet is 72 characters, so the largest usable multiple is
            # 216 and bytes 216..255 must be DISCARDED and redrawn. A generator
            # that folded them with byte % length would bias the low end of the
            # alphabet - and would also produce a different password here,
            # because the leading rejected byte would be consumed rather than
            # skipped.
            $rejected = [byte[]] (@(255, 254, 253, 252) + $script:stream)

            $withRejects = New-HDTDeploymentPassword -RandomNumberGenerator (New-HDTFakeRandomNumberGenerator -Byte $rejected)
            $without = New-HDTDeploymentPassword -RandomNumberGenerator (New-HDTFakeRandomNumberGenerator -Byte $script:stream)

            $withRejects | Should -BeExactly $without
        }

        It 'asks for one byte at a time' {
            # Rejection sampling only works if a rejected byte costs one byte.
            $rng = New-HDTFakeRandomNumberGenerator -Byte $script:stream
            New-HDTDeploymentPassword -RandomNumberGenerator $rng | Out-Null

            @($rng.Operations | ForEach-Object { $_.Arguments[0] } | Sort-Object -Unique) | Should -Be @(1)
        }
    }

    Context 'the source itself' {

        It 'never calls Get-Random' {
            # Get-Random is not a CSPRNG.
            Get-Content -Path $script:sourcePath -Raw | Should -Not -Match 'Get-Random'
        }

        It 'never calls RandomNumberGenerator::GetInt32' {
            # GetInt32 is .NET Core only; it does not exist under 5.1, which is
            # the engine's floor.
            Get-Content -Path $script:sourcePath -Raw | Should -Not -Match 'GetInt32'
        }

        It 'never folds a byte with the modulo of the alphabet length' {
            Get-Content -Path $script:sourcePath -Raw | Should -Not -Match '%\s*\$alphabet'
        }

        It 'writes the password nowhere' {
            # The value is returned and nothing else. The only places it lives
            # are the LSA secret and state.json's deploymentPassword, until
            # teardown nulls it (DESIGN 4.5.2, 4.5.3).
            $text = Get-Content -Path $script:sourcePath -Raw

            foreach ($writer in @('Write-HDTLog', 'Write-Host', 'Write-Verbose', 'Write-Debug', 'Write-Output')) {
                $text.Contains($writer) | Should -BeFalse -Because "the deployment password must not reach $writer"
            }
        }
    }

    Context 'help' {

        It 'has comment based help' {
            $help = Get-Help -Name New-HDTDeploymentPassword -ErrorAction Stop

            # Get-Help falls back to a fuzzy search, so the name is asserted
            # first: without it this passes against a sibling command's help.
            $help.Name | Should -BeExactly 'New-HDTDeploymentPassword'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
