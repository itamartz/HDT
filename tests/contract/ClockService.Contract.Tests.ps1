# The IClock contract (PROJECT constraint 4, DESIGN 12.2.1).
#
# Two methods, GetUtcNow and Sleep. Sleep is on the interface so retry backoff
# (03-04) is provable without a test that actually waits: the fake advances its
# own clock instead of blocking, and the engine never learns the difference.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.
#
# The Skip key goes on a Context INSIDE the Describe, never on the Describe
# itself: verified against Pester 5.7.1, -Skip: on a -ForEach Describe binds
# before -ForEach binds the row's keys, so every row would run regardless.
#
# The real Clock row sleeps only 0 and 1 milliseconds, so the contract stays fast.
$script:HDTImplementation = @(
    @{
        Name           = 'FakeClock'
        Skip           = $false
        Factory        = { New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 1 }
        JournalFactory = { param($Journal) New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -Journal $Journal }
    }
    @{
        Name           = 'Clock'
        Skip           = $false
        Factory        = { New-HDTClock }
        JournalFactory = { param($Journal) New-HDTClock -Journal $Journal }
    }
)

Describe 'IClock contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:clock = & $Factory
        }

        It 'exposes GetUtcNow and Sleep' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapters are pscustomobjects carrying
            # ScriptMethod members. Do not "tidy" ScriptMethod away.
            $method = @($script:clock | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('GetUtcNow', 'Sleep')) {
                $method | Should -Contain $name -Because "IClock requires $name"
            }
        }

        It 'returns a DateTime from GetUtcNow' {
            $script:clock.GetUtcNow() | Should -BeOfType ([datetime])
        }

        It 'returns a UTC DateTime from GetUtcNow' {
            $script:clock.GetUtcNow().Kind | Should -Be ([System.DateTimeKind]::Utc)
        }

        It 'returns a time that does not go backwards' {
            $first = $script:clock.GetUtcNow()
            $second = $script:clock.GetUtcNow()

            $second | Should -BeGreaterOrEqual $first
        }

        It 'accepts a zero millisecond sleep' {
            { $script:clock.Sleep(0) } | Should -Not -Throw
        }

        It 'does not go backwards across a sleep' {
            $before = $script:clock.GetUtcNow()
            $script:clock.Sleep(1)
            $after = $script:clock.GetUtcNow()

            $after | Should -BeGreaterOrEqual $before
        }

        It 'records GetUtcNow and Sleep' {
            $script:clock.GetUtcNow() | Out-Null
            $script:clock.Sleep(0)

            $script:clock.GetOperationName() | Should -Be @('GetUtcNow', 'Sleep')
            $script:clock.Operations[1].Arguments[0] | Should -Be 0
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $journalled = & $JournalFactory $journal

            $journalled.GetUtcNow() | Out-Null
            $journalled.Sleep(0)

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('Clock.GetUtcNow', 'Clock.Sleep')
            @($journal | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2)
        }

        It 'names itself Clock' {
            $script:clock.ServiceName | Should -BeExactly 'Clock'
        }
    }
}
