# THE GUARD THAT MAKES "A RESUMED WinPE LEG NEVER PARTITIONS" STRUCTURAL.
#
# Get-HDTResumeCandidate decides that a run is in progress; this is what stops
# the leg it hands over doing damage anyway.
#
# POSITION ALONE IS NOT A GUARANTEE, WHICH IS THE WHOLE REASON THIS EXISTS. A
# resumed leg continues at state.stepIndex, and on a real capture leg that index
# is past the partition step, so the loop skips it as already Completed. But
# stepIndex is a number in a JSON file on a disk that has just been sysprepped,
# power-cycled and re-enumerated. A document that survived a half-write, an
# engine that wrote it before a schema changed, or a hand edit by somebody
# debugging can all put that number back at 1 - and the failure is a formatted
# disk, so "the index will be right" is not a strong enough argument.
#
# SO IT REFUSES, RATHER THAN SKIPPING. A skip would be quieter and would let the
# capture go on to run against whatever happened to be on the disk. A resumed
# leg that REACHES a partition step has a defect in it, and the step failing is
# how anybody finds out.
#
# AND IT IS ASSERTED AGAINST THE SET, NOT AGAINST DiskPartition (CLAUDE.md 8).
# The forbidden types come from one function, and the test below walks it - so a
# destructive step type added next year is covered by construction rather than
# by somebody remembering this file exists.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:captureYaml = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences/valid-capture-legs.yaml') -Raw

    # A leg. -Resumed is passed through so one helper drives both the ordinary
    # WinPE leg and the resumed one, and the difference between them is the
    # switch rather than two code paths in the test.
    $script:runLeg = {
        param([object] $FileSystem, [string] $StateJson, [string] $Phase, [switch] $Resumed, [hashtable] $Variable)

        $argument = @{ Yaml = $script:captureYaml; Phase = $Phase }
        if ($null -ne $FileSystem) { $argument['FileSystem'] = $FileSystem }
        if (-not [string]::IsNullOrEmpty($StateJson)) { $argument['StateJson'] = $StateJson }
        if ($null -ne $Variable) { $argument['Variable'] = $Variable }

        $harness = New-HDTSequenceTestHarness @argument

        $loop = @{ Sequence = $harness.Sequence; Context = $harness.Context; State = $harness.State }
        if ($Resumed) { $loop['Resumed'] = $true }

        $result = Invoke-HDTTaskSequence @loop

        return [pscustomobject] @{
            Harness = $harness
            Result  = $result
        }
    }

    # The step the loop reported for a given name.
    $script:stepNamed = {
        param([object] $Run, [string] $Name)

        return @($Run.Result.Result | Where-Object { [string] $_.Name -eq $Name })[0]
    }
}

