# The log context is DATA: the run id, the phase, the log path, the two injected
# services, the verbosity, the monotonic seq counter and the current step.
#
# It performs no I/O when it is built, which is what lets the engine construct one
# in WinPE before a disk exists and hand the same object to every step afterwards.
#
# The seq counter lives here rather than in a module variable because it is seeded
# from state.json on resume - that is what makes DESIGN 4.4.2's "seq survives
# reboots" true across a leg boundary.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTLogContext' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
        $script:context = New-HDTLogContext -RunId '8f3c1a90' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
    }

    It 'carries the run id, phase and log path' {
        $script:context.RunId | Should -BeExactly '8f3c1a90'
        $script:context.Phase | Should -BeExactly 'WinPE'
        $script:context.LogPath | Should -BeExactly 'X:\HDT\Logs'
    }

    It 'carries the injected services' {
        $script:context.FileSystem.ServiceName | Should -BeExactly 'FileSystem'
        $script:context.Clock.ServiceName | Should -BeExactly 'Clock'
    }

    It 'starts at seq zero' {
        $script:context.Seq | Should -Be 0
    }

    It 'can be seeded with a seq, so a resumed run continues the numbering' {
        $resumed = New-HDTLogContext -RunId '8f3c1a90' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock -Seq 417

        $resumed.Seq | Should -Be 417
        $resumed.NextSeq() | Should -Be 418
    }

    It 'defaults the level to Info' {
        $script:context.Level | Should -BeExactly 'Info'
    }

    It 'accepts a level' {
        $verbose = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock -Level Debug

        $verbose.Level | Should -BeExactly 'Debug'
    }

    It 'rejects a level outside the set' {
        $record = $null
        try {
            New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level 'Verbose'
        } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
    }

    It 'defaults the component to Engine' {
        $script:context.Component | Should -BeExactly 'Engine'
    }

    It 'captures a thread id' {
        $script:context.ThreadId | Should -BeGreaterThan 0
    }

    It 'accepts an explicit thread id' {
        $fixed = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock -ThreadId 4820

        $fixed.ThreadId | Should -Be 4820
    }

    It 'builds JsonlPath and MasterLogPath under the log path' {
        $script:context.JsonlPath | Should -BeExactly 'X:\HDT\Logs\HDT.jsonl'
        $script:context.MasterLogPath | Should -BeExactly 'X:\HDT\Logs\HDT.log'
    }

    It 'performs no I/O when it is built' {
        # A context is data. The engine builds one in WinPE before a disk exists.
        @($script:fs.Operations).Count | Should -Be 0
        @($script:clock.Operations).Count | Should -Be 0
    }

    It 'starts with no step set' {
        $script:context.StepIndex | Should -Be 0
        $script:context.StepName | Should -BeNullOrEmpty
        $script:context.StepType | Should -BeNullOrEmpty
        $script:context.StepLogPath | Should -BeNullOrEmpty
    }

    It 'sets the step fields from SetStep' {
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')

        $script:context.StepIndex | Should -Be 3
        $script:context.StepName | Should -BeExactly 'Apply OS'
        $script:context.StepType | Should -BeExactly 'ApplyImage'
        $script:context.StepLogPath | Should -BeExactly 'X:\HDT\Logs\Steps\003-ApplyImage.log'
    }

    It 'clears the step fields from ClearStep' {
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')
        $script:context.ClearStep()

        $script:context.StepIndex | Should -Be 0
        $script:context.StepName | Should -BeNullOrEmpty
        $script:context.StepType | Should -BeNullOrEmpty
        $script:context.StepLogPath | Should -BeNullOrEmpty
    }

    It 'performs no I/O when a step is set' {
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage', 'X:\HDT\Logs\Steps\003-ApplyImage.log')

        @($script:fs.Operations).Count | Should -Be 0
    }

    It 'increments seq from NextSeq' {
        $script:context.NextSeq() | Should -Be 1
        $script:context.NextSeq() | Should -Be 2
        $script:context.NextSeq() | Should -Be 3
        $script:context.Seq | Should -Be 3
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTLogContext -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTLogContext'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
