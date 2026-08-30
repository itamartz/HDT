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

        It 'takes the administrator s password rather than generating one' {
            $script:harness.Lsa.GetSecret('DefaultPassword') |
                Should -BeExactly ([string] $script:harness.Variable['HDTAdminPassword'])
        }

        It 'keeps no second copy of it in the state' {
            # The resolved variables are saved with the state already, so a
            # separate field was a second place for the same secret to live and a
            # second thing teardown had to remember to clear.
            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json

            $saved.PSObject.Properties['deploymentPassword'] | Should -BeNullOrEmpty
        }

        It 'never writes it to the registry' {
            $password = [string] $script:harness.Variable['HDTAdminPassword']

            foreach ($entry in @($script:harness.Journal | Where-Object { $_.Service -eq 'RegistryService' })) {
                foreach ($argument in @($entry.Arguments)) {
                    [string] $argument | Should -Not -BeLike "*$password*"
                }
            }

            $script:harness.Registry.GetValue($script:winlogonPath, 'DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'never writes it into the log' {
            $password = [string] $script:harness.Variable['HDTAdminPassword']
            $text = Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Raw

            $text | Should -Not -BeLike "*$password*"
        }

        It 'is the same on every reboot, because it is the account s password' {
            # It used to be a fresh random secret per run, and "different every
            # run" was the property asserted here. It is now HDTAdminPassword -
            # the password the unattend gave the Administrator account - so the
            # only correct value is the SAME one on every leg. A different one
            # would be Winlogon trying a password the account does not have.
            $state = $script:result.State
            $state.leg = 2

            $second = & $script:runLeg $script:rebootYaml $state $script:harness.FileSystem 'FullOS' $state.seq

            $second.Result.Status | Should -BeExactly 'RebootPending'
            $second.Harness.Lsa.GetSecret('DefaultPassword') |
                Should -BeExactly ([string] $script:harness.Variable['HDTAdminPassword'])
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
        }
    }
}

