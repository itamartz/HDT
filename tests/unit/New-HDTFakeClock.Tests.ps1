# Behaviour that belongs to the fake clock itself: seeding, UTC normalisation,
# advancing, and the guarantee that nothing it does reads the real clock.
#
# The fake is only ever obtained through New-HDTFakeClock. The class name is
# never written as a type literal here: a type literal binds to whichever dynamic
# assembly loaded first and breaks across a module reload.
#
# IClock exists so retry backoff (03-04) is provable without a test that actually
# waits - the fake advances its own clock instead of sleeping.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:invariant = [System.Globalization.CultureInfo]::InvariantCulture
}

Describe 'New-HDTFakeClock' {

    It 'returns the time it was seeded with' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 11, 22, 33, [System.DateTimeKind]::Utc))

        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T11:22:33.0000000Z'
    }

    It 'returns UTC' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))

        $clock.GetUtcNow().Kind | Should -Be ([System.DateTimeKind]::Utc)
    }

    It 'normalises a Local kind to UTC' {
        # [datetime]'2026-08-13T00:00:00Z' parses to Kind = Local on both engines.
        # A fake that stored it verbatim would answer with an instant shifted by
        # the developer's time zone - a clock whose answers depend on the machine
        # running the suite, which is the one thing a fake exists to prevent.
        $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:00:00Z')

        $now = $clock.GetUtcNow()

        $now.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $now.ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.0000000Z'
    }

    It 'treats an Unspecified kind as already UTC' {
        $seed = [datetime]::new(2026, 8, 13, 0, 0, 0)
        $seed.Kind | Should -Be ([System.DateTimeKind]::Unspecified)

        $clock = New-HDTFakeClock -UtcNow $seed

        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.0000000Z'
    }

    It 'does not advance on its own by default' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))

        $first = $clock.GetUtcNow()
        $second = $clock.GetUtcNow()

        $second | Should -Be $first
    }

    It 'advances by the tick when one is given' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250

        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.0000000Z'
        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.2500000Z'
        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.5000000Z'
    }

    It 'advances by Sleep' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.Sleep(90000)

        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:01:30.0000000Z'
    }

    It 'preserves the UTC kind across Sleep' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:00:00Z')
        $clock.Sleep(1000)

        $clock.GetUtcNow().Kind | Should -Be ([System.DateTimeKind]::Utc)
    }

    It 'returns immediately from Sleep' {
        # This is the assertion that keeps every retry-backoff test in 03-04 fast.
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $clock.Sleep(600000)
        $watch.Stop()

        $watch.ElapsedMilliseconds | Should -BeLessThan 1000
    }

    It 'accumulates TotalSleepMillisecond' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.Sleep(1000)
        $clock.Sleep(2000)
        $clock.Sleep(4000)

        $clock.TotalSleepMillisecond | Should -Be 7000
    }

    It 'advances without recording from Advance' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.Advance(3600000)

        $clock.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T01:00:00.0000000Z'
    }

    It 'records GetUtcNow' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.GetUtcNow() | Out-Null
        $clock.GetUtcNow() | Out-Null

        $clock.GetOperationName() | Should -Be @('GetUtcNow', 'GetUtcNow')
    }

    It 'records Sleep with its argument' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.Sleep(1500)

        $clock.GetOperationName() | Should -Be @('Sleep')
        $clock.Operations[0].Arguments[0] | Should -Be 1500
    }

    It 'does not record Advance' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $clock.Advance(5000)

        @($clock.Operations).Count | Should -Be 0
    }

    It 'never reads the real clock' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2001, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))

        $clock.GetUtcNow().Year | Should -Be 2001
    }

    It 'is independent between instances' {
        $first = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $second = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))

        $first.Sleep(60000)

        $second.GetUtcNow().ToString('o', $script:invariant) | Should -BeExactly '2026-08-13T00:00:00.0000000Z'
    }

    It 'exposes the service name Clock' {
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))

        $clock.ServiceName | Should -BeExactly 'Clock'
    }
}
