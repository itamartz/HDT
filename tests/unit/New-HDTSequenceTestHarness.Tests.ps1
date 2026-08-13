# The shared assembly line for every 03-04 loop test.
#
# Running Invoke-HDTTaskSequence against fakes takes eleven objects wired
# together in one order: a journal, seven fakes, a service catalog, a log
# context, a run state and an execution context. Seven test files each building
# that by hand is seven chances for them to drift apart, and a drifting harness
# turns "the loop changed" into "one file's BeforeEach was different".
#
# So it lives in HDTTestTools, and it has its own tests - a harness nobody
# asserts on is a second implementation nobody reads.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:yaml = @'
schemaVersion: 1
id: HARNESS
name: Harness sequence
variables:
  HDTStage: start
steps:
  - name: First
    type: NoOp
  - name: Second
    type: NoOp
'@
}

Describe 'New-HDTSequenceTestHarness' {

    Context 'what it assembles' {

        BeforeEach {
            $script:harness = New-HDTSequenceTestHarness -Yaml $script:yaml
        }

        It 'imports the sequence' {
            $script:harness.Sequence.Id | Should -BeExactly 'HARNESS'
            @($script:harness.Sequence.Step).Count | Should -Be 2
        }

        It 'shares one journal across every service' {
            $script:harness.FileSystem.Journal | Should -Be $script:harness.Journal
            $script:harness.Clock.Journal | Should -Be $script:harness.Journal
            $script:harness.Registry.Journal | Should -Be $script:harness.Journal
            $script:harness.Lsa.Journal | Should -Be $script:harness.Journal
            $script:harness.Power.Journal | Should -Be $script:harness.Journal
            $script:harness.Process.Journal | Should -Be $script:harness.Journal
            $script:harness.ScriptInvoker.Journal | Should -Be $script:harness.Journal
        }

        It 'builds a catalog carrying every service' {
            foreach ($name in @('FileSystem', 'Clock', 'Registry', 'Lsa', 'Process', 'Power', 'ScriptInvoker', 'Cim', 'Environment')) {
                $script:harness.Catalog.$name | Should -Not -BeNullOrEmpty -Because "the catalog must carry $name"
            }
        }

        It 'builds a log context on the same services' {
            $script:harness.Log.FileSystem | Should -Be $script:harness.FileSystem
            $script:harness.Log.Clock | Should -Be $script:harness.Clock
        }

        It 'builds an execution context carrying the catalog and the log' {
            $script:harness.Context.Service | Should -Be $script:harness.Catalog
            $script:harness.Context.Log | Should -Be $script:harness.Log
        }

        It 'builds a run state with one record per step' {
            @($script:harness.State.step).Count | Should -Be 2
            $script:harness.State.sequenceId | Should -BeExactly 'HARNESS'
        }

        It 'seeds the sequence variable defaults into the live dictionary' {
            $script:harness.Context.Variable['HDTStage'] | Should -BeExactly 'start'
        }

        It 'defaults to the WinPE phase' {
            $script:harness.Context.Phase | Should -BeExactly 'WinPE'
        }

        It 'names the state and status paths under the log path' {
            $script:harness.StatePath | Should -BeExactly 'X:\HDT\Logs\state.json'
            $script:harness.StatusPath | Should -BeExactly 'X:\HDT\Logs\status.json'
        }

        It 'freezes the clock by default' {
            $first = $script:harness.Clock.GetUtcNow()
            $second = $script:harness.Clock.GetUtcNow()

            $second | Should -Be $first
        }

        It 'records nothing before the code under test runs' {
            # Seeding is not an operation (tests/helpers/README.md section 4), so
            # the first journal entry belongs to the loop and not to the harness.
            @($script:harness.Journal).Count | Should -Be 0
        }
    }

    Context 'what a test can vary' {

        It 'takes a phase' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase FullOS

            $harness.Context.Phase | Should -BeExactly 'FullOS'
            $harness.Log.Phase | Should -BeExactly 'FullOS'
        }

        It 'takes extra variables' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Variable @{ HDTGate = 'open' }

            $harness.Context.Variable['HDTGate'] | Should -BeExactly 'open'
        }

        It 'lets a variable override a sequence default' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Variable @{ HDTStage = 'later' }

            $harness.Context.Variable['HDTStage'] | Should -BeExactly 'later'
        }

        It 'takes an existing state, which is what a resume is' {
            $first = New-HDTSequenceTestHarness -Yaml $script:yaml
            $first.State.stepIndex = 2

            $second = New-HDTSequenceTestHarness -Yaml $script:yaml -State $first.State

            $second.State | Should -Be $first.State
            $second.Context.State | Should -Be $first.State
        }

        It 'seeds the log seq, so a second leg continues the numbering' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Seq 41

            $harness.Log.NextSeq() | Should -Be 42
        }

        It 'takes a clock tick' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -TickMillisecond 1000

            $first = $harness.Clock.GetUtcNow()
            $harness.Clock.GetUtcNow() | Should -Be $first.AddMilliseconds(1000)
        }

        It 'seeds the process service' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -ProcessResult @{ 'cmd.exe /c exit 0' = @{ ExitCode = 0 } }

            $harness.Process.Start('cmd.exe', '/c exit 0', '', 0).ExitCode | Should -Be 0
        }

        It 'seeds the registry' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -RegistryValue @{ 'HKLM:\Test' = @{ Name = 'value' } }

            $harness.Registry.GetValue('HKLM:\Test', 'Name') | Should -BeExactly 'value'
        }

        It 'seeds the LSA secret' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Secret @{ DefaultPassword = 'Sw0rdfish!' }

            $harness.Lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
        }
    }

    Context 'a second leg' {

        It 'imports a state document from its saved text' {
            $first = New-HDTSequenceTestHarness -Yaml $script:yaml
            $first.State.stepIndex = 2
            Save-HDTRunState -State $first.State -Path $first.StatePath -FileSystem $first.FileSystem -Clock $first.Clock

            $text = $first.FileSystem.ReadAllText($first.StatePath)
            $second = New-HDTSequenceTestHarness -Yaml $script:yaml -StateJson $text

            $second.State.stepIndex | Should -Be 2
            $second.State.runId | Should -BeExactly $first.State.runId
        }

        It 'seeds the log seq from the imported state' {
            $first = New-HDTSequenceTestHarness -Yaml $script:yaml
            $first.State.seq = 17
            Save-HDTRunState -State $first.State -Path $first.StatePath -FileSystem $first.FileSystem -Clock $first.Clock

            $second = New-HDTSequenceTestHarness -Yaml $script:yaml -StateJson ($first.FileSystem.ReadAllText($first.StatePath))

            $second.Log.NextSeq() | Should -Be 18
        }

        It 'reuses a filesystem it was given, so one log stream spans the legs' {
            $first = New-HDTSequenceTestHarness -Yaml $script:yaml
            Write-HDTLog -Context $first.Log -Message 'leg one' -Event run.start

            $second = New-HDTSequenceTestHarness -Yaml $script:yaml -FileSystem $first.FileSystem
            Write-HDTLog -Context $second.Log -Message 'leg two' -Event run.start

            $second.FileSystem | Should -Be $first.FileSystem
            @(Get-HDTLogRecord -FileSystem $first.FileSystem -Path $first.Log.JsonlPath | ForEach-Object { $_.message }) |
                Should -Be @('leg one', 'leg two')
        }

        It 'takes a filesystem whose writes fail' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -WriteFailure @{ 'X:\HDT\Logs\state.json' = 'the disk is full' }

            { $harness.FileSystem.WriteAllText($harness.StatePath, '{}') } | Should -Throw -ExceptionType ([System.IO.IOException])
        }
    }

    Context 'the sequence file' {

        It 'seeds the sequence into the fake filesystem' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml

            $harness.FileSystem.TestPath($harness.SequencePath) | Should -BeTrue
        }

        It 'refuses a sequence that does not parse' {
            { New-HDTSequenceTestHarness -Yaml "schemaVersion: 1`nid: BROKEN" } | Should -Throw
        }
    }
}
