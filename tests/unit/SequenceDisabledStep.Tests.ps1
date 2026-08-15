# A step an administrator switched off without deleting it.
#
# WHY THE ENGINE HAS TO KNOW, AND NOT JUST THE CONSOLE. MDT's task sequence
# editor has "Disable this step", and it is how a technician bisects a failing
# build: turn one step off, run it again, turn it back on. A checkbox the
# console honoured and the deployment ignored would be worse than no checkbox -
# the run would do the thing the screen said it would not.
#
# IT IS A SKIP, NOT AN OMISSION. The step keeps its index and gets a step.skip
# record saying it was disabled, exactly like the five skip reasons that already
# exist (DESIGN 4.4). A disabled step that simply vanished from the run would
# leave a technician comparing two reports with different numbers of steps and
# no statement anywhere about why.
#
# A DISABLED GROUP DISABLES ITS STEPS, because otherwise turning off a group of
# six means six separate edits and the chance to miss one.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DISABLED\sequence.yaml'

    $script:yaml = @'
schemaVersion: 1
id: DISABLED
name: A sequence with a step switched off
steps:
  - name: First
    type: NoOp
  - name: Second
    type: NoOp
    disabled: true
  - name: Third
    type: NoOp
    disabled: false
'@

    $script:groupYaml = @'
schemaVersion: 1
id: DISABLEDGROUP
name: A group switched off
steps:
  - group: Off
    disabled: true
    steps:
      - name: Inside One
        type: NoOp
      - name: Inside Two
        type: NoOp
  - group: On
    steps:
      - name: Outside
        type: NoOp
'@

    function Read-HDTDisabledDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string] $Yaml
        )

        $fs = New-HDTFakeFileSystem -File @{ $script:path = $Yaml }

        return Import-HDTSequenceDocument -Path $script:path -FileSystem $fs
    }
}

Describe 'a disabled step in a sequence document' {

    It 'is accepted by the schema' {
        { Read-HDTDisabledDocument -Yaml $script:yaml } | Should -Not -Throw
    }

    It 'is carried onto the step, so the engine and the console see the same thing' {
        $document = Read-HDTDisabledDocument -Yaml $script:yaml
        $second = @($document.Step | Where-Object { $_.Name -eq 'Second' })[0]

        $second.Disabled | Should -BeTrue
    }

    It 'defaults to enabled when the document says nothing' {
        # Absent must mean enabled. A sequence written before this existed has no
        # disabled key anywhere in it, and every one of its steps must still run.
        $document = Read-HDTDisabledDocument -Yaml $script:yaml
        $first = @($document.Step | Where-Object { $_.Name -eq 'First' })[0]

        $first.Disabled | Should -BeFalse
    }

    It 'reads an explicit false as enabled' {
        $document = Read-HDTDisabledDocument -Yaml $script:yaml
        $third = @($document.Step | Where-Object { $_.Name -eq 'Third' })[0]

        $third.Disabled | Should -BeFalse
    }

    It 'keeps the step in the sequence, with its index' {
        # A disabled step is skipped, not omitted. Two reports of the same
        # sequence must have the same steps in them.
        $document = Read-HDTDisabledDocument -Yaml $script:yaml

        @($document.Step).Count | Should -Be 3
        @($document.Step | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
    }
}

Describe 'a disabled group' {

    It 'is accepted by the schema' {
        { Read-HDTDisabledDocument -Yaml $script:groupYaml } | Should -Not -Throw
    }

    It 'disables every step inside it' {
        # Otherwise turning off a group of six is six edits and a chance to miss
        # one.
        $document = Read-HDTDisabledDocument -Yaml $script:groupYaml

        @($document.Step | Where-Object { $_.Name -eq 'Inside One' })[0].Disabled | Should -BeTrue
        @($document.Step | Where-Object { $_.Name -eq 'Inside Two' })[0].Disabled | Should -BeTrue
    }

    It 'leaves the steps of other groups alone' {
        $document = Read-HDTDisabledDocument -Yaml $script:groupYaml

        @($document.Step | Where-Object { $_.Name -eq 'Outside' })[0].Disabled | Should -BeFalse
    }
}

Describe 'Test-HDTSequenceDocument rejects a disabled that is not a boolean' {

    It 'refuses a string where a boolean belongs' {
        $bad = @'
schemaVersion: 1
id: BAD
name: Bad
steps:
  - name: First
    type: NoOp
    disabled: "sometimes"
'@

        { Read-HDTDisabledDocument -Yaml $bad } | Should -Throw -ExpectedMessage '*disabled*'
    }
}