Describe 'the password autologon is armed with' {

    # ONE PASSWORD, AND IT IS HDTAdminPassword.
    #
    # DESIGN 4.5.2 settles this in as many words: "The administrator sets the
    # password; HDT does not invent one." An earlier draft generated a random
    # per-deployment secret, and New-HDTDeploymentPassword was that draft, left
    # behind after the decision went the other way. It was worse in practice for
    # the reason the design gives: when a deployment fails halfway the machine is
    # sitting there with a password NOBODY KNOWS, at exactly the moment a
    # technician needs to log into it and look.
    #
    # It was also quietly wrong. The unattend arms the first logon with
    # %HDTAdminPassword%, so a machine whose Administrator account carries the
    # ADMIN password would have had autologon armed with a DIFFERENT, generated
    # one on its second reboot - Winlogon would try a password the account does
    # not have, and the resume would stop at a logon screen with no explanation.
    # DEMO-05 never hit it because it restarts once.

    BeforeAll {
        $script:twoRestartYaml = @'
schemaVersion: 1
id: TWO-RESTARTS
name: Two restarts
steps:
  - name: First restart
    type: Restart
  - name: Second restart
    type: Restart
'@
    }

    It 'arms with HDTAdminPassword, not something it made up' {
        $harness = New-HDTSequenceTestHarness -Yaml $script:twoRestartYaml `
            -Variable @{ HDTAdminPassword = 'Set-By-The-Rules-1' }

        [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

        # THE JOURNAL REDACTS IT, WHICH IS THE POINT OF THE JOURNAL - so what
        # was actually armed is read from the store Winlogon would read.
        @($harness.Journal |
                Where-Object { $_.Service -eq 'LsaService' -and $_.Operation -eq 'SetSecret' }) |
            Should -HaveCount 1

        $harness.Lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Set-By-The-Rules-1'
    }

    It 'keeps no second copy of it in the state document' {
        # The resolved variables are already saved with the state, so a separate
        # deploymentPassword field was a second place for the same secret to live
        # - and a second thing teardown had to remember to clear.
        $harness = New-HDTSequenceTestHarness -Yaml $script:twoRestartYaml `
            -Variable @{ HDTAdminPassword = 'Set-By-The-Rules-1' }

        [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

        $harness.State.PSObject.Properties['deploymentPassword'] | Should -BeNullOrEmpty
    }

    It 'refuses the reboot by name when nobody set one' {
        # BETWEEN A LOOP AND A STOP, CHOOSE THE STOP - and between a stop and a
        # machine nobody can log into, choose the stop. The message has to name
        # the variable and where it goes, because that is the whole fix.
        $harness = New-HDTSequenceTestHarness -Yaml $script:twoRestartYaml `
            -Variable @{ HDTAdminPassword = '' }

        $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

        $result.Status | Should -BeExactly 'Failed'

        $said = @($result.Result | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { $_.Message })
        ($said -join ' ') | Should -BeLike '*HDTAdminPassword*'
    }

    It 'does not reboot a machine it could not arm' {
        $harness = New-HDTSequenceTestHarness -Yaml $script:twoRestartYaml `
            -Variable @{ HDTAdminPassword = '' }

        [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

        @($harness.Journal | Where-Object { $_.Service -eq 'PowerService' -and $_.Operation -eq 'Restart' }) |
            Should -BeNullOrEmpty
    }
}

# TWO RESTARTS IN THE FULL OS, WHICH IS THE CASE run-20260830-204613 DIED ON.
#
# The reboot tests above all arm from WinPE. That is one leg of a real
# deployment and it is the FORGIVING one: WinPE's
# HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon is a shallow copy
# on a RAM disk, so the adapter's `New-Item -Force` - which on the registry
# provider DELETES the key tree and recreates it - emptied a key nobody would
# miss and nothing ever failed.
#
# The second arm happens in the FULL OS, against the real Winlogon key, and that
# is where it threw. Step 11 'Restart into Windows' (WinPE -> FullOS) succeeded
# and step 12 'Restart before second application pass' (FullOS -> FullOS) did
# not. Nothing in this file covered a second arm from the full OS at all.
#
# THE ADAPTER IS WHERE THE DEFECT WAS AND THE CONTRACT TEST IS WHERE IT IS
# CAUGHT - the fake was right all along, so these tests were green before the
# fix and are green after it. They are here because the SEQUENCE SHAPE was
# uncovered: two arms, both in the full OS, converging rather than accumulating.
# A seeded Winlogon value that must survive both of them is the engine-level
# expression of "a set is not a delete".
Describe 'Invoke-HDTTaskSequence' {

    Context 'two Restart steps in the FullOS phase' {

        BeforeAll {
            $script:fullOsYaml = @'
schemaVersion: 1
id: FULLOS-TWO-RESTARTS
name: Two restarts in the full OS
steps:
  - group: Configure
    runIn: FullOS
    steps:
      - name: Install applications
        type: NoOp
      - name: Restart into Windows
        type: Restart
      - name: Restart before second application pass
        type: Restart
      - name: Finish
        type: NoOp
'@

            # WHAT A REAL Winlogon KEY HAS IN IT BESIDES HDT'S OWN VALUES. These
            # are the ones the delete took with it, and they are seeded so the
            # test can say out loud that arming twice must not cost the machine
            # its shell.
            $script:seeded = @{
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' = @{
                    Shell    = 'explorer.exe'
                    Userinit = 'C:\Windows\system32\userinit.exe,'
                }
            }

            $script:fs = New-HDTFakeFileSystem
            $script:sharedLsa = New-HDTFakeLsaService

            $first = New-HDTSequenceTestHarness -Yaml $script:fullOsYaml -Phase FullOS `
                -FileSystem $script:fs -Lsa $script:sharedLsa -RegistryValue $script:seeded `
                -Variable @{ HDTAdminPassword = 'Set-By-The-Rules-1' }
            $script:firstResult = Invoke-HDTTaskSequence -Sequence $first.Sequence -Context $first.Context -State $first.State
            $script:firstHarness = $first

            # Leg two: the state document out of the fake filesystem as TEXT,
            # which is what a machine that has actually rebooted has.
            $stateJson = $script:fs.ReadAllText($first.StatePath)

            $second = New-HDTSequenceTestHarness -Yaml $script:fullOsYaml -Phase FullOS `
                -FileSystem $script:fs -Lsa $script:sharedLsa -StateJson $stateJson `
                -RegistryValue $script:seeded `
                -Variable @{ HDTAdminPassword = 'Set-By-The-Rules-1' }
            $second.State.leg = [int] $second.State.leg + 1
            $script:secondResult = Invoke-HDTTaskSequence -Sequence $second.Sequence -Context $second.Context -State $second.State
            $script:secondHarness = $second
        }

        It 'ends the first leg at the first Restart' {
            $script:firstResult.Status | Should -BeExactly 'RebootPending'
            @($script:firstResult.Result | ForEach-Object { $_.Name }) |
                Should -Be @('Install applications', 'Restart into Windows')
        }

        It 'ends the second leg at the second Restart' {
            $script:secondResult.Status | Should -BeExactly 'RebootPending'

            $ran = @($script:secondResult.Result | Where-Object { $_.Status -ne 'Skipped' })
            $ran[0].Name | Should -BeExactly 'Restart before second application pass'
        }

        It 'arms once on each leg' {
            @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:firstHarness.Log.JsonlPath -Event 'reboot.arm').Count |
                Should -Be 2
        }

        It 'counts down rather than accumulating' {
            # One more Restart after the first, so two autologons; none after the
            # second, so one. Arming twice leaves what arming once left.
            $script:firstHarness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 2
            $script:secondHarness.Registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 1
        }

        It 'keeps the rest of the Winlogon key across both arms' {
            # THE ONE THAT NAMES THE DEFECT. Arming used to empty this key.
            foreach ($harness in @($script:firstHarness, $script:secondHarness)) {
                $harness.Registry.GetValue($script:winlogonPath, 'Shell') | Should -BeExactly 'explorer.exe'
                $harness.Registry.GetValue($script:winlogonPath, 'Userinit') |
                    Should -BeExactly 'C:\Windows\system32\userinit.exe,'
            }
        }

        It 'never deletes a registry key while arming' {
            # A set is a set. No arm may issue a remove of the key it writes to.
            @($script:firstHarness.Journal | Where-Object {
                    $_.Service -eq 'RegistryService' -and $_.Operation -eq 'RemoveKey'
                }) | Should -BeNullOrEmpty

            @($script:secondHarness.Journal | Where-Object {
                    $_.Service -eq 'RegistryService' -and $_.Operation -eq 'RemoveKey'
                }) | Should -BeNullOrEmpty
        }

        It 're-arms RunOnce on the second leg, because RunOnce is consumed each leg' {
            $script:secondHarness.Registry.GetValue($script:runOncePath, 'HDTResume') | Should -Not -BeNullOrEmpty
        }

        It 'restarts on both legs' {
            @($script:firstHarness.Journal | Where-Object {
                    $_.Service -eq 'PowerService' -and $_.Operation -eq 'Restart'
                }).Count | Should -Be 1

            @($script:secondHarness.Journal | Where-Object {
                    $_.Service -eq 'PowerService' -and $_.Operation -eq 'Restart'
                }).Count | Should -Be 1
        }
    }
}

# THE RECORD A FATAL FAILURE LEAVES BEHIND.
#
# When the reboot ceremony itself throws, nothing has turned that into a step
# result - Invoke-HDTStepAttempt only catches what a STEP threw - so it reaches
# the engine's own catch, and that catch writes the last thing anybody will ever
# know about the deployment. On run-20260830-204613 the whole of it was:
#
#   The task sequence stopped: Exception calling "SetValue" with "4"
#   argument(s): "The running command stopped because the preference variable
#   "ErrorActionPreference" or common parameter is set to Stop: Cannot delete a
#   subkey tree because the subkey does not exist."
#
# THE DOUBLE THROWS THROUGH A ScriptMethod ON PURPOSE, because that is what
# builds the three-layer MethodInvocationException the old record could not read.
# Throwing from a plain function would produce a one-layer error and would prove
# nothing about the unwrap.
Describe 'Invoke-HDTTaskSequence' {

    Context 'a fatal error in the reboot ceremony' {

        BeforeAll {
            # A REAL SERVICE DOUBLE, NOT A Mock (tests/helpers/README.md 10). It
            # delegates everything to a real fake and throws on the one call the
            # ceremony makes, from inside a ScriptMethod.
            $script:brokenLsa = [pscustomobject] @{
                Inner       = New-HDTFakeLsaService
                ServiceName = 'LsaService'
            }
            $script:brokenLsa | Add-Member -MemberType ScriptProperty -Name Operations -Value { $this.Inner.Operations }
            # A SETTER AS WELL AS A GETTER: the harness assigns the shared
            # cross-service journal onto every service it is given, and a
            # read-only ScriptProperty makes that a SetValueException rather than
            # a wiring problem anybody can see.
            $script:brokenLsa | Add-Member -MemberType ScriptProperty -Name Journal `
                -Value { $this.Inner.Journal } -SecondValue { $this.Inner.Journal = $args[0] }
            $script:brokenLsa | Add-Member -MemberType ScriptMethod -Name GetSecret -Value {
                param([string] $Name) return $this.Inner.GetSecret($Name)
            }
            $script:brokenLsa | Add-Member -MemberType ScriptMethod -Name RemoveSecret -Value {
                param([string] $Name) $this.Inner.RemoveSecret($Name)
            }
            $script:brokenLsa | Add-Member -MemberType ScriptMethod -Name SetSecret -Value {
                param([string] $Name, [string] $Value)

                $ErrorActionPreference = 'Stop'
                throw [System.ArgumentException]::new('Cannot delete a subkey tree because the subkey does not exist.')
            }

            $script:failYaml = @'
schemaVersion: 1
id: FATAL-ARM
name: A restart that cannot be armed
steps:
  - name: Restart into Windows
    type: Restart
  - name: Never reached
    type: NoOp
'@

            $harness = New-HDTSequenceTestHarness -Yaml $script:failYaml -Phase FullOS `
                -Lsa $script:brokenLsa -Variable @{ HDTAdminPassword = 'Set-By-The-Rules-1' }

            $script:fatalResult = Invoke-HDTTaskSequence -Sequence $harness.Sequence `
                -Context $harness.Context -State $harness.State
            $script:fatalHarness = $harness

            $script:fatalRecord = @(Get-HDTLogRecord -FileSystem $harness.FileSystem `
                    -Path $harness.Log.JsonlPath -Event 'step.fail')[-1]
        }

        It 'fails the run' {
            $script:fatalResult.Status | Should -BeExactly 'Failed'
        }

        It 'writes a step.fail record' {
            $script:fatalRecord | Should -Not -BeNullOrEmpty
        }

        It 'names the cause in the message rather than the plumbing that wrapped it' {
            $script:fatalRecord.message | Should -BeLike '*Cannot delete a subkey tree*'
        }

        It 'names the real exception type' {
            $script:fatalRecord.data.exceptionType | Should -BeExactly 'System.ArgumentException'
        }

        It 'keeps the outer wrapper too, because the chain is evidence' {
            $script:fatalRecord.data.outerExceptionType |
                Should -BeExactly 'System.Management.Automation.MethodInvocationException'
            [int] $script:fatalRecord.data.layerCount | Should -BeGreaterOrEqual 2
        }

        It 'carries the file and the line' {
            $script:fatalRecord.data.scriptName | Should -Not -BeNullOrEmpty
            [int] $script:fatalRecord.data.scriptLineNumber | Should -BeGreaterThan 0
            $script:fatalRecord.data.position | Should -Not -BeNullOrEmpty
        }

        It 'carries the stack trace' {
            $script:fatalRecord.data.stackTrace | Should -Not -BeNullOrEmpty
        }

        It 'carries the category and the fully qualified error id' {
            $script:fatalRecord.data.category | Should -Not -BeNullOrEmpty
            $script:fatalRecord.data.fullyQualifiedErrorId | Should -Not -BeNullOrEmpty
        }

        It 'still says which sequence it was' {
            $script:fatalRecord.data.sequenceId | Should -BeExactly 'FATAL-ARM'
        }

        It 'keeps the human-readable message to one line' {
            # The CMTrace twin is read by eye, one row per record. The stack goes
            # in data, never into the middle of the sentence.
            @($script:fatalRecord.message -split "`n").Count | Should -Be 1
        }
    }
}
