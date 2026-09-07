# The checkpoint mirror, followed across the reboot a Refresh sends itself
# through (DESIGN 4.3, and M9's "A full-OS entry point").
#
# THE TWO LEGS OF A REFRESH GO IN THE OPPOSITE DIRECTION TO EVERY OTHER RUN.
# A NEWCOMPUTER deployment starts in WinPE and reboots into the full OS: the leg
# that follows was ARMED by the leg before it, and Start-HDTResume.ps1 reads the
# path it was handed. A Refresh starts in the FULL OS and reboots into WinPE,
# and nothing hands that leg a path - the WinPE leg has to FIND the run, which
# it does by scanning every lettered volume for <letter>:\HDT\state.json
# (Get-HDTResumeCandidate).
#
# SO THE FULL-OS LEG HAS TO WRITE ONE THERE, AND IT DID NOT. The mirror was set
# only inside the log relocation, which is gated on the WinPE phase - correctly,
# for the case it was written for: a WinPE leg logs to X:, a RAM disk that
# evaporates at the restart, so the log MOVES to the target volume the moment a
# step publishes one, and the state mirror rides along on the same trigger. A
# full-OS leg's log is already on the OS volume and must not move; it needed the
# mirror without the relocation, and there was no path through the code that
# gave it one. The Refresh's second leg would have found nothing, minted a new
# run at step 1, and the deployment would have stopped dead.
#
# THIS TEST FOLLOWS ONE RUN THROUGH BOTH LEGS rather than asserting a path
# string: leg one runs in the full OS and stops for the reboot, the WinPE-side
# discovery is asked what it finds, and leg two continues from the document it
# found. A test that only checked C:\HDT\state.json exists would pass for a
# mirror written in a shape Import-HDTRunState could not read back.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # A Refresh in miniature: the machine validates itself, reboots into the
    # WinPE it staged, and applies the image on the leg that comes back.
    $script:refreshYaml = @'
schemaVersion: 1
id: REFRESH-LEGS
name: A Refresh, both legs
steps:
  - name: Validate the machine
    type: NoOp
  - name: Boot into the staged WinPE
    type: Restart
  - name: Apply OS
    type: NoOp
'@

    # What a WinPE leg sees on a machine that was running Windows on C: - the
    # RAM disk it is running from, the ESP, and the OS volume. Only DriveLetter
    # is read by the scan.
    $script:volumeRow = {
        param([string[]] $Letter)

        return @($Letter | ForEach-Object {
                [pscustomobject] @{
                    DriveLetter        = $_
                    FileSystem         = 'NTFS'
                    FileSystemLabel    = ''
                    SizeBytes          = 128GB
                    SizeRemainingBytes = 40GB
                }
            })
    }
}

