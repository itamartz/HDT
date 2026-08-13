# The reboot ceremony (DESIGN 4.3, 4.5.1).
#
#   1. mark the step Completed, advancing stepIndex past it
#   2. SAVE
#   3. take (or generate) the deployment password
#   4. arm autologon for 1 + the Restart steps still ahead
#   5. SAVE again, so autoLogon.armed is durable
#   6. status heartbeat
#   7. IPowerService.Restart
#
# THE ORDER IS ASSERTED FROM THE CROSS-SERVICE JOURNAL, not inferred from the
# effects, because the argument for it is an argument about crash windows:
#
#   arm then save, and a crash between them reboots a machine that autologons and
#   resumes at the OLD index - re-running the Restart step, which reboots again.
#   An infinite loop that needs a technician and a boot menu.
#
#   save then arm, and a crash between them reboots a machine that stops at the
#   logon screen. Stuck, but safe and diagnosable.
#
# Between a loop and a stop, choose the stop.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

    $script:rebootYaml = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences/valid-reboot-legs.yaml') -Raw

    # Three Restart steps, for the count the plan states literally: two more
    # after this one means AutoLogonCount 3.
    $script:threeRestartYaml = @'
schemaVersion: 1
id: THREE-RESTARTS
name: Three restarts
steps:
  - name: First restart
    type: Restart
  - name: Second restart
    type: Restart
  - name: Third restart
    type: Restart
