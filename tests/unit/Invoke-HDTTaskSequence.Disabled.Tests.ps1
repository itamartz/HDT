# A disabled step, run for real against fakes.
#
# THE CHECKBOX HAS TO MEAN SOMETHING. The console can show "disabled" all it
# likes; if Invoke-HDTTaskSequence runs the step anyway, the deployment does the
# thing the screen said it would not - which is worse than not offering the
# option. This file is the assertion that the engine, not the editor, is what
# honours it.
#
# IT IS A SKIP, NOT AN OMISSION, and it joins the five skip reasons DESIGN 4.4
# already lists. A disabled step keeps its index and gets a step.skip record
# saying why, so two reports of the same sequence have the same steps in them
# and a technician can see which one they switched off.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:yaml = @'
schemaVersion: 1
id: DISABLED
name: One step switched off
steps:
  - name: First
    type: NoOp
  - name: Second
    type: NoOp
    disabled: true
  - name: Third
    type: NoOp
'@

    $script:groupYaml = @'
schemaVersion: 1
id: DISABLEDGROUP
name: A whole group switched off
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
}

Describe 'Invoke-HDTTaskSequence with a disabled step' {

    BeforeAll {
        $script:harness = New-HDTSequenceTestHarness -Yaml $script:yaml
        $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
    }

    It 'does not run the disabled step' {
        $started = @($script:record | Where-Object { $_.event -eq 'step.start' })

        @($started | ForEach-Object { $_.stepName }) | Should -Be @('First', 'Third')
    }

    It 'still runs the steps around it' {
        @($script:record | Where-Object { $_.event -eq 'step.complete' }).Count | Should -Be 2
    }

    It 'records it as Skipped rather than dropping it' {
        @($script:result.Result | ForEach-Object { $_.Status }) |
            Should -Be @('Completed', 'Skipped', 'Completed')
    }

    It 'keeps its index, so two reports of this sequence have the same steps' {
        @($script:result.Result | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
    }

    It 'says WHY it was skipped, in words a technician can act on' {
        $skip = @($script:record | Where-Object { $_.event -eq 'step.skip' })

        @($skip).Count | Should -Be 1
        $skip[0].message | Should -Match 'disabled'
    }

    It 'still reports the run as Succeeded' {
        # A step somebody deliberately switched off is not a failure.
        $script:result.Status | Should -BeExactly 'Succeeded'
    }
}

Describe 'Invoke-HDTTaskSequence with a disabled group' {

    BeforeAll {
        $script:harness = New-HDTSequenceTestHarness -Yaml $script:groupYaml
        $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        $script:record = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath)
    }

    It 'runs nothing inside the group' {
        $started = @($script:record | Where-Object { $_.event -eq 'step.start' })

        @($started | ForEach-Object { $_.stepName }) | Should -Be @('Outside')
    }

    It 'skips every step in it, each with its own record' {
        @($script:record | Where-Object { $_.event -eq 'step.skip' }).Count | Should -Be 2
    }

    It 'still reports Succeeded' {
        $script:result.Status | Should -BeExactly 'Succeeded'
    }
}
