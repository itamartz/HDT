# New-HDTExecutionContext is the single argument every step receives besides the
# step itself. It carries the LIVE variable dictionary, the service catalog, the
# 03-01 log context, the run state and the attempt number.
#
# It seeds DESIGN 4.4.1's engine variables - _HDTRunId, _HDTPhase, _HDTLogPath,
# _HDTDeployRoot, _HDTVersion, and per step _HDTStepName and _HDTStepType. They
# are readable by conditions and by user scripts and are never assignable from a
# sequence: Assert-HDTSequenceDocument already refuses a variables: block that
# names one.
#
# SetStep forwards to the log context, which is what makes DESIGN 4.4.4 true -
# "entries carry the step name automatically, so a custom step's output is
# attributable without the author doing anything".

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTExecutionContext' {

    BeforeEach {
        $script:journal = New-Object -TypeName System.Collections.ArrayList
        $script:fileSystem = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -Journal $script:journal
        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        $script:log = New-HDTLogContext -RunId '11111111-2222-3333-4444-555555555555' -Phase WinPE `
            -LogPath 'X:\HDT\Logs' -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:variable['HDTComputerName'] = 'PC-0001'

        $script:context = New-HDTExecutionContext -RunId '11111111-2222-3333-4444-555555555555' `
            -Phase WinPE -WorkspaceRoot 'X:\Deploy' -Variable $script:variable `
            -Service $script:catalog -Log $script:log
    }

    It 'carries the run id, phase and workspace root' {
        $script:context.RunId | Should -BeExactly '11111111-2222-3333-4444-555555555555'
        $script:context.Phase | Should -BeExactly 'WinPE'
        $script:context.WorkspaceRoot | Should -BeExactly 'X:\Deploy'
    }

    It 'carries the service catalog and the log context' {
        [object]::ReferenceEquals($script:context.Service, $script:catalog) | Should -BeTrue
        [object]::ReferenceEquals($script:context.Log, $script:log) | Should -BeTrue
    }

    It 'carries the live variable dictionary' {
        # LIVE, not a copy: a SetVariable step writes through the context and the
        # next step's condition must see it.
        $script:context.Variable['HDTStage'] = 'written by a step'

        $script:variable['HDTStage'] | Should -BeExactly 'written by a step'
    }

    It 'looks a variable up case-insensitively' {
        $script:context.Variable['hdtcomputername'] | Should -BeExactly 'PC-0001'
    }

    It 'seeds _HDTRunId, _HDTPhase, _HDTLogPath, _HDTDeployRoot and _HDTVersion' {
        $script:context.Variable['_HDTRunId'] | Should -BeExactly '11111111-2222-3333-4444-555555555555'
        $script:context.Variable['_HDTPhase'] | Should -BeExactly 'WinPE'
        $script:context.Variable['_HDTLogPath'] | Should -BeExactly 'X:\HDT\Logs'
        $script:context.Variable['_HDTDeployRoot'] | Should -BeExactly 'X:\Deploy'
        $script:context.Variable['_HDTVersion'] | Should -Not -BeNullOrEmpty
    }

    It 'seeds _HDTVersion from Get-HDTModuleVersion' {
        $script:context.Variable['_HDTVersion'] | Should -BeExactly ([string] (Get-HDTModuleVersion))
    }

    It 'sets _HDTStepName and _HDTStepType from SetStep' {
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage')

        $script:context.Variable['_HDTStepName'] | Should -BeExactly 'Apply OS'
        $script:context.Variable['_HDTStepType'] | Should -BeExactly 'ApplyImage'
    }

    It 'forwards SetStep to the log context' {
        # DESIGN 4.4.4: a custom step's log lines are attributed without the
        # author doing anything, because the log context already knows the step.
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage')

        $script:log.StepIndex | Should -Be 3
        $script:log.StepName | Should -BeExactly 'Apply OS'
        $script:log.StepType | Should -BeExactly 'ApplyImage'
    }

    It 'starts with attempt one' {
        $script:context.Attempt | Should -Be 1
    }

    It 'carries a null run state when none was supplied' {
        $script:context.State | Should -BeNullOrEmpty
    }

    It 'carries the run state it was given' {
        $state = New-HDTRunState -RunId '11111111-2222-3333-4444-555555555555' -SequenceId 'STD-CLIENT' `
            -Phase WinPE -Clock $script:clock

        $withState = New-HDTExecutionContext -RunId '11111111-2222-3333-4444-555555555555' `
            -Phase WinPE -WorkspaceRoot 'X:\Deploy' -Variable $script:variable `
            -Service $script:catalog -Log $script:log -State $state

        [object]::ReferenceEquals($withState.State, $state) | Should -BeTrue
    }

    It 'performs no I/O when it is built' {
        # It is built in WinPE before a disk exists, so construction may not
        # touch the filesystem or the clock.
        @($script:journal).Count | Should -Be 0
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTExecutionContext -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTExecutionContext'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
