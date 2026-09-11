# How a run ends the machine, as a decision rather than a guard in a payload.
#
# WRITTEN AFTER THE FACT, AND THAT IS THE POINT. The behaviour below shipped in
# a boot image with no test at all: Start-HDTDeployment.ps1 is asserted as TEXT
# ("the file mentions wpeutil"), never executed, so a branch added to it is a
# branch nothing checks. CLAUDE.md rule 1 exempts thin branch-free adapters; a
# payload full of if statements is not one.
#
# THE DECISION THIS COVERS COST A DEPLOYMENT. A failed run used to power the
# machine off five seconds after the failure, which is defensible against a
# REBOOT - a failed run has usually not applied an image, and rebooting boots
# the media and starts the same deployment again, unwatched. But the answer to
# "do not loop" is "stop", not "power off": a machine sitting in WinPE loops
# nothing, keeps X: and the console and the error on screen, and can be walked
# up to. One that powered itself off took the only copy of the reason with it.
#
# The same reasoning was already written down for a share that could not be
# reached - "one that powered off at 3am tells nobody anything" - and this is
# that rule applied to every failure rather than one of them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTMachineEnding' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTMachineEnding' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'a run that failed' {

        It 'leaves the machine where it failed' {
            $answer = Get-HDTMachineEnding -Status 'Failed'

            $answer.EndMachine | Should -BeFalse
            $answer.Reason | Should -Match 'read'
        }

        It 'still reboots when the technician asked for it' {
            # Restart on the failure screen is a person deciding, and the
            # machine obeys the person.
            (Get-HDTMachineEnding -Status 'Failed' -FailureScreenAction 'Restart').EndMachine | Should -BeTrue
        }

        It 'powers off when the technician asked for that' {
            (Get-HDTMachineEnding -Status 'Failed' -FailureScreenAction 'Shutdown').EndMachine | Should -BeTrue
        }

        It 'does nothing when they were left at a command prompt' {
            # THE MACHINE IS THEIRS. A run that opened a prompt and then powered
            # the machine off five seconds later gave a technician nothing.
            (Get-HDTMachineEnding -Status 'Failed' -LeftAtCommandPrompt).EndMachine | Should -BeFalse
        }
    }

    Context 'a run that did not fail' {

        It 'ends a succeeded run' {
            (Get-HDTMachineEnding -Status 'Succeeded').EndMachine | Should -BeTrue
        }

        It 'ends a run that wants the machine back' {
            # RebootPending means the deployment is not over: it is going back
            # into what it just built to run the rest of the sequence.
            (Get-HDTMachineEnding -Status 'RebootPending').EndMachine | Should -BeTrue
        }

        It 'leaves a succeeded run alone when the technician took a prompt' {
            (Get-HDTMachineEnding -Status 'Succeeded' -LeftAtCommandPrompt).EndMachine | Should -BeFalse
        }
    }

    Context 'what it always answers with' {

        It 'gives a reason whatever it decided' {
            # THE REASON GOES IN THE LOG AS endedWith. A run that ended and did
            # not say how is a run nobody can reconstruct.
            foreach ($status in 'Failed', 'Succeeded', 'RebootPending') {
                [string] (Get-HDTMachineEnding -Status $status).Reason |
                    Should -Not -BeNullOrEmpty -Because "$status has to explain itself"
            }
        }
    }
}

# THE REASON IS READ BY A PERSON, SO IT HAS TO BE TRUE ON THEIR MACHINE.
#
# On 2026-09-10 a Refresh failed in its FULL-OS leg and the log said "HDT is not
# ending this machine: left in WinPE so the failure can be read" - on a machine
# running Windows, which had never been in WinPE. The same run also announced
# 'wpeutil shutdown' as the command it would have used and tried to write its
# fallback RESULT.json to X:, a drive that does not exist outside WinPE.
#
# THE BEHAVIOUR IS RIGHT AND IS NOT CHANGED HERE. Holding a failed machine so a
# technician can read the screen is the decision DESIGN made, and it is as
# correct in the full OS as it is in WinPE. What was wrong was telling them they
# were somewhere they were not, in the one log they are reading precisely
# because something has gone wrong.
Describe 'the reason a failed machine is held' {

    It 'says WinPE when the run was in WinPE' {
        $ending = Get-HDTMachineEnding -Status 'Failed' -Phase 'WinPE'

        $ending.EndMachine | Should -BeFalse
        $ending.Reason | Should -BeLike '*WinPE*'
    }

    It 'does not claim WinPE when the run was in the full OS' {
        $ending = Get-HDTMachineEnding -Status 'Failed' -Phase 'FullOS'

        $ending.EndMachine | Should -BeFalse
        $ending.Reason | Should -Not -BeLike '*WinPE*' -Because (
            'a Refresh fails in the full OS, and telling the technician it is in WinPE sends them looking for a machine that is not there')
        $ending.Reason | Should -BeLike '*failure can be read*'
    }
}
