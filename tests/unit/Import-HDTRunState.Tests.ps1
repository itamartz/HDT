# Reading DESIGN 4.3's state document back, which is what a resume is made of.
#
# A CORRUPT DOCUMENT IS A TERMINATING ERROR, NOT "no state". Treating an
# unreadable state.json as an absent one would restart a sequence from step 1 on
# a machine that is already half built - re-running a destructive step. So a
# truncated file, a missing runId or a schemaVersion from the future all throw,
# naming the file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/state'
}

Describe 'Import-HDTRunState' {

    BeforeEach {
        $script:running = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-running.json') -Raw
        $script:fs = New-HDTFakeFileSystem -File @{ 'X:\HDT\state.json' = $script:running }
    }

    It 'reads through the injected filesystem' {
        $null = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $script:fs.GetOperationName() | Should -Be @('ReadAllText')
    }

    It 'returns the run id, sequence id, phase, status and leg' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.runId | Should -BeExactly '8f3c1a90-0000-4000-8000-000000000001'
        $state.sequenceId | Should -BeExactly 'STD-CLIENT'
        $state.phase | Should -BeExactly 'WinPE'
        $state.status | Should -BeExactly 'Running'
        $state.leg | Should -Be 2
    }

    It 'returns stepIndex as an integer' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.stepIndex | Should -BeOfType ([int])
        $state.stepIndex | Should -Be 2
    }

    It 'returns the seq the log stream reached' {
        # This is what makes DESIGN 4.4.2's "seq survives reboots" true: the next
        # leg's log context is seeded from here.
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.seq | Should -Be 417
    }

    It 'rehydrates variable as an ordered dictionary' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.variable -is [System.Collections.IDictionary] | Should -BeTrue
        @($state.variable.Keys) | Should -Be @('HDTTaskSequenceID', 'HDTComputerName', 'HDTDriverGroup')
    }

    It 'looks a variable up case-insensitively' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.variable['hdtcomputername'] | Should -BeExactly 'PC-FIXTURE-0001'
    }

    It 'returns steps in index order' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        @($state.step | ForEach-Object { $_.index }) | Should -Be @(1, 2, 3)
        @($state.step | ForEach-Object { $_.status }) | Should -Be @('Completed', 'Running', 'Pending')
    }

    It 'returns the autologon block' {
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.autoLogon.armed | Should -BeTrue
        $state.autoLogon.countSet | Should -Be 2
    }

    It 'round-trips a document written by Save-HDTRunState' {
        # The property that makes resume work at all.
        $fs = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))

        $original = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $clock `
            -Variable ([ordered] @{ HDTComputerName = 'PC-0001'; HDTApplications = @('7zip', 'Chrome') }) `
            -Step @(
            @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false }
            @{ Index = 2; Name = 'Apply OS'; Type = 'ApplyImage'; Group = @('Install'); Resumable = $true }
        )
        Save-HDTRunState -State $original -Path 'X:\HDT\state.json' -FileSystem $fs -Clock $clock

        $restored = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs

        $restored.runId | Should -BeExactly 'r1'
        $restored.sequenceId | Should -BeExactly 'STD-CLIENT'
        $restored.stepIndex | Should -Be 1
        $restored.variable['HDTComputerName'] | Should -BeExactly 'PC-0001'
        @($restored.variable['HDTApplications']) | Should -Be @('7zip', 'Chrome')
        @($restored.step | ForEach-Object { $_.name }) | Should -Be @('Validate', 'Apply OS')
        $restored.step[1].resumable | Should -BeTrue
    }

    It 'round-trips a state saved under one engine and read under the other' {
        # The fixture on disk is the cross-engine proof: it is written once and
        # read by both the 5.1 and the pwsh 7 leg of the suite.
        $state = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $script:fs

        $state.startedUtc | Should -BeExactly '2026-08-13T00:00:00.0000000Z'
        $state.updatedUtc | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
        $state.step[1].message | Should -BeExactly 'Reboot pending'
    }

    It 'throws a configuration error naming the file for a truncated document' {
        $truncated = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'unparseable-truncated.json') -Raw
        $fs = New-HDTFakeFileSystem -File @{ 'X:\HDT\state.json' = $truncated }

        $record = $null
        try { Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.Exception.Message | Should -BeLike '*X:\HDT\state.json*'
    }

    It 'throws rather than returning null for a corrupt document' {
        # Stated as its own test because treating corruption as "no state" is what
        # would re-run a destructive step on a half-built machine.
        $fs = New-HDTFakeFileSystem -File @{ 'X:\HDT\state.json' = 'not json at all' }

        $result = 'unset'
        $record = $null
        try { $result = Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $result | Should -BeExactly 'unset'
    }

    It 'throws for <Name>' -ForEach @(
        @{ Name = 'invalid-missing-schemaversion.json' }
        @{ Name = 'invalid-missing-runid.json' }
        @{ Name = 'invalid-newer-schemaversion.json' }
        @{ Name = 'invalid-step-without-index.json' }
    ) {
        $text = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath $Name) -Raw
        $fs = New-HDTFakeFileSystem -File @{ 'X:\HDT\state.json' = $text }

        $record = $null
        try { Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'names the unsupported schema version in the message' {
        $text = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'invalid-newer-schemaversion.json') -Raw
        $fs = New-HDTFakeFileSystem -File @{ 'X:\HDT\state.json' = $text }

        $record = $null
        try { Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs } catch { $record = $_ }

        $record.Exception.Message | Should -BeLike '*schemaVersion 2*'
    }

    It 'throws ObjectNotFound naming the file when it does not exist' {
        $fs = New-HDTFakeFileSystem

        $record = $null
        try { Import-HDTRunState -Path 'X:\HDT\state.json' -FileSystem $fs } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTStateNotFound*'
        $record.Exception.Message | Should -BeLike '*X:\HDT\state.json*'
    }

    It 'never touches the real filesystem' {
        $fs = New-HDTFakeFileSystem

        try { Import-HDTRunState -Path 'C:\HDTLab\does-not-exist\state.json' -FileSystem $fs } catch { $null = $_ }

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Import-HDTRunState -ErrorAction Stop

        $help.Name | Should -BeExactly 'Import-HDTRunState'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
