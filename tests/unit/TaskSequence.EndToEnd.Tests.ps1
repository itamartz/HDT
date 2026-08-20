# THE DESIGN 12.2.1 HEADLINE TEST, and ROADMAP M2's exit criterion:
#
#   "the entire task sequence engine can execute a full sequence end-to-end in a
#    Pester run against fake services, asserting the ordered list of operations
#    it WOULD have performed. That test is the safety net for every refactor
#    after it."
#
#   "Exit: a multi-group sequence with reboots runs to completion in a Pester
#    run, with a readable report, having touched nothing real."
#
# The sequence is samples/workspace/TaskSequences/DEMO-M2/sequence.yaml, read off
# disk and seeded into the fake filesystem as TEXT - the trick
# GatherAndResolve.EndToEnd.Tests.ps1 already uses - so the sample an
# administrator copies and the sequence this test proves can never drift apart.
#
# THREE LEGS, ONE MACHINE. Every service double is built once and shared across
# all three legs, because that is what a machine is: the registry the first leg
# armed is the registry the third leg tears down. Between legs the state document
# goes back through the FILE, and the leg begins the way a real one does - with
# Invoke-HDTBootReconciliation, exactly as Start-HDTResume.ps1 calls it.
#
# The log directory MOVES with the phase (DESIGN 4.4.1: X:\HDT\Logs in WinPE,
# C:\HDT\Logs in the full OS), and the master log, the state and the heartbeat are
# carried forward at the transition - "mirrored, so the WinPE->OS transition keeps
# history". The engine does not do that carry-forward itself yet; the phase that
# formats a volume owns it (phase 04). Doing it here is what makes the JSONL one
# physical stream across all three legs, which is what the seq assertion and the
# report are about.
#
# WHY THE OPERATION LIST IS FILTERED. Log writes dominate the journal by volume -
# thousands of AppendAllText calls - so the headline assertion keeps the services
# whose operations are SIDE EFFECTS ON A MACHINE: the registry, the LSA store, the
# power service, the process service and the script invoker. The filesystem is
# asserted separately. An unfiltered list would break on every added log line,
# which makes it a list nobody maintains and therefore nobody trusts.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:samplePath = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences/DEMO-M2/sequence.yaml'
    $script:sampleYaml = Get-Content -LiteralPath $script:samplePath -Raw

    $script:runId = 'run-demo-m2'
    $script:computerName = 'PC-FIXTURE-SERIAL-0001'
    $script:workspaceRoot = 'C:\ws'
    $script:sequencePath = 'C:\ws\TaskSequences\DEMO-M2\sequence.yaml'
    $script:scriptPath = 'C:\ws\Scripts\Set-CorpBaseline.ps1'
    $script:winpeLog = 'X:\HDT\Logs'
    $script:fullosLog = 'C:\HDT\Logs'
    $script:winpeState = 'X:\HDT\Logs\state.json'
    $script:fullosState = 'C:\HDT\Logs\state.json'
    $script:jsonlPath = 'C:\HDT\Logs\HDT.jsonl'
    $script:reportPath = 'C:\HDT\Logs\report.html'

    $script:sideEffectService = @('RegistryService', 'LsaService', 'PowerService', 'ProcessService', 'ScriptInvoker')

    # -- one machine's worth of doubles, built once -----------------------

    $script:journal = [System.Collections.ArrayList]::new()

    $script:fs = New-HDTFakeFileSystem -File @{ $script:sequencePath = $script:sampleYaml }
    $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250
    $script:registry = New-HDTFakeRegistryService
    $script:lsa = New-HDTFakeLsaService
    $script:power = New-HDTFakePowerService
    $script:process = New-HDTFakeProcessService -Result @{
        'cmd.exe /c echo HDT demo installer' = @{ ExitCode = 0; StandardOutput = 'HDT demo installer' }
    }
    $script:invoker = New-HDTFakeScriptInvoker -Result @{ $script:scriptPath = $null } -Transcript @{
        $script:scriptPath = @('applying corporate baseline to PC-FIXTURE-SERIAL-0001')
    }
    $script:cim = New-HDTFakeCimProvider
    $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }

    $script:catalog = New-HDTServiceCatalog -FileSystem $script:fs -Clock $script:clock -Registry $script:registry `
        -Lsa $script:lsa -Process $script:process -Power $script:power -ScriptInvoker $script:invoker `
        -Cim $script:cim -Environment $script:environment

    # THE JOURNAL GOES ON LAST, after every seed, so its first entry is the
    # first thing the ENGINE did (tests/helpers/README.md section 4).
    foreach ($fake in @($script:fs, $script:clock, $script:registry, $script:lsa, $script:process,
            $script:power, $script:invoker, $script:cim, $script:environment)) {

        $fake.Journal = $script:journal
    }

    # -- the legs ----------------------------------------------------------

    $script:startVariable = {
        param([object] $Sequence)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($Sequence.Variable.Keys)) {
            $live[[string] $name] = $Sequence.Variable[$name]
        }

        # DESIGN 3.1 source 1: what the rules resolved before the sequence began.
        $live['HDTComputerName'] = $script:computerName

        # THE ONE PASSWORD (DESIGN 4.5.2). The engine arms autologon with it and
        # the unattend gives it to the Administrator account; a sequence that
        # reboots without one is refused, because there would be nothing to come
        # back with.
        $live['HDTAdminPassword'] = $script:adminPassword

        return $live
    }

    # The first leg: a fresh run in WinPE, out of the boot image.
    $script:adminPassword = 'E2E-Admin-P@ssw0rd'

    $script:runFirstLeg = {
        $sequence = Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $script:fs
        $live = & $script:startVariable $sequence

        $log = New-HDTLogContext -RunId $script:runId -Phase 'WinPE' -LogPath $script:winpeLog `
            -FileSystem $script:fs -Clock $script:clock -Level Debug -ThreadId 1

        $state = New-HDTRunState -SequenceId $sequence.Id -RunId $script:runId -Phase 'WinPE' `
            -Clock $script:clock -Variable $live -Step $sequence.Step

        $context = New-HDTExecutionContext -RunId $script:runId -Phase 'WinPE' -WorkspaceRoot $script:workspaceRoot `
            -Variable $live -Service $script:catalog -Log $log -State $state

        $result = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state

        return [pscustomobject] @{
            Result   = $result
            Log      = $log
            Variable = $live
        }
    }

    # Every leg after a reboot, driven exactly as Start-HDTResume.ps1 drives it:
    # a boot log context, the reconcile FIRST (DESIGN 4.5.2), then the loop with
    # the state the reconcile handed back.
    $script:runNextLeg = {
        param([string] $LogPath, [string] $StatePath)

        # The boot log continues the JSONL numbering rather than restarting it:
        # the reconcile's own reboot.resume record is part of the same stream.
        $bootSeq = [long] 0
        if ($script:fs.TestPath($StatePath)) {
            $bootSeq = [long] (ConvertFrom-Json -InputObject $script:fs.ReadAllText($StatePath)).seq
        }

        $bootLog = New-HDTLogContext -RunId 'boot' -Phase 'FullOS' -LogPath $LogPath `
            -FileSystem $script:fs -Clock $script:clock -Level Debug -Seq $bootSeq -ThreadId 1

        $decision = Invoke-HDTBootReconciliation -StatePath $StatePath -FileSystem $script:fs `
            -Registry $script:registry -Lsa $script:lsa -Clock $script:clock -LogContext $bootLog

        $state = $decision.State

        $sequence = Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $script:fs

        $live = & $script:startVariable $sequence
        foreach ($name in @($state.variable.Keys)) {
            $live[[string] $name] = $state.variable[$name]
        }

        $log = New-HDTLogContext -RunId ([string] $state.runId) -Phase 'FullOS' -LogPath $LogPath `
            -FileSystem $script:fs -Clock $script:clock -Level Debug -Seq ([long] $bootLog.Seq) -ThreadId 1

        $context = New-HDTExecutionContext -RunId ([string] $state.runId) -Phase 'FullOS' `
            -WorkspaceRoot $script:workspaceRoot -Variable $live -Service $script:catalog -Log $log -State $state

        # SNAPSHOTTED BEFORE THE RUN. The loop mutates the very state object the
        # reconcile handed back, so reading these afterwards would report where
        # the leg ENDED and quietly prove nothing about where it resumed.
        $resumeIndex = [int] $state.stepIndex
        $resumeStage = [string] $state.variable['HDTInstallStage']

        $result = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state

        return [pscustomobject] @{
            Decision    = $decision
            Result      = $result
            Log         = $log
            Variable    = $live
            ResumeIndex = $resumeIndex
            ResumeStage = $resumeStage
        }
    }

    # DESIGN 4.4.1: _HDTLogPath follows the deployment, and the history follows
    # it too. The engine does not do this yet - the phase that formats a volume
    # owns it - so the test does what the transition will.
    $script:carryLogForward = {
        param([string] $From, [string] $To)

        foreach ($name in @('HDT.jsonl', 'HDT.log', 'status.json', 'state.json')) {
            $source = '{0}\{1}' -f $From, $name
            if ($script:fs.TestPath($source)) {
                # Seeded, not written: this is the test standing in for a step
                # that does not exist yet, and it must not appear in the journal
                # as something the engine did.
                $script:fs.SeedFile(('{0}\{1}' -f $To, $name), $script:fs.ReadAllText($source))
            }
        }
    }

    $script:stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $script:leg1 = & $script:runFirstLeg

    # THE ONE PASSWORD, taken from the variables rather than from a state field.
    # The engine no longer mints a per-deployment secret (DESIGN 4.5.2): it arms
    # autologon with HDTAdminPassword, which is what the unattend gave the
    # Administrator account. The assertions below still check it never reaches a
    # log or a report.
    $script:deploymentPassword = [string] $script:leg1.Variable['HDTAdminPassword']

    & $script:carryLogForward $script:winpeLog $script:fullosLog

    $script:leg2 = & $script:runNextLeg $script:fullosLog $script:fullosState
    $script:leg2StageOnEntry = [string] $script:leg2.ResumeStage

    $script:leg3 = & $script:runNextLeg $script:fullosLog $script:fullosState
    $script:leg3StepOnEntry = [int] $script:leg3.ResumeIndex

    $script:stopwatch.Stop()
    $script:elapsedSecond = $script:stopwatch.Elapsed.TotalSeconds

    # Everything below reads the run rather than driving it. The journal
    # assertions are written first in the file for a reason: these reads are
    # recorded too.
    $script:operation = @($script:journal |
            Where-Object { $script:sideEffectService -contains $_.Service } |
            ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })

    # state.json only: the same journal carries every status.json heartbeat and
    # every report, and those documents have no step array at all.
    $script:stateWrite = @($script:journal |
            Where-Object {
                $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and
                @($script:winpeState, $script:fullosState) -contains [string] $_.Arguments[0]
            })

    $script:finalState = $script:leg3.Result.State
    $script:record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:jsonlPath)
    $script:rawLog = [string] (Get-HDTLogRecord -FileSystem $script:fs -Path $script:jsonlPath -Raw)
}

Describe 'the DEMO-M2 task sequence, end to end against fakes' {

    Context 'the run completed' {

        It 'ends the first leg with a reboot pending' {
            $script:leg1.Result.Status | Should -BeExactly 'RebootPending'
        }

        It 'ends the second leg with a reboot pending' {
            $script:leg2.Result.Status | Should -BeExactly 'RebootPending'
        }

        It 'ends the third leg Succeeded' {
            $script:leg3.Result.Status | Should -BeExactly 'Succeeded'
            $script:finalState.status | Should -BeExactly 'Succeeded'
        }

        It 'restarted exactly twice' {
            @($script:power.GetOperationName()) | Should -Be @('Restart', 'Restart')
        }

        It 'ran three legs' {
            $script:finalState.leg | Should -Be 3
        }
    }

    Context 'the exact ordered operation list' {

        It 'performed exactly these operations, in this order' {
            # DESIGN 12.2.1. THIS LIST IS THE SPECIFICATION OF WHAT HDT DOES TO A
            # MACHINE. A future refactor that changes it announces itself as a
            # diff here, which is the entire point of writing it out in full.
            $script:operation | Should -Be @(

                # -- leg 1, in WinPE: Preinstall runs, the first Restart arms ---
                'RegistryService.SetValue'      # Winlogon AutoAdminLogon = 1
                'RegistryService.SetValue'      # Winlogon DefaultUserName = Administrator
                'RegistryService.SetValue'      # Winlogon DefaultDomainName (empty: a workgroup machine mid-build)
                'RegistryService.SetValue'      # Winlogon AutoLogonCount = 2, the legs still to come
                'RegistryService.RemoveValue'   # any registry DefaultPassword, unconditionally and defensively
                'LsaService.SetSecret'          # the per-deployment password, as an LSA secret (DESIGN 4.5.2)
                'RegistryService.SetValue'      # RunOnce\HDTResume
                'PowerService.Restart'

                # -- leg 2, in the full OS: the installer, then the second Restart
                'ProcessService.Start'          # cmd.exe /c echo HDT demo installer
                'RegistryService.SetValue'      # AutoAdminLogon
                'RegistryService.SetValue'      # DefaultUserName
                'RegistryService.SetValue'      # DefaultDomainName
                'RegistryService.SetValue'      # AutoLogonCount = 1, the last leg
                'RegistryService.RemoveValue'   # the registry DefaultPassword again
                'LsaService.SetSecret'          # the SAME password: one machine, one secret per run
                'RegistryService.SetValue'      # RunOnce\HDTResume, re-registered every leg
                'PowerService.Restart'

                # -- leg 3: the user script, then the DESIGN 4.5.3 teardown -----
                'ScriptInvoker.Invoke'          # Scripts\Set-CorpBaseline.ps1
                'RegistryService.GetValue'      # AutoAdminLogon - present
                'RegistryService.RemoveValue'
                'RegistryService.GetValue'      # DefaultUserName - present
                'RegistryService.RemoveValue'
                'RegistryService.GetValue'      # DefaultDomainName - present
                'RegistryService.RemoveValue'
                'RegistryService.GetValue'      # DefaultPassword - ABSENT, so nothing to remove
                'RegistryService.GetValue'      # AutoLogonCount - present
                'RegistryService.RemoveValue'
                'LsaService.GetSecret'          # the secret itself, never behind an earlier item's failure
                'LsaService.RemoveSecret'
                'RegistryService.GetValue'      # RunOnce\HDTResume
                'RegistryService.RemoveValue'
            )
        }

        It 'started exactly one process' {
            @($script:process.GetOperationName()) | Should -Be @('Start')
            $script:process.Operations[0].Arguments[0] | Should -BeExactly 'cmd.exe'
            $script:process.Operations[0].Arguments[1] | Should -BeExactly '/c echo HDT demo installer'
        }

        It 'invoked exactly one user script' {
            @($script:invoker.GetOperationName()) | Should -Be @('Invoke')
            $script:invoker.Operations[0].Arguments[0] | Should -BeExactly $script:scriptPath
        }

        It 'wrote the state document at every checkpoint' {
            # Checkpoints bracket every step: one when it is marked Running and
            # one when its outcome is known. Leg 1: four steps x 2, plus the
            # save after arming, the finally save and the seq-only save after
            # run.end = 11. Leg 2: three steps x 2 plus those same three = 9.
            # Leg 3: three steps that ran x 2, three that were skipped x 1, the
            # finally save and the teardown's own save = 11. Both full-OS legs
            # write the same file, so 9 + 11 = 20.
            @($script:stateWrite | Where-Object { $_.Arguments[0] -eq $script:winpeState }).Count | Should -Be 11
            @($script:stateWrite | Where-Object { $_.Arguments[0] -eq $script:fullosState }).Count | Should -Be 20
        }

        It 'checkpointed every step as Running before it ran' {
            # The property that makes an interrupted step detectable at all.
            $ran = @(1, 2, 3, 4, 5, 6, 7, 8, 10, 11)

            $runningIndex = @($script:stateWrite | ForEach-Object {
                    $document = ConvertFrom-Json -InputObject ([string] $_.Arguments[1])
                    @($document.step | Where-Object { $_.status -eq 'Running' } | ForEach-Object { [int] $_.index })
                } | Select-Object -Unique | Sort-Object)

            $runningIndex | Should -Be $ran
        }
    }

    Context 'every step, exactly once' {

        It 'completed every step that should have run' {
            @($script:finalState.step | Where-Object { $_.status -eq 'Completed' } | ForEach-Object { [string] $_.name }) |
                Should -Be @(
                    'Announce',
                    'Record Stage',
                    'Flaky Preflight',
                    'Reboot Into Install',
                    'Record Stage',
                    'Run Installer',
                    'Reboot After Install',
                    'Corp Baseline',
                    'Finish')
        }

        It 'accounts for every step exactly once' {
            @($script:finalState.step | ForEach-Object { [string] $_.status }) | Should -Be @(
                'Completed',   # 1  Announce
                'Completed',   # 2  Record Stage
                'Completed',   # 3  Flaky Preflight (second attempt)
                'Completed',   # 4  Reboot Into Install
                'Completed',   # 5  Record Stage
                'Completed',   # 6  Run Installer
                'Completed',   # 7  Reboot After Install
                'Completed',   # 8  Corp Baseline
                'Skipped',     # 9  WinPE Only Task - the phase filter
                'Failed',      # 10 Optional Task - tolerated by continueOnError
                'Completed',   # 11 Finish
                'Skipped',     # 12 Install Roles Placeholder - the group condition
                'Skipped')     # 13 Configure Roles Placeholder - the same one
        }

        It 'ran no step twice' {
            # By INDEX, not by name: two different steps in this sequence are
            # both called 'Record Stage', which is exactly what an admin does.
            # Component Engine, because a step type may write its own
            # step.complete too - the PowerShell step does.
            $completed = @($script:record |
                    Where-Object { $_.event -eq 'step.complete' -and $_.component -eq 'Engine' } |
                    ForEach-Object { [int] $_.stepIndex })

            @($completed | Select-Object -Unique).Count | Should -Be $completed.Count
        }

        It 'skipped WinPE Only Task on phase' {
            $row = @($script:leg3.Result.Result | Where-Object { $_.Name -eq 'WinPE Only Task' })[0]

            $row.Status | Should -BeExactly 'Skipped'
            $row.Reason | Should -BeLike '*runIn WinPE*'
        }

        It 'skipped both Server Only steps, naming the group' {
            $skipped = @($script:leg3.Result.Result | Where-Object { $_.Index -ge 12 })

            $skipped.Count | Should -Be 2
            foreach ($row in $skipped) {
                $row.Status | Should -BeExactly 'Skipped'
                $row.Reason | Should -BeLike "*the group 'Server Only' is skipped*"
            }
        }

        It 'retried Flaky Preflight once and succeeded on the second attempt' {
            # failAttempt: 1 with retry.count: 2 is TWO attempts, not three. The
            # number is asserted from the state so it is a claim about the
            # engine rather than a phrase in a test name.
            $step = @($script:finalState.step | Where-Object { $_.index -eq 3 })[0]

            $step.attempt | Should -Be 2
            $step.status | Should -BeExactly 'Completed'
        }

        It 'tolerated Optional Task and carried on' {
            @($script:finalState.step | Where-Object { $_.index -eq 10 })[0].status | Should -BeExactly 'Failed'
            @($script:finalState.step | Where-Object { $_.index -eq 11 })[0].status | Should -BeExactly 'Completed'
            $script:leg3.Result.Status | Should -BeExactly 'Succeeded'
        }

        It 'resumed the second leg at Record Stage' {
            $ran = @($script:leg2.Result.Result | Where-Object { $_.Status -ne 'Skipped' })[0]

            $ran.Index | Should -Be 5
            $ran.Name | Should -BeExactly 'Record Stage'
        }

        It 'resumed the third leg at Corp Baseline' {
            $script:leg3StepOnEntry | Should -Be 8

            $ran = @($script:leg3.Result.Result | Where-Object { $_.Status -ne 'Skipped' })[0]
            $ran.Name | Should -BeExactly 'Corp Baseline'
        }
    }

    Context 'the variables' {

        It 'carried HDTInstallStage from leg one into leg two' {
            # Read from the state the reconcile handed over, BEFORE leg two's own
            # SetVariable step overwrote it.
            $script:leg2StageOnEntry | Should -BeExactly 'preinstall'
        }

        It 'set it to install in leg two' {
            $script:leg2.Result.State.variable['HDTInstallStage'] | Should -BeExactly 'install'
        }

        It 'evaluated the Install group condition against the value leg one set' {
            # '"%HDTInstallStage%" != "skip"' was true, so nothing under Install
            # was skipped on the group.
            @($script:record | Where-Object { $_.event -eq 'step.skip' -and $_.message -like "*group 'Install'*" }).Count |
                Should -Be 0

            @($script:finalState.step | Where-Object { $_.index -eq 5 })[0].status | Should -BeExactly 'Completed'
        }

        It 'logged a var.resolve record for every SetVariable step' {
            $resolve = @($script:record | Where-Object { $_.event -eq 'var.resolve' })

            $resolve.Count | Should -Be 2
            @($resolve | ForEach-Object { [string] $_.data.value }) | Should -Be @('preinstall', 'install')
        }
    }

    Context 'the log' {

        It 'increases seq strictly across all three legs' {
            $seq = @($script:record | ForEach-Object { [long] $_.seq })

            $seq[0] | Should -Be 1
            $seq | Should -Be @(1..$seq.Count)
        }

        It 'restarts seq nowhere' {
            $seq = @($script:record | ForEach-Object { [long] $_.seq })

            @($seq | Select-Object -Unique).Count | Should -Be $seq.Count
        }

        It 'logs run.start once per leg and run.end once per leg' {
            @($script:record | Where-Object { $_.event -eq 'run.start' }).Count | Should -Be 3
            @($script:record | Where-Object { $_.event -eq 'run.end' }).Count | Should -Be 3
        }

        It 'logs two reboot.arm records and two reboot.resume records' {
            @($script:record | Where-Object { $_.event -eq 'reboot.arm' }).Count | Should -Be 2
            @($script:record | Where-Object { $_.event -eq 'reboot.resume' }).Count | Should -Be 2
        }

        It 'wrote a numbered per-step log for every step that ran' {
            # DESIGN 4.4: "the directory listing itself tells you the sequence".
            foreach ($name in @('001-Announce.log', '002-Record-Stage.log', '003-Flaky-Preflight.log', '004-Reboot-Into-Install.log')) {
                $script:fs.TestPath(('{0}\Steps\{1}' -f $script:winpeLog, $name)) | Should -BeTrue -Because "leg 1 wrote $name"
            }

            foreach ($name in @('005-Record-Stage.log', '006-Run-Installer.log', '007-Reboot-After-Install.log',
                    '008-Corp-Baseline.log', '010-Optional-Task.log', '011-Finish.log')) {

                $script:fs.TestPath(('{0}\Steps\{1}' -f $script:fullosLog, $name)) | Should -BeTrue -Because "the full OS legs wrote $name"
            }
        }

        It 'captured the user script transcript into its step log' {
            # DESIGN 4.4.4: a script that only uses Write-Host still lands in the
            # log, because real fleets carry years of them.
            $stepLog = $script:fs.ReadAllText(('{0}\Steps\008-Corp-Baseline.log' -f $script:fullosLog))

            $stepLog | Should -BeLike '*applying corporate baseline*'
        }
    }

    Context 'the machine is left clean' {

        It 'leaves no autologon artifact' {
            # The ROADMAP M2 assertion, in the headline test as well as in 03-03
            # and 03-04.
            Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa `
                -FileSystem $script:fs -State $script:finalState | Should -BeNullOrEmpty
        }

        It 'nulls the deployment password in the final state' {
            $script:deploymentPassword | Should -Not -BeNullOrEmpty
            $script:finalState.PSObject.Properties['deploymentPassword'] | Should -BeNullOrEmpty
        }

        It 'never wrote the password into the log' {
            $script:rawLog | Should -Not -BeLike ('*{0}*' -f $script:deploymentPassword)
        }

        It 'never wrote DefaultPassword to the registry' {
            $written = @($script:journal | Where-Object {
                    $_.Service -eq 'RegistryService' -and $_.Operation -eq 'SetValue' -and
                    [string] $_.Arguments[1] -eq 'DefaultPassword'
                })

            $written.Count | Should -Be 0
            $script:registry.GetValue('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'DefaultPassword') |
                Should -BeNullOrEmpty
        }
    }

    Context 'it touched nothing real' {

        It 'started no real process' {
            @($script:process.GetOperationName()).Count | Should -Be 1
        }

        It 'rebooted nothing' {
            @($script:power.GetOperationName()).Count | Should -Be 2
        }

        It 'wrote no file to the real disk' {
            foreach ($path in @('X:\HDT\Logs\HDT.jsonl', 'C:\HDT\Logs\HDT.jsonl', 'C:\HDT\Logs\state.json', 'C:\ws\TaskSequences')) {
                Test-Path -LiteralPath $path | Should -BeFalse -Because "$path exists only inside the fake"
            }
        }

        It 'touched no real registry key' {
            $runOnce = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue

            if ($null -ne $runOnce) {
                $runOnce.PSObject.Properties['HDTResume'] | Should -BeNullOrEmpty
            }

            $winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
            if ($null -ne $winlogon) {
                $winlogon.PSObject.Properties['AutoLogonCount'] | Should -BeNullOrEmpty
            }
        }

        It 'ran the whole deployment in seconds, not minutes' {
            # DEMO-M2 configures five seconds of retry backoff and two machine
            # restarts. If any of it were real this number would not be small,
            # so the wall clock is itself evidence for the claim above.
            $script:elapsedSecond | Should -BeLessThan 15
        }

        It 'ran no real script' {
            # The sample script writes one Write-Host line. It never executed:
            # the invoker is a double, and the transcript came from a seed.
            @($script:invoker.GetOperationName()).Count | Should -Be 1
        }
    }

    Context 'the report' {

        BeforeAll {
            $script:reportWritten = ConvertTo-HDTReport -JsonlPath $script:jsonlPath -Path $script:reportPath `
                -FileSystem $script:fs -State $script:finalState -Title 'DEMO-M2 deployment report'

            $script:html = $script:fs.ReadAllText($script:reportPath)
        }

        It 'renders a report from the run' {
            $script:reportWritten | Should -BeExactly $script:reportPath
            $script:html | Should -Match '<!DOCTYPE html>'
        }

        It 'names every step in the report' {
            foreach ($name in @('Announce', 'Record Stage', 'Flaky Preflight', 'Reboot Into Install', 'Run Installer',
                    'Corp Baseline', 'WinPE Only Task', 'Optional Task', 'Finish', 'Install Roles Placeholder')) {

                $script:html | Should -BeLike ('*{0}*' -f $name) -Because "the report has to name $name"
            }
        }

        It 'shows the group each step belongs to' {
            # End to end, this proves the state document carried the flattener's
            # GroupPath: the report has no other source for it.
            foreach ($group in @('Preinstall', 'Install', 'State Restore', 'Server Only')) {
                $script:html | Should -BeLike ('*<td>{0}</td>*' -f $group) -Because "the report has to place a step in $group"
            }
        }

        It 'shows the run as succeeded' {
            $script:html | Should -Match 'Succeeded'
        }

        It 'shows both reboots' {
            @([regex]::Matches($script:html, 'reboot\.arm')).Count | Should -BeGreaterOrEqual 2
            @([regex]::Matches($script:html, 'reboot\.resume')).Count | Should -BeGreaterOrEqual 2
        }

        It 'contains no deployment password' {
            $script:html | Should -Not -BeLike ('*{0}*' -f $script:deploymentPassword)
        }
    }
}
