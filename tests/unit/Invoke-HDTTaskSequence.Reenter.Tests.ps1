# A step that owns a LIST needs the reboot to come back to it (07-02).
#
# The loop records a RebootRequested step as Completed, which advances stepIndex
# past it, so the next leg continues at the step AFTER it. That is exactly right
# for a Restart step, and exactly wrong for an InstallApplications step that got
# a 3010 halfway down its list: the applications after it would be silently
# skipped, and the deployment would report success having installed half the
# software it was asked to.
#
# Reenter is the step saying "record me Pending, not Completed". The loop leaves
# stepIndex where it is, the whole reboot ceremony runs unchanged, and the next
# leg runs the step again - which picks up from the progress it checkpointed into
# a variable, because DESIGN 4.3's state document persists variables across legs.
#
# IT IS OPT-IN BECAUSE THE DEFAULT IS RIGHT FOR EVERYTHING ELSE. A Restart step
# that re-entered would reboot forever, so the regression guard below asserts
# that a plain RebootRequested still advances.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # Two step types that differ in exactly one thing: whether they ask to be
    # re-entered. Everything else about them is identical, so any difference in
    # the state document is attributable to Reenter and to nothing else.
    #
    # ContosoBatch counts its own calls in a variable, which is how the second
    # leg proves it resumed rather than restarted: it reboots on call 1 and
    # completes on call 2.
    $script:stepModule = {
        function Invoke-HDTContosoBatchStep {
            param($Step, $Context)

            # The step contract requires -Step; this double reads only the
            # context, which is where the progress lives.
            $null = $Step

            $done = 0
            if ($Context.Variable.Contains('ContosoBatchDone')) {
                $done = [int] $Context.Variable['ContosoBatchDone']
            }

            $done = $done + 1
            $Context.Variable['ContosoBatchDone'] = $done

            if ($done -lt 2) {
                return (New-HDTStepResult -Status RebootRequested -Reenter -Message ('installed {0} of 2' -f $done))
            }

            return (New-HDTStepResult -Status Completed -Message ('installed {0} of 2' -f $done))
        }

        function Invoke-HDTContosoPlainStep {
            param($Step, $Context)

            $null = $Step, $Context
            return (New-HDTStepResult -Status RebootRequested -Message 'restarting')
        }

        Export-ModuleMember -Function *
    }

    $script:batchYaml = @'
schemaVersion: 1
id: BATCH
name: A step that owns a list
steps:
  - name: Install the applications
    type: ContosoBatch
  - name: After the applications
    type: NoOp
'@

    $script:plainYaml = @'
schemaVersion: 1
id: PLAIN
name: A step that just wants a restart
steps:
  - name: Ask for a restart
    type: ContosoPlain
  - name: After the restart
    type: NoOp
'@

    $script:runLeg = {
        param([string] $Yaml, [object] $FileSystem, [string] $StateJson, [string] $Phase)

        $argument = @{ Yaml = $Yaml; Phase = $Phase }
        if ($null -ne $FileSystem) { $argument['FileSystem'] = $FileSystem }
        if (-not [string]::IsNullOrEmpty($StateJson)) { $argument['StateJson'] = $StateJson }

        $harness = New-HDTSequenceTestHarness @argument

        # What Invoke-HDTBootReconciliation does before handing the state over.
        if (-not [string]::IsNullOrEmpty($StateJson)) {
            $harness.State.leg = [int] $harness.State.leg + 1
        }

        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
            -State $harness.State -StepType @(Get-HDTStepType)

        return [pscustomobject] @{
            Harness   = $harness
            Result    = $result
            StateJson = $harness.FileSystem.ReadAllText($harness.StatePath)
        }
    }
}

