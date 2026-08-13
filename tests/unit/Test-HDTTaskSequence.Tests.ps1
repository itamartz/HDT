# The authoring-time lint (DESIGN 4.2, 4.3).
#
# Assert-HDTSequenceDocument answers "is this a well formed sequence document".
# This answers a different question: "would this sequence actually work on the
# machine you are about to deploy" - a step type nothing implements, a WinPE step
# after the machine has left WinPE, a %Var% nothing supplies, continueOnError on
# a Restart.
#
# It RETURNS findings rather than throwing, because it is a lint: the console
# (M8) surfaces them inline while somebody is still editing, and a lint that
# stops at the first problem makes that experience worse than useless.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:import = {
        param([string] $Yaml)

        $path = 'X:\Deploy\Sequences\LINT\sequence.yaml'
        $fs = New-HDTFakeFileSystem -File @{ $path = $Yaml }

        return (Import-HDTSequenceDocument -Path $path -FileSystem $fs)
    }
}

Describe 'Test-HDTTaskSequence' {

    Context 'a step type nothing implements' {

        BeforeAll {
            $script:sequence = & $script:import @'
schemaVersion: 1
id: LINT-TYPE
name: An unimplemented type
steps:
  - name: Fine
    type: NoOp
  - name: Nobody implements this
    type: Contoso
'@
            $script:finding = @(Test-HDTTaskSequence -Sequence $script:sequence)
        }

        It 'reports an Error' {
            $unknown = @($script:finding | Where-Object { $_.Step -eq 'Nobody implements this' })

            $unknown.Count | Should -Be 1
            $unknown[0].Severity | Should -BeExactly 'Error'
        }

        It 'names the type' {
            @($script:finding | Where-Object { $_.Step -eq 'Nobody implements this' })[0].Message | Should -BeLike '*Contoso*'
        }

        It 'lists the known types in that message' {
            $message = @($script:finding | Where-Object { $_.Step -eq 'Nobody implements this' })[0].Message

            $message | Should -BeLike '*NoOp*'
            $message | Should -BeLike '*Restart*'
        }

        It 'reports the step index and name on every finding' {
            foreach ($item in $script:finding) {
                $item.Index | Should -BeGreaterThan 0
                $item.Step | Should -Not -BeNullOrEmpty
            }
        }

        It 'says nothing about the step whose type exists' {
            @($script:finding | Where-Object { $_.Step -eq 'Fine' }) | Should -BeNullOrEmpty
        }
    }

    Context 'a clean sequence' {

        It 'reports nothing for a sequence whose types all exist' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-CLEAN
name: Nothing to report
variables:
  HDTStage: start
steps:
  - name: First
    type: NoOp
  - name: Second
    type: SetVariable
    variable: HDTGate
    value: open
  - name: Third
    type: NoOp
    condition: '"%HDTGate%" == "open"'
  - name: Fourth
    type: NoOp
    message: stage is %HDTStage%
'@

            Test-HDTTaskSequence -Sequence $sequence | Should -BeNullOrEmpty
        }

        It 'returns findings rather than throwing' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-THROW
name: Everything wrong at once
steps:
  - name: Unknown type
    type: Contoso
  - name: Tolerated restart
    type: Restart
    continueOnError: true
  - name: Back to WinPE
    type: NoOp
    runIn: WinPE
  - name: Missing variable
    type: NoOp
    message: '%HDTNobodySuppliesThis%'
'@

            { Test-HDTTaskSequence -Sequence $sequence } | Should -Not -Throw
            @(Test-HDTTaskSequence -Sequence $sequence).Count | Should -Be 4
        }
    }

    Context 'a Restart step' {

        BeforeAll {
            $script:restartSequence = & $script:import @'
schemaVersion: 1
id: LINT-RESTART
name: Restart problems
steps:
  - name: Tolerated restart
    type: Restart
    continueOnError: true
  - name: Back to WinPE
    type: NoOp
    runIn: WinPE
  - name: Fine in the full OS
    type: NoOp
    runIn: FullOS
'@
            $script:restartFinding = @(Test-HDTTaskSequence -Sequence $script:restartSequence)
        }

        It 'warns about continueOnError on a Restart step' {
            $finding = @($script:restartFinding | Where-Object { $_.Step -eq 'Tolerated restart' })

            $finding.Count | Should -Be 1
            $finding[0].Severity | Should -BeExactly 'Warning'
            $finding[0].Message | Should -BeLike '*continueOnError*'
        }

        It 'warns about a WinPE step after a Restart' {
            $finding = @($script:restartFinding | Where-Object { $_.Step -eq 'Back to WinPE' })

            $finding.Count | Should -Be 1
            $finding[0].Severity | Should -BeExactly 'Warning'
            $finding[0].Message | Should -BeLike '*WinPE*'
        }

        It 'says nothing about a FullOS step after a Restart' {
            @($script:restartFinding | Where-Object { $_.Step -eq 'Fine in the full OS' }) | Should -BeNullOrEmpty
        }

        It 'says nothing about a WinPE step before the Restart' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-RESTART-ORDER
name: WinPE work then a restart
steps:
  - name: In WinPE
    type: NoOp
    runIn: WinPE
  - name: Restart
    type: Restart
'@

            Test-HDTTaskSequence -Sequence $sequence | Should -BeNullOrEmpty
        }
    }

    Context 'a variable nothing supplies' {

        It 'warns about a token no source could supply' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-VARIABLE
name: An unsupplied token
steps:
  - name: Needs a variable
    type: NoOp
    message: 'building %HDTNobodySuppliesThis%'
'@
            $finding = @(Test-HDTTaskSequence -Sequence $sequence)

            $finding.Count | Should -Be 1
            $finding[0].Severity | Should -BeExactly 'Warning'
            $finding[0].Message | Should -BeLike '*HDTNobodySuppliesThis*'
        }

        It 'warns about a token in a condition' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-CONDITION
