#
# run-20260830-221934 succeeded 15/15 on LT-D5M1NN3 and wrote its step logs
# twice - once on the machine, once live on the share. Steps 001-011, 013 and
# 014 came out byte for byte identical. 012 and 015 did not:
#
#   Steps\015-Tattoo.log   local  8194 bytes, ends "step 15 'Tattoo' completed"
#   Steps\015-Tattoo.log   share 10593 bytes, and carries on past the step with
#                                 run.end, the summary answer, the share
#                                 disconnect and the resume-agent sweep
#
# Every one of those four records says component="Engine" and file="Engine".
# They know they are engine-level. They were filed under the last step anyway,
# because ONE writer detached at the step boundary and the other did not.
#
# THE ASYMMETRY, EXACTLY. New-HDTLogContext has three methods that move the
# step: SetStep, SetDynamicPath and ClearStep. The first two recompute BOTH
# StepLogPath (local) and DynamicStepLogPath (mirror). ClearStep nulled the
# local one and left the mirror's pointing at the step that had just ended -
# so the mirror kept a writer open on a file the local copy had already closed.
#
# WHICH IS WHY IT IS THE LAST STEP OF A LEG AND NOT EVERY STEP. Between steps
# both paths are still step N's, on both copies, and they agree; the next
# SetStep moves both together. ClearStep runs once per leg, in
# Invoke-HDTTaskSequence's finally, so a three-leg deployment mis-files the
# tail of three step logs and looks clean everywhere else. 012 was leg two's
# last step, 015 was leg three's.
#
# THE PROPERTY, NOT THE FIXTURE. The last Context below drives the assertion
# off the SET of paths the mirror appended to and maps each one back to its
# machine-local twin, so a fourth mirrored surface - a second step log, a
# native-command transcript, whatever it is - either agrees with its twin or
# fails here. A test naming Steps\015-Tattoo.log would pass for the one file
# somebody remembered and for nothing after it.
#
# AND THE MIRROR IS ALLOWED TO BE SHORTER. HDTSLShareDynamicLogging resolves
# after the wizard, and the resume path connects the share mid-leg, so the
# machine-local log legitimately holds records written before the share was
# reachable. The property is therefore a SUFFIX check - the mirror is the tail
# of the local file - and never an equality that would tempt somebody to
# "fix" it by dropping local records.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # The share root as rules.yaml resolves it: a UNC, TEST-NET-1, computer name
    # already expanded. SetDynamicPath puts the run folder inside it.
    $script:share = '\\192.0.2.108\HDTShare\Logs\LT-D5M1NN3'

    # ONE LEG OF ONE RUN. A leg is a process: its own log root, its own phase,
    # its own filesystem. The run id is what spans them.
    $script:newLeg = {
        param(
            [string] $RunId = 'run-20260830-221934',
            [string] $Phase = 'FullOS',
            [string] $LogPath = 'C:\HDT\Logs'
        )

        $fileSystem = New-HDTFakeFileSystem

        $context = New-HDTLogContext -RunId $RunId -Phase $Phase -LogPath $LogPath `
            -FileSystem $fileSystem `
            -Clock (New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-30T22:19:34Z'))) `
            -ThreadId 13

        return [pscustomobject] @{
            Context    = $context
            FileSystem = $fileSystem
        }
    }

    # Every distinct path the mirror appended to, in the order it first touched
    # them. The SET of mirrored surfaces rather than the three this file happens
    # to name.
    $script:mirrorPath = {
        param([object] $FileSystem)

        return @($FileSystem.Operations |
                Where-Object { $_.Operation -eq 'AppendAllText' -and ([string] $_.Arguments[0]).StartsWith('\\') } |
                ForEach-Object { [string] $_.Arguments[0] } |
                Select-Object -Unique)
    }

    # The machine-local twin of a mirrored path: same leaf under the log root
    # instead of under the run folder on the share.
    $script:localTwin = {
        param([object] $Context, [string] $MirrorPath)

        $leaf = $MirrorPath.Substring(([string] $Context.DynamicPath).Length).TrimStart('\', '/')

        return '{0}\{1}' -f ([string] $Context.LogPath), $leaf
    }

    # THE PROPERTY, as a list of complaints. Empty means the two copies agree.
    # A complaint names the file and what it holds that its twin does not,
    # because "the mirror disagreed" is not something anybody can act on.
    $script:disagreement = {
        param([object] $Context, [object] $FileSystem)

        $complaint = New-Object System.Collections.Generic.List[string]

        foreach ($mirror in @(& $script:mirrorPath $FileSystem)) {
            $local = & $script:localTwin $Context $mirror

            if (-not $FileSystem.TestPath($local)) {
                $complaint.Add(("'{0}' was mirrored but '{1}' was never written" -f $mirror, $local))
                continue
            }

            $mirrorText = [string] $FileSystem.ReadAllText($mirror)
            $localText = [string] $FileSystem.ReadAllText($local)

            if (-not $localText.EndsWith($mirrorText)) {
                $complaint.Add(("'{0}' is not the tail of '{1}'" -f $mirror, $local))
            }
        }

        return @($complaint)
    }

    # The step log leaf both copies use, so a test names one file and the two
    # paths are composed from it. The names are the ones run-20260830-221934
    # actually wrote; Get-HDTStepLogName is private and its rule has its own
    # tests, so nothing here re-derives it.
    $script:stepLeaf = {
        param([string] $FileName)

        return 'Steps\{0}' -f $FileName
    }
}

Describe 'The live mirror detaches from a step when the machine-local log does' {

    Context 'the engine records that follow the last step of a leg' {

        # THE DEFECT, STATED. Four records after step 15 completed, every one of
        # them component="Engine", all four in the share's copy of the step log
        # and none of them in the machine's.
        It 'keeps them out of the mirrored copy of that step log' {
            $run = & $script:newLeg
            $run.Context.SetDynamicPath($script:share)

            $stepLog = 'C:\HDT\Logs\{0}' -f (& $script:stepLeaf '015-Tattoo.log')
            $run.Context.SetStep(15, 'Tattoo', 'Tattoo', $stepLog)
            Write-HDTLog -Context $run.Context -Message "step 15 'Tattoo' completed" -Event step.complete

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Event run.end `
                -Message 'Run run-20260830-221934 ended Succeeded: 13 completed, 0 failed, 2 skipped'

            $mirrored = [string] $run.FileSystem.ReadAllText(
                ('{0}\run-20260830-221934\{1}' -f $script:share, (& $script:stepLeaf '015-Tattoo.log')))

            $mirrored | Should -Match "step 15 'Tattoo' completed"
            $mirrored | Should -Not -Match 'ended Succeeded'
        }

        It 'leaves the two copies of that step log identical' {
            $run = & $script:newLeg
            $run.Context.SetDynamicPath($script:share)

            $stepLog = 'C:\HDT\Logs\{0}' -f (& $script:stepLeaf '015-Tattoo.log')
            $run.Context.SetStep(15, 'Tattoo', 'Tattoo', $stepLog)
            Write-HDTLog -Context $run.Context -Message "step 15 'Tattoo' completed" -Event step.complete

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Message 'the deployment share was disconnected'
            Write-HDTLog -Context $run.Context -Message 'the resume agent was swept'

            $mirrored = [string] $run.FileSystem.ReadAllText(
                ('{0}\run-20260830-221934\{1}' -f $script:share, (& $script:stepLeaf '015-Tattoo.log')))

            $mirrored | Should -BeExactly ([string] $run.FileSystem.ReadAllText($stepLog))
        }

        # THE FIELD ITSELF. SetStep and SetDynamicPath both recompute the pair;
        # ClearStep is the third door and it forgot the mirror's half.
        It 'clears the mirrored step log path along with the local one' {
            $run = & $script:newLeg
            $run.Context.SetDynamicPath($script:share)
            $run.Context.SetStep(15, 'Tattoo', 'Tattoo', ('C:\HDT\Logs\{0}' -f (& $script:stepLeaf '015-Tattoo.log')))

            [string] $run.Context.DynamicStepLogPath | Should -Not -BeNullOrEmpty -Because 'the mirror must have been attached for the clear to mean anything'

            $run.Context.ClearStep()

            [string] $run.Context.StepLogPath | Should -BeNullOrEmpty
            [string] $run.Context.DynamicStepLogPath | Should -BeNullOrEmpty
        }
    }

    Context 'however the run ended' {

        # ALL THREE ARE PATHS THAT EMIT AFTER A STEP. Succeeded and Failed both
        # fall through Invoke-HDTTaskSequence's finally to teardown, run.end and
        # the verdict heartbeat; RebootPending skips teardown and still writes
        # the heartbeat - which is the record that landed in the share's
        # 012-Restart-before-second-application-pass.log twice and the machine's
        # once.
        It 'files nothing after the last step under it: <Status>' -TestCases @(
            @{ Status = 'Succeeded'; Verdict = 'Run run-20260830-221934 ended Succeeded: 13 completed, 0 failed, 2 skipped' }
            @{ Status = 'Failed'; Verdict = 'Run run-20260830-221934 ended Failed: 8 completed, 1 failed, 0 skipped' }
            @{ Status = 'RebootPending'; Verdict = 'run status is RebootPending at step 12 of 15' }
        ) {
            param([string] $Status, [string] $Verdict)

            $run = & $script:newLeg
            $run.Context.SetDynamicPath($script:share)

            $stepLog = 'C:\HDT\Logs\{0}' -f (& $script:stepLeaf '012-Restart-before-second-application-pass.log')
            $run.Context.SetStep(12, 'Restart before second application pass', 'Restart', $stepLog)
            Write-HDTLog -Context $run.Context -Message 'the machine was armed for one more leg'

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Message $Verdict

            $mirrored = [string] $run.FileSystem.ReadAllText(
                ('{0}\run-20260830-221934\{1}' -f $script:share,
                    (& $script:stepLeaf '012-Restart-before-second-application-pass.log')))

            $mirrored | Should -Not -Match ([regex]::Escape($Verdict))
            $mirrored | Should -BeExactly ([string] $run.FileSystem.ReadAllText($stepLog))
        }
    }

    Context 'on every leg of a multi-leg run' {

        # THE REPORTED RUN HAD THREE. Leg 1 is WinPE on the RAM disk, legs 2 and
        # 3 are the full OS on C:, and all three end by clearing the step and
        # writing records after it. A fix proved on the leg somebody looked at
        # is a fix for one third of the deployment.
        It 'detaches at the end of leg <Leg>' -TestCases @(
            @{ Leg = 1; Phase = 'WinPE'; LogPath = 'X:\HDT\Logs'; Index = 10; Name = 'Restart into Windows'; Type = 'Restart'; Leaf = '010-Restart-into-Windows.log' }
            @{ Leg = 2; Phase = 'FullOS'; LogPath = 'C:\HDT\Logs'; Index = 12; Name = 'Restart before second application pass'; Type = 'Restart'; Leaf = '012-Restart-before-second-application-pass.log' }
            @{ Leg = 3; Phase = 'FullOS'; LogPath = 'C:\HDT\Logs'; Index = 15; Name = 'Tattoo'; Type = 'Tattoo'; Leaf = '015-Tattoo.log' }
        ) {
            param([int] $Leg, [string] $Phase, [string] $LogPath, [int] $Index, [string] $Name, [string] $Type, [string] $Leaf)

            $run = & $script:newLeg 'run-20260830-221934' $Phase $LogPath
            $run.Context.SetDynamicPath($script:share)

            $stepLog = '{0}\{1}' -f $LogPath, (& $script:stepLeaf $Leaf)
            $run.Context.SetStep($Index, $Name, $Type, $stepLog)
            Write-HDTLog -Context $run.Context -Message ("step {0} '{1}' completed" -f $Index, $Name) -Event step.complete

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Message ('leg {0} handed the deployment on' -f $Leg)

            $mirrored = [string] $run.FileSystem.ReadAllText(
                ('{0}\run-20260830-221934\{1}' -f $script:share, (& $script:stepLeaf $Leaf)))

            $mirrored | Should -Not -Match 'handed the deployment on'
            $mirrored | Should -BeExactly ([string] $run.FileSystem.ReadAllText($stepLog))
        }
    }

    Context 'the two copies of a run, as a property' {

        # DRIVEN OFF THE SET. Every path the mirror appended to is mapped back to
        # its machine-local twin and has to be the tail of it. It does not name
        # HDT.log, HDT.jsonl or any step file, so a mirrored surface added later
        # is covered the day it is added.
        It 'never holds a record its machine-local twin does not' {
            $run = & $script:newLeg
            $run.Context.SetDynamicPath($script:share)

            $step = @(
                @{ Index = 13; Name = 'Install Applications second pass'; Type = 'InstallApplications'; Leaf = '013-Install-Applications-second-pass.log' }
                @{ Index = 14; Name = 'Show all notification area icons'; Type = 'RunCommand'; Leaf = '014-Show-all-notification-area-icons.log' }
                @{ Index = 15; Name = 'Tattoo'; Type = 'Tattoo'; Leaf = '015-Tattoo.log' }
            )

            foreach ($current in $step) {
                $stepLog = 'C:\HDT\Logs\{0}' -f (& $script:stepLeaf $current.Leaf)

                $run.Context.SetStep($current.Index, $current.Name, $current.Type, $stepLog)
                Write-HDTLog -Context $run.Context -Message ("step {0} '{1}' started" -f $current.Index, $current.Name) -Event step.start
                Write-HDTLog -Context $run.Context -Message ("step {0} '{1}' completed" -f $current.Index, $current.Name) -Event step.complete

                # BETWEEN TWO STEPS, which is the boundary nobody looked at: the
                # engine writes here fifteen times a run, and if the mirror files
                # these somewhere the local copy does not, the same defect is
                # happening all the way down the log rather than once at the end.
                Write-HDTLog -Context $run.Context -Message ('the engine moved on from step {0}' -f $current.Index)
            }

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Event run.end `
                -Message 'Run run-20260830-221934 ended Succeeded: 13 completed, 0 failed, 2 skipped'
            Write-HDTLog -Context $run.Context -Message 'the deployment summary was answered: Finish'
            Write-HDTLog -Context $run.Context -Message 'the deployment share was disconnected'
            Write-HDTLog -Context $run.Context -Message 'the resume agent was swept'

            $mirrored = @(& $script:mirrorPath $run.FileSystem)

            $mirrored.Count | Should -BeGreaterThan 4 -Because 'a mirror that wrote nowhere would satisfy the assertion below vacuously'

            (@(& $script:disagreement $run.Context $run.FileSystem) -join '; ') | Should -BeExactly ''
        }

        # THE ONE DIFFERENCE THAT IS ALLOWED, AND IT IS LOCAL-ONLY. The share is
        # not reachable when the context is built - HDTSLShareDynamicLogging
        # resolves after the wizard, and the resume path connects mid-leg - so
        # the machine keeps records the share cannot have. That is the mirror
        # being shorter, never the local copy being quieter.
        It 'stays the tail of a local log that started before the share was reachable' {
            $run = & $script:newLeg

            Write-HDTLog -Context $run.Context -Message 'the deployment share is being connected'
            $run.Context.SetDynamicPath($script:share)
            Write-HDTLog -Context $run.Context -Message 'the deployment share was connected'

            $stepLog = 'C:\HDT\Logs\{0}' -f (& $script:stepLeaf '011-Install-Applications.log')
            $run.Context.SetStep(11, 'Install Applications', 'InstallApplications', $stepLog)
            Write-HDTLog -Context $run.Context -Message 'installing 7-Zip'

            $run.Context.ClearStep()
            Write-HDTLog -Context $run.Context -Message 'the resume agent was swept'

            (@(& $script:disagreement $run.Context $run.FileSystem) -join '; ') | Should -BeExactly ''

            $local = [string] $run.FileSystem.ReadAllText('C:\HDT\Logs\HDT.log')
            $mirror = [string] $run.FileSystem.ReadAllText(
                ('{0}\run-20260830-221934\HDT.log' -f $script:share))

            $local | Should -Match 'the deployment share is being connected'
            $mirror | Should -Not -Match 'the deployment share is being connected' -Because 'the share cannot hold what was written before it was reachable'
            $mirror | Should -Match 'the resume agent was swept'
        }
    }
}