Describe 'Invoke-HDTTaskSequence -Resumed' {

    Context 'a resumed WinPE leg reaching a partition step' {

        # THE PATHOLOGICAL CASE, BUILT ON PURPOSE. The state says step 1, which
        # is the partition step, and the leg is WinPE. This is precisely the
        # machine the feature exists to protect: one that has been deployed and
        # sysprepped, and whose state document is lying about where it is.
        BeforeAll {
            $script:fs = New-HDTFakeFileSystem
            $script:resumed = & $script:runLeg $script:fs '' 'WinPE' -Resumed
        }

        It 'fails the partition step rather than running it' {
            (& $script:stepNamed $script:resumed 'Format and Partition Disk').Status |
                Should -BeExactly 'Failed'
        }

        It 'does not skip it, because a skip is how this stays invisible' {
            (& $script:stepNamed $script:resumed 'Format and Partition Disk').Status |
                Should -Not -BeExactly 'Skipped'
        }

        It 'says why, naming the step and the phase' {
            $message = [string] (& $script:stepNamed $script:resumed 'Format and Partition Disk').Message

            $message | Should -Match 'resumed'
            $message | Should -Match 'DiskPartition'
        }

        It 'stops the run rather than carrying on to the capture' {
            $script:resumed.Result.Status | Should -BeExactly 'Failed'
        }
    }

    Context 'the same sequence on an ordinary first WinPE leg' {

        # THE REGRESSION GUARD, AND IT IS THE MORE IMPORTANT HALF. A machine
        # with no run in progress must still deploy, which means the partition
        # step must still be DISPATCHED. If this ever goes red the feature has
        # broken every deployment rather than protected one.
        #
        # IT IS JUDGED ON THE REASON, NOT ON THE STATUS, and that is the
        # stronger claim rather than a concession. This harness builds no
        # IDiskService - the loop's fakes are the ones every other sequence test
        # uses - so the step fails here either way. What must differ is WHY:
        # dispatched and short of a service on a fresh leg, refused before
        # dispatch on a resumed one. Asserting the status alone would pass just
        # as well if the guard fired on every leg.
        BeforeAll {
            $script:freshFs = New-HDTFakeFileSystem
            $script:fresh = & $script:runLeg $script:freshFs '' 'WinPE'
        }

        It 'does not refuse the partition step' {
            [string] (& $script:stepNamed $script:fresh 'Format and Partition Disk').Message |
                Should -Not -Match 'resumed'
        }

        It 'dispatches it, so it fails on its own missing service rather than on the guard' {
            [string] (& $script:stepNamed $script:fresh 'Format and Partition Disk').Message |
                Should -Match 'Disk'
        }
    }

    Context 'the forbidden set' {

        # ASSERTED AGAINST THE SET. Every type the private list names must be
        # refused on a resumed leg - not just the one that prompted this.
        It 'names DiskPartition, which is the one that destroys a disk' {
            InModuleScope Hephaestus {
                Get-HDTResumeForbiddenStepType | Should -Contain 'DiskPartition'
            }
        }

        # ApplyImage overwrites the volume the capture is about to read, which
        # on a reference build is the customized installation somebody spent an
        # hour producing. Not a formatted disk, but the same loss.
        It 'names ApplyImage, which overwrites the volume being captured' {
            InModuleScope Hephaestus {
                Get-HDTResumeForbiddenStepType | Should -Contain 'ApplyImage'
            }
        }

        It 'refuses every type in it, so a type added later is covered by construction' {
            $forbidden = @(InModuleScope Hephaestus { Get-HDTResumeForbiddenStepType })

            $forbidden.Count | Should -BeGreaterThan 0

            foreach ($type in $forbidden) {
                $step = [pscustomobject] @{ Name = ('a {0} step' -f $type); Type = $type }

                InModuleScope Hephaestus -Parameters @{ Step = $step } {
                    param($Step)

                    Test-HDTResumeStepForbidden -Step $Step | Should -BeTrue
                }
            }
        }

        It 'permits the steps a capture leg actually needs' {
            foreach ($type in @('CaptureImage', 'Gather', 'NoOp', 'SetVariable', 'Restart')) {
                $step = [pscustomobject] @{ Name = ('a {0} step' -f $type); Type = $type }

                InModuleScope Hephaestus -Parameters @{ Step = $step } {
                    param($Step)

                    Test-HDTResumeStepForbidden -Step $Step | Should -BeFalse
                }
            }
        }
    }

    Context 'autologon on a resumed WinPE leg' {

        # THE INTERACTION WITH a31cca1, CHECKED RATHER THAN ASSUMED.
        #
        # Test-HDTAutoLogonNeeded arms a logon only when a step after the
        # restart runs in the full OS. A capture leg's remaining step runs in
        # WinPE, so nothing should be armed - which matters because sysprep
        # cleared the LSA secret one step earlier ON PURPOSE, so the image would
        # not carry it. A leg that armed here would either fail looking for a
        # secret that is gone, or bake a password into the reference image.
        It 'arms nothing when every remaining step runs in WinPE' {
            $step = @(
                [pscustomobject] @{ Name = 'Restart into the boot media'; Type = 'Restart'; RunIn = 'FullOS' }
                [pscustomobject] @{ Name = 'Capture Image'; Type = 'CaptureImage'; RunIn = 'WinPE' }
            )

            InModuleScope Hephaestus -Parameters @{ Step = $step } {
                param($Step)

                Test-HDTAutoLogonNeeded -Step $Step -AfterIndex 1 | Should -BeFalse
            }
        }
    }
}