Describe 'Invoke-HDTTaskSequence, a full-OS leg that reboots into WinPE' {

    BeforeAll {
        # -- leg one, in the running Windows --------------------------------
        #
        # ONE FAKE FILESYSTEM ACROSS BOTH LEGS, because one machine has one disk.
        # C:\HDT\Logs is where Get-HDTLogPath -Phase FullOS puts the log, so the
        # harness opens the path the payload really would have.
        $script:machine = New-HDTFakeFileSystem
        $script:legOne = New-HDTSequenceTestHarness -Yaml $script:refreshYaml -Phase FullOS `
            -LogPath 'C:\HDT\Logs' -FileSystem $script:machine -RunId 'run-refresh-0001'

        $script:resultOne = Invoke-HDTTaskSequence -Sequence $script:legOne.Sequence `
            -Context $script:legOne.Context -State $script:legOne.State

        # -- what the WinPE leg does when it comes up ------------------------
        #
        # Nothing armed it and nothing handed it a path: a Refresh's second leg
        # is a WinPE boot like any other, and this scan is the only thing that
        # can tell it a run is already in progress.
        $script:decision = Get-HDTResumeCandidate -Phase WinPE `
            -Disk (New-HDTFakeDiskService -Volume (& $script:volumeRow @('X', 'S', 'C'))) `
            -FileSystem $script:machine -Clock $script:legOne.Clock
    }

    Context 'leg one, in the full OS' {

        It 'stops for the reboot rather than finishing' {
            $script:resultOne.Status | Should -BeExactly 'RebootPending'
        }

        It 'does not relocate its log' {
            # THE REASONING THE WinPE GATE WAS PROTECTING, KEPT. A WinPE leg
            # relocates because X: is a RAM disk that does not survive the
            # restart. A full-OS leg's log is already on the OS volume, so there
            # is nowhere better for it to go.
            $script:legOne.Log.LogPath | Should -BeExactly 'C:\HDT\Logs'
        }

        It 'writes its checkpoint beside that log' {
            $script:machine.TestPath('C:\HDT\Logs\state.json') | Should -BeTrue
        }

        It 'mirrors the checkpoint where the WinPE leg will look for it' {
            # THE WHOLE DEFECT, IN ONE LINE. Get-HDTResumeCandidate scans
            # <letter>:\HDT\state.json and nothing else.
            $script:machine.TestPath('C:\HDT\state.json') | Should -BeTrue
        }

        It 'keeps the mirror current rather than freezing it at the first checkpoint' {
            $mirror = ConvertFrom-Json -InputObject ($script:machine.ReadAllText('C:\HDT\state.json'))

            [int] $mirror.stepIndex | Should -Be 3 `
                -Because 'the restart step is recorded Completed, so stepIndex advances past it to the step that comes back'
            [string] $mirror.status | Should -BeExactly 'Running'
        }
    }

    Context 'the WinPE leg that comes back' {

        It 'finds a run in progress' {
            $script:decision.Action | Should -BeExactly 'Resume' `
                -Because ('the scan reported: {0}' -f $script:decision.Reason)
        }

        It 'finds it on the OS volume, not on the RAM disk' {
            $script:decision.Path | Should -BeExactly 'C:\HDT\state.json'
        }

        It 'finds THIS run, at the step leg one stopped at' {
            [string] $script:decision.State.runId | Should -BeExactly 'run-refresh-0001'
            [int] $script:decision.State.stepIndex | Should -Be 3 `
                -Because 'leg one completed the restart step, so the leg that comes back starts at the one after it'
        }

        It 'carries on rather than starting the sequence again' {
            # THE DOCUMENT, NOT THE OBJECT. A second leg reads the file the leg
            # before it wrote; passing the in-memory state between them would
            # prove nothing about the mirror.
            $legTwo = New-HDTSequenceTestHarness -Yaml $script:refreshYaml -Phase WinPE `
                -RunId 'run-refresh-0001' -FileSystem $script:machine `
                -StateJson ($script:machine.ReadAllText($script:decision.Path))

            $resultTwo = Invoke-HDTTaskSequence -Sequence $legTwo.Sequence -Context $legTwo.Context `
                -State $legTwo.State

            $resultTwo.Status | Should -BeExactly 'Succeeded'

            @($resultTwo.State.step | Where-Object { [string] $_.status -eq 'Completed' } |
                    ForEach-Object { [int] $_.index }) | Should -Be @(1, 2, 3)
        }
    }

    Context 'what the fix must not have started doing' {

        It 'writes no mirror in WinPE before a volume exists' {
            # X: IS THE RAM DISK. A mirror there survives nothing, and a scan
            # that found one would make every ordinary deployment resume itself
            # - which is why Get-HDTResumeCandidate excludes X: in the first
            # place. The WinPE leg still waits for a step to publish a volume.
            $fileSystem = New-HDTFakeFileSystem
            $harness = New-HDTSequenceTestHarness -Yaml $script:refreshYaml -Phase WinPE `
                -FileSystem $fileSystem

            [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context `
                    -State $harness.State)

            $fileSystem.TestPath('X:\HDT\state.json') | Should -BeFalse
            $fileSystem.TestPath('X:\HDT\Logs\state.json') | Should -BeTrue
        }
    }
}