name: An unsupplied token in a condition
steps:
  - name: Conditional
    type: NoOp
    condition: '"%HDTNobodySuppliesThis%" == "yes"'
'@

            @(Test-HDTTaskSequence -Sequence $sequence).Count | Should -Be 1
        }

        It 'warns about a token in a group condition once per contained step' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-GROUP-CONDITION
name: An unsupplied token in a group condition
steps:
  - group: Conditional group
    condition: '"%HDTNobodySuppliesThis%" == "yes"'
    steps:
      - name: Inside
        type: NoOp
'@
            $finding = @(Test-HDTTaskSequence -Sequence $sequence)

            $finding.Count | Should -Be 1
            $finding[0].Step | Should -BeExactly 'Inside'
        }

        It 'says nothing about an engine variable' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-ENGINE-VARIABLE
name: The engine supplies these
steps:
  - name: Conditional
    type: NoOp
    condition: '"%_HDTPhase%" == "FullOS"'
'@

            Test-HDTTaskSequence -Sequence $sequence | Should -BeNullOrEmpty
        }

        It 'says nothing about a variable an earlier SetVariable step supplies' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-SET-VARIABLE
name: A step supplies it
steps:
  - name: Set it
    type: SetVariable
    variables:
      HDTGate: open
  - name: Read it
    type: NoOp
    condition: '"%HDTGate%" == "open"'
'@

            Test-HDTTaskSequence -Sequence $sequence | Should -BeNullOrEmpty
        }

        It 'warns about a variable a LATER SetVariable step supplies' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-SET-VARIABLE-LATE
name: Set too late to help
steps:
  - name: Read it
    type: NoOp
    condition: '"%HDTGate%" == "open"'
  - name: Set it
    type: SetVariable
    variable: HDTGate
    value: open
'@
            $finding = @(Test-HDTTaskSequence -Sequence $sequence)

            $finding.Count | Should -Be 1
            $finding[0].Step | Should -BeExactly 'Read it'
        }

        It 'takes the names a rules document would supply' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-KNOWN-VARIABLE
name: A rule supplies it
steps:
  - name: Read it
    type: NoOp
    condition: '"%HDTSite%" == "HQ"'
'@

            Test-HDTTaskSequence -Sequence $sequence -KnownVariable 'HDTSite' | Should -BeNullOrEmpty
        }
    }

    Context 'the registry it was given' {

        It 'uses a step type registry it was handed rather than discovering one' {
            $sequence = & $script:import @'
schemaVersion: 1
id: LINT-REGISTRY
name: A supplied registry
steps:
  - name: Only NoOp exists here
    type: Restart
'@
            $registry = @(Get-HDTStepType -Name NoOp)
            $finding = @(Test-HDTTaskSequence -Sequence $sequence -StepType $registry)

            $finding.Count | Should -Be 1
            $finding[0].Severity | Should -BeExactly 'Error'
            $finding[0].Message | Should -BeLike '*Restart*'
        }
    }
}
