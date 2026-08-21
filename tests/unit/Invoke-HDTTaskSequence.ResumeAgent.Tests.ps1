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

        # AND THE LOG GOES WITH IT - MDT'S MININT, BY ANOTHER NAME.
        #
        # LiteTouch keeps its logs in MININT\SMSOSD\OSDLOGS and moves that folder
        # onto the target volume before the WinPE leg restarts, so the log
        # survives the reboot on the disk the machine is about to boot from.
        # HDT wrote its WinPE log to X:\HDT\Logs - the RAM disk - and copied it
        # to the share at the TAIL of the payload, after the sequence returned.
        # A Restart step restarts from inside the sequence, so that tail never
        # ran: a deployment with a reboot in it lost every WinPE log it had, and
        # the one machine this was noticed on had nothing to read afterwards
        # because the share it would have copied to was unreachable anyway.
        #
        # THE DISK IS THE COPY THAT CANNOT FAIL. It is local, it is the volume
        # this leg has just written, and the full-OS leg logs to \HDT\Logs on
        # that same volume - so the two legs end up in one folder, which is what
        # reading a deployment end to end requires.
        It 'puts the WinPE log on that volume before it restarts' {
            @($script:fileSystem.GetChildItem('W:\HDT\Logs')).Count |
                Should -BeGreaterThan 0 -Because 'the RAM disk goes away at the restart'
        }

        It 'keeps the log tree intact, under computer and run' {
            $copied = @($script:fileSystem.GetChildItem('W:\HDT\Logs'))[0]

            $script:fileSystem.TestPath(
                [System.IO.Path]::Combine([string] $copied, 'HDT.log')) | Should -BeTrue
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


# MDT'S SLShareDynamicLogging: SOMETHING ON THE SHARE WHILE IT IS STILL WORKING.
#
# The console tails <share>\Logs\_active\ and rebuilds that branch every fifteen
# seconds. Nothing ever wrote it, so the Monitoring view could not show a live
# deployment - and on the first machine anybody watched, it stayed empty from
# start to finish while the deployment ran for four minutes.
Describe 'Invoke-HDTTaskSequence and the console that is watching' {

    BeforeAll {
        $script:watchFileSystem = New-HDTFakeFileSystem

        $script:watchHarness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' `
            -FileSystem $script:watchFileSystem -Variable @{ HDTOSVolume = 'W:' }

        $script:watchResult = Invoke-HDTTaskSequence -Sequence $script:watchHarness.Sequence `
            -Context $script:watchHarness.Context -State $script:watchHarness.State `
            -LogDestination '\host\HDTShare\Logs'
    }

    It 'writes a heartbeat where the console looks for one' {
        $script:watchFileSystem.TestPath('\host\HDTShare\Logs\_active\' +
            $script:watchHarness.Context.RunId + '.json') | Should -BeTrue
    }

    # A ROW THAT NEVER MOVES IS A ROW NOBODY TRUSTS. The heartbeat carries the
    # step, and the console renders "step 7 of 12" from it - so it has to be
    # rewritten as the run steps, not only at the start and the end.
    It 'rewrites it as the run steps, so the row moves' {
        $written = @($script:watchFileSystem.Operations |
                Where-Object { $_.Operation -eq 'WriteAllText' -and
                    ([string] $_.Arguments[0]) -like '*\_active\*' })

        @($written).Count | Should -BeGreaterThan 2 -Because 'start and end alone is not a heartbeat'
    }

    It 'leaves the last one carrying the run outcome, not Running' {
        $active = $script:watchFileSystem.ReadAllText('\host\HDTShare\Logs\_active\' +
            $script:watchHarness.Context.RunId + '.json') | ConvertFrom-Json

        $active.status | Should -Not -BeExactly 'Running'
    }
}

# THE CORRECTED SHARE HAS TO SURVIVE THE REBOOT.
#
# bootstrap.json is baked into the boot image and names the deploy root that was
# true when the image was built. A technician who corrects the share at the
# Welcome screen fixed the WinPE leg only - the full-OS leg asked for the dead
# address again, mapped no drive letter, and Install Applications never ran.
# Watched end to end on 2026-08-21, with the machine sitting on a desktop while
# the log said "the deployment share could not be reached".
Describe 'Invoke-HDTTaskSequence and the share the resume leg is given' {

    It 'writes the share this run reached into the staged bootstrap' {
        $fileSystem = & $script:newFileSystem
        $fileSystem.SeedFile('X:\HDT\bootstrap.json', '{ "deployRoot": "\\\\old\\HDTShare", "provider": "Smb" }')

        $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' `
            -FileSystem $fileSystem -Variable @{ HDTOSVolume = 'W:' }

        $harness.Context.Variable['_HDTDeployRoot'] = '\\192.168.2.40\HDTShare'

        [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

        $staged = $fileSystem.ReadAllText('W:\HDT\bootstrap.json') | ConvertFrom-Json

        $staged.deployRoot | Should -BeExactly '\\192.168.2.40\HDTShare'
        $staged.provider | Should -BeExactly 'Smb'
    }

    # MEDIA KEEPS THE IMAGE'S OWN VALUE. A local root is D: in WinPE and
    # commonly another letter once Windows has assigned its own, so the resolved
    # path would hand the resume a letter that has moved. Resolve-HDTDeployRoot
    # works it out again from the marker instead.
    It 'leaves a local root alone, because a drive letter moves' {
        $fileSystem = & $script:newFileSystem
        $fileSystem.SeedFile('X:\HDT\bootstrap.json', '{ "deployRoot": "D:\\HDTShare", "provider": "Local" }')

        $harness = New-HDTSequenceTestHarness -Yaml $script:yaml -Phase 'WinPE' `
            -FileSystem $fileSystem -Variable @{ HDTOSVolume = 'W:' }

        $harness.Context.Variable['_HDTDeployRoot'] = 'E:\HDTShare'

        [void] (Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State)

        $staged = $fileSystem.ReadAllText('W:\HDT\bootstrap.json') | ConvertFrom-Json

        $staged.deployRoot | Should -BeExactly 'D:\HDTShare'
    }
}