Describe 'Invoke-HDTTaskSequence' {

    BeforeEach {
        $script:module = New-Module -Name HDTReenterStepType -ScriptBlock $script:stepModule | Import-Module -PassThru -Global
    }

    AfterEach {
        Remove-Module -ModuleInfo $script:module -Force -ErrorAction SilentlyContinue
    }

    Context 'a step that asks to be re-entered' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:leg1 = & $script:runLeg $script:batchYaml $script:fs '' 'WinPE'
            $script:state1 = $script:leg1.StateJson | ConvertFrom-Json

            # THE PRECONDITION, ASSERTED RATHER THAN ASSUMED. A step that FAILS
            # also leaves stepIndex where it is and also keeps the variable it
            # set, so half the assertions below would pass against a first leg
            # that failed - green tests proving nothing. Refusing to run them
            # unless leg 1 genuinely rebooted is what makes them tests.
            if ([string] $script:leg1.Result.Status -ne 'RebootPending') {
                $reason = @($script:leg1.Result.Result | ForEach-Object { [string] $_.Message }) -join '; '

                throw ("the first leg must end at a reboot for these assertions to mean anything, but it ended '{0}': {1}" -f
                    $script:leg1.Result.Status, $reason)
            }
        }

        It 'still ends the leg at a reboot' {
            $script:leg1.Result.Status | Should -BeExactly 'RebootPending'
        }

        It 'records the step Pending rather than Completed' {
            # Completed is what the loop records for every other RebootRequested,
            # and it is what advances stepIndex.
            @($script:state1.step | Where-Object { $_.index -eq 1 }).status | Should -BeExactly 'Pending'
        }

        It 'leaves stepIndex at the step, so the next leg runs it again' {
            $script:state1.stepIndex | Should -Be 1
        }

        It 'checkpoints the progress variable the step set' {
            # This is what makes resuming at the next application possible at all:
            # DESIGN 4.3 copies the live variables into the state on every save.
            $script:state1.variable.ContosoBatchDone | Should -Be 1
        }

        It 'runs the step again on the next leg and completes it' {
            $leg2 = & $script:runLeg $script:batchYaml $script:fs $script:leg1.StateJson 'FullOS'

            $ran = @($leg2.Result.Result | Where-Object { $_.Status -ne 'Skipped' })

            $ran[0].Index | Should -Be 1
            $ran[0].Name | Should -BeExactly 'Install the applications'
            $ran[0].Status | Should -BeExactly 'Completed'
        }

        It 'resumes the step rather than restarting it' {
            $leg2 = & $script:runLeg $script:batchYaml $script:fs $script:leg1.StateJson 'FullOS'

            # 2, not 1: the step saw the progress its first leg checkpointed. A
            # step that restarted from nothing would report 1 again.
            $leg2.Result.Result[0].Message | Should -BeExactly 'installed 2 of 2'
        }

        It 'reaches the step after it once it completes' {
            $leg2 = & $script:runLeg $script:batchYaml $script:fs $script:leg1.StateJson 'FullOS'

            @($leg2.Result.Result | ForEach-Object { $_.Name }) | Should -Contain 'After the applications'
        }
    }

    Context 'a plain RebootRequested, which must be unchanged' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:plainLeg = & $script:runLeg $script:plainYaml $script:fs '' 'WinPE'
            $script:plainState = $script:plainLeg.StateJson | ConvertFrom-Json
        }

        It 'records the step Completed' {
            @($script:plainState.step | Where-Object { $_.index -eq 1 }).status | Should -BeExactly 'Completed'
        }

        It 'advances stepIndex past it' {
            # A Restart step that re-entered would reboot forever.
            $script:plainState.stepIndex | Should -Be 2
        }

        It 'starts the next leg at the step after it' {
            $leg2 = & $script:runLeg $script:plainYaml $script:fs $script:plainLeg.StateJson 'FullOS'

            $ran = @($leg2.Result.Result | Where-Object { $_.Status -ne 'Skipped' })

            $ran[0].Name | Should -BeExactly 'After the restart'
        }
    }
}
