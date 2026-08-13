# DESIGN 4.5.2's third backstop, read by 03-03's boot reconcile: "if the state
# document says the run is finished, failed, or missing, it clears autologon, the
# LSA secret, the RunOnce entry and C:\HDT\state.json before doing anything else."
#
# The stale case is the interesting one. A run that is still marked Running but
# has not been touched for hours is a deployment that died between legs - the
# machine autologs on forever otherwise, which is precisely the failure mode
# MDT's teardown-as-a-step leaves behind.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTRunStateAbandoned' {

    BeforeEach {
        $script:startClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $script:state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase FullOS -Clock $script:startClock `
            -Step @(@{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false })
    }

    It 'reports a Succeeded run as abandoned' {
        $script:state.status = 'Succeeded'
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 1, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeTrue
    }

    It 'reports a Failed run as abandoned' {
        $script:state.status = 'Failed'
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 1, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeTrue
    }

    It 'reports a fresh Running run as not abandoned' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 30, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeFalse
    }

    It 'reports a Running run exactly at the limit as not abandoned' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 12, 0, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeFalse
    }

    It 'reports a stale Running run as abandoned' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 13, 0, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeTrue
    }

    It 'honours -MaxAgeHour' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 2, 0, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now -MaxAgeHour 1 | Should -BeTrue
        Test-HDTRunStateAbandoned -State $script:state -Clock $now -MaxAgeHour 4 | Should -BeFalse
    }

    It 'reads the time only through the injected clock' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 30, 0, [System.DateTimeKind]::Utc))

        $null = Test-HDTRunStateAbandoned -State $script:state -Clock $now

        $now.GetOperationName() | Should -Be @('GetUtcNow')
    }

    It 'treats an unparseable updatedUtc as abandoned' {
        # A state document whose timestamp cannot be read is not evidence that a
        # run is alive.
        $script:state.updatedUtc = 'yesterday afternoon'
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 30, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeTrue
    }

    It 'treats a missing updatedUtc as abandoned' {
        $script:state.updatedUtc = ''
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 30, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeTrue
    }

    It 'reads an imported state document' {
        $fixture = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/state/valid-completed.json') -Raw
        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDT\state.json' = $fixture }
        $imported = Import-HDTRunState -Path 'C:\HDT\state.json' -FileSystem $fs
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 43, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $imported -Clock $now | Should -BeTrue
    }

    It 'returns a boolean' {
        $now = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 30, 0, [System.DateTimeKind]::Utc))

        Test-HDTRunStateAbandoned -State $script:state -Clock $now | Should -BeOfType ([bool])
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Test-HDTRunStateAbandoned -ErrorAction Stop

        $help.Name | Should -BeExactly 'Test-HDTRunStateAbandoned'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
