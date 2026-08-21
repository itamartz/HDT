# What the engine publishes about the sequence it is running (DESIGN 3.2).
#
# THE ID WAS AN INPUT AND NEVER AN OUTPUT, and that was a defect with a
# misleading error attached to it. HDTTaskSequenceID is one of THREE ways a
# sequence gets chosen - the -SequenceId parameter, bootstrap.json's sequenceId,
# or the variable - and only the third of them left the variable set. So a PXE
# deployment driven by bootstrap.json ran a sequence whose ApplyUnattend step
# then refused with "this run does not know which sequence it is running. Set
# HDTTaskSequenceID", naming a variable the administrator had deliberately not
# used.
#
# The engine knows. It is holding the document. It publishes what it is running,
# which is what MDT does with TaskSequenceID, TaskSequenceName and
# TaskSequenceVersion - and a run that resumes after a reboot publishes them
# again on the next leg, because they describe the leg rather than the boot.
#
# Everything here runs against fakes.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:versionedYaml = @'
schemaVersion: 1
id: STD-CLIENT
name: Standard Windows 11 Client
version: 3.4.1
steps:
  - name: Only
    type: NoOp
'@

    $script:unversionedYaml = @'
schemaVersion: 1
id: LAB-CLIENT
name: Lab client
steps:
  - name: Only
    type: NoOp
'@
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'the sequence it is running' {

        It 'publishes HDTTaskSequenceID from the document it was handed' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:versionedYaml

            $null = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $harness.Context.Variable['HDTTaskSequenceID'] | Should -BeExactly 'STD-CLIENT'
        }

        It 'publishes HDTTaskSequenceName' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:versionedYaml

            $null = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $harness.Context.Variable['HDTTaskSequenceName'] | Should -BeExactly 'Standard Windows 11 Client'
        }

        It 'publishes HDTTaskSequenceVersion' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:versionedYaml

            $null = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $harness.Context.Variable['HDTTaskSequenceVersion'] | Should -BeExactly '3.4.1'
        }

        It 'publishes an empty HDTTaskSequenceVersion for a sequence that declares none' {
            # Not "omits the variable". A condition written against it would
            # then fail to resolve rather than compare false, and every sequence
            # that predates the field declares none.
            $harness = New-HDTSequenceTestHarness -Yaml $script:unversionedYaml

            $null = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $harness.Context.Variable.Contains('HDTTaskSequenceVersion') | Should -BeTrue
            $harness.Context.Variable['HDTTaskSequenceVersion'] | Should -BeExactly ''
        }

        It 'overwrites an HDTTaskSequenceID that names a different sequence' {
            # THE RUNNING SEQUENCE IS THE TRUTH. A rule can resolve
            # HDTTaskSequenceID to one id while -SequenceId or bootstrap.json
            # chose another; the engine is running the one it was handed, and a
            # variable that says otherwise is what sends a technician reading
            # the wrong sequence's steps. MDT overwrites it for the same reason.
            $harness = New-HDTSequenceTestHarness -Yaml $script:versionedYaml
            $harness.Context.Variable['HDTTaskSequenceID'] = 'SOMETHING-ELSE'

            $null = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $harness.Context.Variable['HDTTaskSequenceID'] | Should -BeExactly 'STD-CLIENT'
        }

        It 'publishes them before the first step runs' {
            # A Validate step conditioned on the sequence version has to see it.
            # Publishing after the loop would make the variables true only of a
            # run that had already finished.
            $harness = New-HDTSequenceTestHarness -Yaml @'
schemaVersion: 1
id: STD-CLIENT
name: Standard Windows 11 Client
version: 3.4.1
steps:
  - name: Runs only when the version is 3.4.1
    type: NoOp
    condition: '"%HDTTaskSequenceVersion%" == "3.4.1"'
'@

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            @($result.Result)[0].Status | Should -BeExactly 'Completed'
        }
    }
}
