# THE REBOOT CEREMONY STAGES THE ENGINE BEFORE IT ARMS THE LOGON.
#
# DESIGN 4.5.1 launches the engine at logon from <os volume>\HDT\Start-HDTResume.ps1.
# The ceremony armed that logon for five milestones without ever putting the file
# on the disk: the payload and the module were staged into the BOOT IMAGE at
# X:\HDT\, and X: is a RAM disk that does not survive the restart.
#
# So the machine rebooted, autologged on, and ran nothing. Every step in a FullOS
# group was silently skipped while the run reported success - and on the shipped
# client template that is the entire State Restore group, which is where
# applications install.
#
# WHY IT IS IN THE CEREMONY AND NOT IN A STEP. A step does not own the state
# document, the log context or the reboot; the ceremony is the one place that
# sees a restart coming and knows which volume the image went onto. Putting it in
# a step would also make it optional, and a sequence author who forgot it would
# get the same silent skip back.
#
# ORDER: it stages BEFORE arming, for the reason the ceremony's own order exists.
# Arming a logon for an engine that is not there is the loop-versus-stop argument
# again - a machine that autologons into nothing is stuck, and one that never
# armed is diagnosable from WinPE where the log still is.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:yaml = @'
schemaVersion: 1
id: STAGE-TEST
name: One restart
steps:
  - name: Restart into Windows
    type: Restart
  - name: Install Applications
    type: InstallApplications
    runIn: FullOS
'@

    # THE BOOT IMAGE'S OWN TREE, as Update-HDTBootImage leaves it.
    $script:newFileSystem = {
        return New-HDTFakeFileSystem -File @{
            'X:\HDT\Start-HDTResume.ps1'                          = '# resume'
            'X:\HDT\Start-HDTDeployment.ps1'                      = '# deployment'
            'X:\HDT\bootstrap.json'                               = '{}'
            'X:\HDT\Modules\Hephaestus\Hephaestus.psd1'           = '@{}'
            'X:\HDT\Modules\powershell-yaml\powershell-yaml.psd1' = '@{}'
        }
    }
}

Describe 'Invoke-HDTTaskSequence' {

    Context 'a WinPE leg restarting onto a volume it has just written' {

        BeforeAll {
            $script:fileSystem = & $script:newFileSystem

            $script:harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' `
                -FileSystem $script:fileSystem -Variable @{ HDTOSVolume = 'W:' }

            $script:result = Invoke-HDTTaskSequence -Sequence $script:harness.Sequence `
                -Context $script:harness.Context -State $script:harness.State
        }

        It 'still reports RebootPending' {
            $script:result.Status | Should -BeExactly 'RebootPending'
        }

        It 'puts the resume payload on the volume the machine will boot from' {
            $script:fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeTrue
        }

        It 'puts the engine there too' {
            $script:fileSystem.TestPath('W:\HDT\Modules\Hephaestus\Hephaestus.psd1') | Should -BeTrue
            $script:fileSystem.TestPath('W:\HDT\Modules\powershell-yaml\powershell-yaml.psd1') | Should -BeTrue
        }

        It 'stages before it arms' {
            # The journal is the argument, not the effects: arming a logon for an
            # engine that is not there leaves a machine stuck at a desktop.
            $copy = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' -and
                        ([string] $_.Arguments[1]) -like 'W:\HDT\*' })

            $arm = @($script:harness.Journal |
                    Where-Object { $_.Service -eq 'RegistryService' -and $_.Operation -eq 'SetValue' })

            @($copy).Count | Should -BeGreaterThan 0
            @($arm).Count | Should -BeGreaterThan 0

            @($copy)[0].Sequence | Should -BeLessThan @($arm)[0].Sequence
        }

        It 'says so in the log, because a technician reading it needs to know it happened' {
            $line = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path $script:harness.Log.JsonlPath |
                    Where-Object { [string] $_.message -like '*resume*' })

            @($line).Count | Should -BeGreaterThan 0
        }
    }

    Context 'a WinPE leg that has written no volume yet' {

        It 'stages nothing, and still reboots' {
            # A sequence that restarts before it has partitioned anything - MDT
            # does this to apply firmware settings - has nowhere to stage to, and
            # inventing a letter is exactly what SPIKES S9.1 forbids.
            $fileSystem = & $script:newFileSystem

            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' -FileSystem $fileSystem

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'RebootPending'
            $fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeFalse
        }
    }

    Context 'a full-OS leg' {

        It 'stages nothing, because the engine it is running from is already there' {
            $fileSystem = & $script:newFileSystem

            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'FullOS' `
                -FileSystem $fileSystem -Variable @{ HDTOSVolume = 'W:' }

            [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

            $fileSystem.TestPath('W:\HDT\Start-HDTResume.ps1') | Should -BeFalse
        }
    }

    Context 'a boot image with no resume payload staged in it' {

        It 'reboots anyway rather than failing the deployment' {
            # AN OLDER BOOT IMAGE IS NOT A REASON TO DESTROY A DEPLOYMENT that
            # has already applied Windows. The machine restarts and stops after
            # the first leg, which is what it did before this existed - and the
            # log says why, which is what it did not.
            $fileSystem = New-HDTFakeFileSystem -File @{ 'X:\HDT\Start-HDTDeployment.ps1' = '# deployment' }

            $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' `
                -FileSystem $fileSystem -Variable @{ HDTOSVolume = 'W:' }

            $result = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

            $result.Status | Should -BeExactly 'RebootPending'

            $warned = @(Get-HDTLogRecord -FileSystem $fileSystem -Path $harness.Log.JsonlPath -Severity Warning |
                    Where-Object { [string] $_.message -like '*resume agent*' })

            @($warned).Count | Should -BeGreaterThan 0
        }
    }
}
