# DESIGN 4.5.3's teardown checklist, run from the loop's finally block.
#
# "Teardown is a failsafe, not a step. MDT's cleanup is a task sequence step, so
# a failure before it leaves autologon armed. In HDT teardown runs from finally
# around the sequence" (DESIGN 4.5.2).
#
# ROADMAP M2 names four scenarios the checklist must come out empty after. 03-03
# proved two of them - the abandoned run and the missing state document - from
# Invoke-HDTBootReconciliation. These are the other two, plus the cases that make
# a finally block worth having at all: a step that threw, a sequence that could
# not run, and a CHECKPOINT THAT ITSELF FAILED.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

    # An armed machine, exactly as Set-HDTAutoLogon leaves it, so teardown has
    # something to tear down.
    $script:armed = @{
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' = @{
            AutoAdminLogon    = '1'
            DefaultUserName   = 'Administrator'
            DefaultDomainName = ''
            AutoLogonCount    = 2
        }
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'     = @{ HDTResume = 'powershell.exe' }
    }

    $script:goodYaml = @'
schemaVersion: 1
id: TEARDOWN-GOOD
name: A run that succeeds
steps:
  - name: First
    type: NoOp
  - name: Second
    type: NoOp
'@

    $script:badYaml = @'
schemaVersion: 1
id: TEARDOWN-BAD
name: A run that fails
steps:
  - name: First
    type: NoOp
  - name: Fatal
    type: NoOp
    fail: true
    exitCode: 9
'@

    $script:throwYaml = @'
schemaVersion: 1
id: TEARDOWN-THROW
name: A step that throws
steps:
  - name: Wrong namespace
    type: SetVariable
    variable: NotAnHDTName
    value: nope
'@

    $script:unusableYaml = @'
schemaVersion: 1
id: TEARDOWN-UNUSABLE
name: An unusable sequence
steps:
  - name: Nobody implements this
    type: Contoso
