# DESIGN 4.3: "every step is idempotent or checkpointed. On resume the engine
# skips completed steps by index".
#
# stepIndex is the 1-based index of the NEXT step to run, so it advances past a
# step that Completed or was Skipped and STAYS PUT for one that is Running or
# Failed - a failed run resumes AT the failure, not after it, or the technician
# who fixes the cause never gets the step retried.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Update-HDTRunStateStep' {

    BeforeEach {
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $script:state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $script:clock `
            -Step @(
            @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false }
            @{ Index = 2; Name = 'Restart'; Type = 'Restart'; Group = @('Preinstall'); Resumable = $true }
            @{ Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; Group = @('Install'); Resumable = $false }
        )
    }

    It 'sets the status of the step at that index' {
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Running

        $script:state.step[1].status | Should -BeExactly 'Running'
    }

    It 'leaves other steps alone' {
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Running

        $script:state.step[0].status | Should -BeExactly 'Pending'
        $script:state.step[2].status | Should -BeExactly 'Pending'
    }

    It 'records the attempt number' {
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Running -Attempt 3

        $script:state.step[1].attempt | Should -Be 3
    }

    It 'records the exit code' {
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Failed -ExitCode 3010

        $script:state.step[1].exitCode | Should -Be 3010
    }

    It 'records an exit code of zero' {
        # Zero is a result, not an absence.
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Completed -ExitCode 0

        $script:state.step[1].exitCode | Should -Be 0
    }

    It 'records the message' {
        $null = Update-HDTRunStateStep -State $script:state -Index 3 -Status Failed -Message 'DISM returned 0x80070002'

        $script:state.step[2].message | Should -BeExactly 'DISM returned 0x80070002'
    }

    It 'records startedUtc and endedUtc as strings' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed `
            -StartedUtc ([datetime]::new(2026, 8, 13, 0, 0, 1, [System.DateTimeKind]::Utc)) `
            -EndedUtc ([datetime]::new(2026, 8, 13, 0, 0, 2, 200, [System.DateTimeKind]::Utc))

        $script:state.step[0].startedUtc | Should -BeExactly '2026-08-13T00:00:01.0000000Z'
        $script:state.step[0].endedUtc | Should -BeExactly '2026-08-13T00:00:02.2000000Z'
        $script:state.step[0].startedUtc | Should -BeOfType ([string])
    }

    It 'converts a local timestamp to UTC' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed `
            -StartedUtc ([datetime]'2026-08-13T00:00:01Z')

        $script:state.step[0].startedUtc | Should -BeExactly '2026-08-13T00:00:01.0000000Z'
    }

    It 'records durationMs' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed -DurationMs 1200

        $script:state.step[0].durationMs | Should -Be 1200
    }

    It 'advances stepIndex past a completed step' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed

        $script:state.stepIndex | Should -Be 2
    }

    It 'advances stepIndex past a skipped step' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Skipped

        $script:state.stepIndex | Should -Be 2
    }

    It 'advances stepIndex past the last step' {
        $null = Update-HDTRunStateStep -State $script:state -Index 3 -Status Completed

        $script:state.stepIndex | Should -Be 4
    }

    It 'does not advance stepIndex for a running step' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Running

        $script:state.stepIndex | Should -Be 1
    }

    It 'does not advance stepIndex for a failed step' {
        # A failed run resumes AT the failure, not after it.
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed
        $null = Update-HDTRunStateStep -State $script:state -Index 2 -Status Failed

        $script:state.stepIndex | Should -Be 2
    }

    It 'does not advance stepIndex for a pending step' {
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Pending

        $script:state.stepIndex | Should -Be 1
    }

    It 'rejects an index outside the sequence' {
        $record = $null
        try { Update-HDTRunStateStep -State $script:state -Index 4 -Status Completed } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'rejects an index of zero' {
        $record = $null
        try { Update-HDTRunStateStep -State $script:state -Index 0 -Status Completed } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike '*ParameterArgumentValidation*'
    }

    It 'rejects a status outside the set' {
        $record = $null
        try { Update-HDTRunStateStep -State $script:state -Index 1 -Status 'Done' } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
    }

    It 'returns the state object' {
        $returned = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed

        $returned.runId | Should -BeExactly 'r1'
        $returned.stepIndex | Should -Be 2
    }

    It 'reads no clock and no file' {
        # It mutates the document in memory; Save-HDTRunState stamps and writes.
        $null = Update-HDTRunStateStep -State $script:state -Index 1 -Status Completed

        @($script:clock.Operations).Count | Should -Be 1
        (Get-Command -Name Update-HDTRunStateStep).Parameters.ContainsKey('FileSystem') | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Update-HDTRunStateStep -ErrorAction Stop

        $help.Name | Should -BeExactly 'Update-HDTRunStateStep'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