'@

    # Runs the first leg of a sequence and hands back the harness and the result.
    $script:runLeg = {
        param([string] $Yaml, [object] $State, [object] $FileSystem, [string] $Phase = 'WinPE', [long] $Seq = 0)

        $argument = @{ Yaml = $Yaml; Phase = $Phase; Seq = $Seq }
        if ($null -ne $State) { $argument['State'] = $State }
        if ($null -ne $FileSystem) { $argument['FileSystem'] = $FileSystem }

        $harness = New-HDTSequenceTestHarness @argument
        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        return [pscustomobject] @{ Harness = $harness; Result = $result }
    }
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'the ceremony' {

        BeforeEach {
            $script:leg = & $script:runLeg $script:rebootYaml
            $script:harness = $script:leg.Harness
            $script:result = $script:leg.Result

            $script:stateWrite = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:harness.StatePath })
            $script:setValue = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'RegistryService' -and $_.Operation -eq 'SetValue' })
            $script:secretWrite = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'LsaService' -and $_.Operation -eq 'SetSecret' })
            $script:restart = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'PowerService' -and $_.Operation -eq 'Restart' })
        }

        It 'returns RebootPending' {
            $script:result.Status | Should -BeExactly 'RebootPending'
        }

        It 'stops at the Restart step' {
            @($script:result.Result | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
        }

        It 'advances stepIndex to the step after the Restart' {
            $script:result.State.stepIndex | Should -Be 4
        }

        It 'records the Restart step Completed' {
            @($script:result.State.step | Where-Object { $_.index -eq 3 })[0].status | Should -BeExactly 'Completed'
        }

        It 'saves the state before arming' {
            $script:stateWrite.Count | Should -BeGreaterThan 0
            $script:setValue.Count | Should -BeGreaterThan 0

            $script:stateWrite[0].Sequence | Should -BeLessThan $script:setValue[0].Sequence
        }

        It 'saves the state again after arming' {
            $afterArm = @($script:stateWrite | Where-Object { $_.Sequence -gt $script:setValue[-1].Sequence })

            $afterArm.Count | Should -BeGreaterOrEqual 1
        }

        It 'arms autologon before restarting' {
            $script:restart.Count | Should -Be 1

            $script:setValue[-1].Sequence | Should -BeLessThan $script:restart[0].Sequence
            $script:secretWrite[0].Sequence | Should -BeLessThan $script:restart[0].Sequence
        }

        It 'saves the state after arming and before restarting' {
            $afterArm = @($script:stateWrite | Where-Object { $_.Sequence -gt $script:setValue[-1].Sequence })

            $afterArm[0].Sequence | Should -BeLessThan $script:restart[0].Sequence
        }

        It 'calls the power service exactly once' {
            $script:harness.Power.GetOperationName() | Should -Be @('Restart')
        }

        It 'passes the step delay to the power service' {
            $script:restart[0].Arguments[0] | Should -Be 30
        }

        It 'logs one reboot.arm record' {
            @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Event 'reboot.arm').Count |
                Should -Be 1
        }

        It 'writes a status heartbeat before restarting' {
            $heartbeat = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:harness.StatusPath })

            @($heartbeat | Where-Object { $_.Sequence -lt $script:restart[0].Sequence }).Count | Should -BeGreaterOrEqual 2
        }

        It 'writes the RunOnce entry that brings the engine back' {
            $script:harness.Registry.GetValue($script:runOncePath, 'HDTResume') | Should -Not -BeNullOrEmpty
        }

        It 'does not run the steps after the Restart' {
            @($script:result.State.step | Where-Object { $_.index -eq 4 })[0].status | Should -BeExactly 'Pending'
        }
    }

    Context 'the password' {

        BeforeEach {
            $script:leg = & $script:runLeg $script:rebootYaml
            $script:harness = $script:leg.Harness
            $script:result = $script:leg.Result
        }

        It 'generates a deployment password on the first reboot' {
            $script:result.State.deploymentPassword | Should -Not -BeNullOrEmpty
        }

        It 'stores it in the state' {
            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json

            $saved.deploymentPassword | Should -BeExactly $script:result.State.deploymentPassword
        }

        It 'stores it as the LSA secret' {
            $script:harness.Lsa.GetSecret('DefaultPassword') | Should -BeExactly $script:result.State.deploymentPassword
        }

        It 'never writes it to the registry' {
            $password = [string] $script:result.State.deploymentPassword

            foreach ($entry in @($script:harness.Journal | Where-Object { $_.Service -eq 'RegistryService' })) {
                foreach ($argument in @($entry.Arguments)) {
                    [string] $argument | Should -Not -BeLike "*$password*"
                }
            }

            $script:harness.Registry.GetValue($script:winlogonPath, 'DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'never writes it into the log' {
            $password = [string] $script:result.State.deploymentPassword
            $text = Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Raw

            $text | Should -Not -BeLike "*$password*"
        }

        It 'is different on every run' {
            $second = & $script:runLeg $script:rebootYaml

            $second.Result.State.deploymentPassword | Should -Not -BeExactly $script:result.State.deploymentPassword
        }

        It 'reuses the same password on the second reboot' {
            # One machine, one secret per run.
            $state = $script:result.State
            $state.leg = 2

            $second = & $script:runLeg $script:rebootYaml $state $script:harness.FileSystem 'FullOS' $state.seq

            $second.Result.Status | Should -BeExactly 'RebootPending'
            $second.Result.State.deploymentPassword | Should -BeExactly $state.deploymentPassword
            $second.Harness.Lsa.GetSecret('DefaultPassword') | Should -BeExactly $state.deploymentPassword
        }
    }

    Context 'the count' {

        It 'sets AutoLogonCount to one more than the Restart steps still ahead' {
            $leg = & $script:runLeg $script:rebootYaml

            # One more Restart after this one, so two more autologons.
            $leg.Harness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 2
            $leg.Result.State.autoLogon.countSet | Should -Be 2
        }

        It 'sets it to 3 when two Restarts are still left' {
            $leg = & $script:runLeg $script:threeRestartYaml

            $leg.Harness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 3
        }

        It 'writes it as a DWord, which is what Winlogon reads' {
            $leg = & $script:runLeg $script:rebootYaml

            $leg.Harness.Registry.GetValueType($script:winlogonPath, 'AutoLogonCount') | Should -BeExactly 'DWord'
        }

        It 'sets it to 1 on the last leg' {
            $first = & $script:runLeg $script:rebootYaml
            $state = $first.Result.State
            $state.leg = 2

            $second = & $script:runLeg $script:rebootYaml $state $first.Harness.FileSystem 'FullOS' $state.seq

            $second.Harness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 1
        }

        It 'refreshes the count on the second arm' {
            $first = & $script:runLeg $script:rebootYaml
            $first.Harness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 2

            $state = $first.Result.State
            $state.leg = 2
            $second = & $script:runLeg $script:rebootYaml $state $first.Harness.FileSystem 'FullOS' $state.seq

            # The same registry is not shared between harnesses, so the assertion
            # is that the second arm wrote its own, smaller count.
            $second.Harness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 1
            $second.Result.State.autoLogon.countSet | Should -Be 1
        }
    }

    Context 'no teardown while a reboot is pending' {

        BeforeEach {
            $script:leg = & $script:runLeg $script:rebootYaml
            $script:harness = $script:leg.Harness
            $script:result = $script:leg.Result
        }

        It 'does not clear autologon' {
            # The assertion that keeps the machine able to come back.
            $script:harness.Registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeExactly '1'
            $script:harness.Registry.GetValue($script:winlogonPath, 'DefaultUserName') | Should -BeExactly 'Administrator'
        }

        It 'leaves the LSA secret in place' {
            $script:harness.Lsa.GetSecret('DefaultPassword') | Should -Not -BeNullOrEmpty
        }

        It 'leaves the RunOnce entry in place' {
            $script:harness.Registry.GetValue($script:runOncePath, 'HDTResume') | Should -Not -BeNullOrEmpty
        }

        It 'leaves the state status Running' {
            $script:result.State.status | Should -BeExactly 'Running'

            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json
            $saved.status | Should -BeExactly 'Running'
        }

        It 'logs no reboot.teardown record' {
            @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Event 'reboot.teardown').Count |
                Should -Be 0
        }

        It 'leaves the machine armed, which Get-HDTAutoLogonArtifact reports' {
            $artifact = @(Get-HDTAutoLogonArtifact -Registry $script:harness.Registry -Lsa $script:harness.Lsa `
                    -FileSystem $script:harness.FileSystem -State $script:result.State)

            $artifact | Should -Contain 'AutoAdminLogon'
            $artifact | Should -Contain 'LsaSecret:DefaultPassword'
            $artifact | Should -Contain 'RunOnce:HDTResume'
            $artifact | Should -Contain 'DeploymentPassword'
        }
    }
}