'@

    # An armed harness whose state already carries the deployment password.
    $script:armedHarness = {
        param([string] $Yaml, [hashtable] $WriteFailure)

        $argument = @{ Yaml = $Yaml; RegistryValue = $script:armed; Secret = @{ DefaultPassword = 'Sw0rdfish!' } }
        if ($null -ne $WriteFailure) { $argument['WriteFailure'] = $WriteFailure }

        $harness = New-HDTSequenceTestHarness @argument
        $harness.State.deploymentPassword = 'Sw0rdfish!'
        $harness.State.autoLogon.armed = $true
        $harness.State.autoLogon.userName = 'Administrator'
        $harness.State.autoLogon.countSet = 2
        $harness.State.autoLogon.secretName = 'DefaultPassword'
        $harness.State.autoLogon.runOnceName = 'HDTResume'

        return $harness
    }
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'after a successful run' {

        BeforeEach {
            $script:harness = & $script:armedHarness $script:goodYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        }

        It 'reports Succeeded' {
            $script:result.Status | Should -BeExactly 'Succeeded'
        }

        It 'clears autologon' {
            $script:harness.Registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:harness.Lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'leaves no artifact behind' {
            Get-HDTAutoLogonArtifact -Registry $script:harness.Registry -Lsa $script:harness.Lsa `
                -FileSystem $script:harness.FileSystem -State $script:result.State | Should -BeNullOrEmpty
        }

        It 'nulls the deployment password in the state' {
            $script:result.State.deploymentPassword | Should -BeNullOrEmpty

            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json
            $saved.deploymentPassword | Should -BeNullOrEmpty
        }

        It 'removes the RunOnce entry' {
            $script:harness.Registry.GetValue($script:runOncePath, 'HDTResume') | Should -BeNullOrEmpty
        }

        It 'logs one reboot.teardown record' {
            @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Event 'reboot.teardown').Count |
                Should -Be 1
        }

        It 'sets the state status to Succeeded' {
            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json

            $saved.status | Should -BeExactly 'Succeeded'
        }
    }

    Context 'after a failed run' {

        BeforeEach {
            $script:harness = & $script:armedHarness $script:badYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        }

        It 'clears autologon' {
            $script:harness.Registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:harness.Lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'leaves no artifact behind' {
            Get-HDTAutoLogonArtifact -Registry $script:harness.Registry -Lsa $script:harness.Lsa `
                -FileSystem $script:harness.FileSystem -State $script:result.State | Should -BeNullOrEmpty
        }

        It 'sets the state status to Failed' {
            $script:result.State.status | Should -BeExactly 'Failed'

            $saved = $script:harness.FileSystem.ReadAllText($script:harness.StatePath) | ConvertFrom-Json
            $saved.status | Should -BeExactly 'Failed'
        }

        It 'still returns the failing step' {
            $script:result.FailedStep.Name | Should -BeExactly 'Fatal'
        }

        It 'tears down even when the failure came from a thrown exception' {
            $harness = & $script:armedHarness $script:throwYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Failed'
            Get-HDTAutoLogonArtifact -Registry $harness.Registry -Lsa $harness.Lsa `
                -FileSystem $harness.FileSystem -State $result.State | Should -BeNullOrEmpty
        }

        It 'tears down even when the sequence itself was unusable' {
            $harness = & $script:armedHarness $script:unusableYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Failed'
            Get-HDTAutoLogonArtifact -Registry $harness.Registry -Lsa $harness.Lsa `
                -FileSystem $harness.FileSystem -State $result.State | Should -BeNullOrEmpty
        }
    }

    Context 'when the checkpoint itself fails' {

        BeforeEach {
            # The failsafe's own failsafe: a filesystem that refuses to write
            # state.json. The finally must not be skipped because the checkpoint
            # inside it threw.
            $script:harness = & $script:armedHarness $script:badYaml @{ 'X:\HDT\Logs\state.json' = 'the disk is full' }
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        }

        It 'does not throw' {
            $script:result | Should -Not -BeNullOrEmpty
        }

        It 'tears down anyway' {
            $script:harness.Registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:harness.Lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'leaves no registry or LSA artifact behind' {
            $artifact = @(Get-HDTAutoLogonArtifact -Registry $script:harness.Registry -Lsa $script:harness.Lsa `
                    -FileSystem $script:harness.FileSystem)

            $artifact | Should -BeNullOrEmpty
        }

        It 'fails the run, because a run that cannot be checkpointed cannot survive a reboot' {
            $script:result.Status | Should -BeExactly 'Failed'
        }

        It 'says in the log that the state could not be checkpointed' {
            $warning = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath |
                    Where-Object { $_.message -like '*could not be checkpointed*' })

            $warning.Count | Should -BeGreaterOrEqual 1
        }

        It 'still ends the run in the log' {
            @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Event 'run.end').Count |
                Should -Be 1
        }
    }

    Context 'a teardown that could not finish' {

        # Clear-HDTAutoLogon never throws: it attempts nine items independently
        # and reports the ones that would not go. What the loop must do with that
        # report is say so and change nothing else - the run's own status is what
        # the caller acts on.

        BeforeEach {
            Mock -ModuleName Hephaestus -CommandName Clear-HDTAutoLogon -MockWith {
                [pscustomobject] @{
                    Cleared = [string[]] @('DefaultUserName')
                    Failed  = [object[]] @([pscustomobject] @{ Item = 'AutoAdminLogon'; Message = 'Requested registry access is not allowed.' })
                }
            }

            $script:harness = & $script:armedHarness $script:badYaml
            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence -Context $script:harness.Context -State $script:harness.State
        }

        It 'reports a teardown failure without hiding the run failure' {
            $script:result.Status | Should -BeExactly 'Failed'
            $script:result.FailedStep.Name | Should -BeExactly 'Fatal'
        }

        It 'names the unfinished item in the log' {
            $warning = @(Get-HDTLogRecord -FileSystem $script:harness.FileSystem -Path $script:harness.Log.JsonlPath -Severity Warning |
                    Where-Object { $_.message -like '*AutoAdminLogon*' })

            $warning.Count | Should -Be 1
        }

        It 'does not promote a teardown failure to the run status of a run that succeeded' {
            $harness = & $script:armedHarness $script:goodYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'
        }
    }

    Context 'a run with no registry or LSA service' {

        It 'says teardown was skipped rather than failing silently' {
            $harness = New-HDTSequenceTestHarness -Yaml $script:goodYaml
            $catalog = New-HDTServiceCatalog -FileSystem $harness.FileSystem -Clock $harness.Clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
                -Variable $harness.Variable -Service $catalog -Log $harness.Log -State $harness.State

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $context -State $harness.State

            $result.Status | Should -BeExactly 'Succeeded'

            $warning = @(Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Severity Warning |
                    Where-Object { $_.message -like '*teardown was skipped*' })

            $warning.Count | Should -Be 1
        }
    }

    Context 'copy-back' {

        It 'copies the logs when a destination was given' {
            $harness = & $script:armedHarness $script:goodYaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                -State $harness.State -LogDestination '\\share\Logs' | Out-Null

            $harness.FileSystem.TestPath('\\share\Logs') | Should -BeTrue
            @($harness.Journal | Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' }).Count |
                Should -BeGreaterThan 0
        }

        It 'names the destination after the computer name and the run id' {
            $harness = & $script:armedHarness $script:goodYaml
            $harness.Context.Variable['HDTComputerName'] = 'PC-0001'

            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                -State $harness.State -LogDestination '\\share\Logs' | Out-Null

            $harness.FileSystem.TestPath('\\share\Logs\PC-0001-run-0001') | Should -BeTrue
        }

        It 'copies them on failure too' {
            # DESIGN 4.4.1: "a deployment that dies is exactly when the logs
            # matter, and MDT's habit of stranding them on a wiped machine is a
            # real operational problem".
            $harness = & $script:armedHarness $script:badYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                -State $harness.State -LogDestination '\\share\Logs'

            $result.Status | Should -BeExactly 'Failed'
            @($harness.Journal | Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' }).Count |
                Should -BeGreaterThan 0
        }

        It 'does not fail the run when copy-back fails' {
            Mock -ModuleName Hephaestus -CommandName Copy-HDTLog -MockWith {
                throw [System.IO.IOException]::new('the share went away')
            }

            $harness = & $script:armedHarness $script:goodYaml
            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                -State $harness.State -LogDestination '\\share\Logs'

            $result.Status | Should -BeExactly 'Succeeded'
        }

        It 'copies nothing when no destination was given' {
            $harness = & $script:armedHarness $script:goodYaml
            Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State | Out-Null

            @($harness.Journal | Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' }).Count | Should -Be 0
        }
    }
}
