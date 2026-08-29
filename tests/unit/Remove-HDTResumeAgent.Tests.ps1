# MDT's LTICleanup, AND THE THREE THINGS A FINISHED MACHINE SHOULD NOT STILL BE
# CARRYING.
#
# Watched on a deployed machine: the deployment succeeded, the Deployment Summary
# said so - and the machine was still holding the deployment share on a mapped
# drive, still had C:\HDT with the engine and the share credential's bootstrap
# document in it, and its only record of how it had been built was inside that
# same folder.
#
# ON SUCCESS ONLY, WHICH IS MDT'S RULE AND THE IMPORTANT ONE. A failed
# deployment is exactly the machine somebody walks up to with questions, and
# every one of those questions is answered by the things this command removes.
# The caller decides; this refuses nothing on its own except a path that does
# not look like the agent.
#
# THE LOGS MOVE BEFORE ANYTHING IS DELETED. They live under the folder being
# removed, so an order that deleted first would be a deployment with no account
# of itself - which is worse than a machine with a stale folder on it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # A STAGED AGENT, THE WAY Copy-HDTResumeAgent LEAVES ONE - AND THE WAY A
    # REAL ONE WAS FOUND ON A DEPLOYED MACHINE. C:\HDT\Logs holds exactly one
    # entry and it is a DIRECTORY: the run folder. There is no loose file in it
    # at all, which is the shape the first version of this command could not
    # copy and did not survive.
    $script:newAgent = {
        $fs = New-HDTFakeFileSystem
        $fs.SeedFile('C:\HDT\Start-HDTResume.ps1', '# the agent')
        $fs.SeedFile('C:\HDT\Remove-HDTAgentTree.ps1', '# the deleter')
        $fs.SeedFile('C:\HDT\bootstrap.json', '{"credential":{"protected":"AAAA"}}')
        $fs.SeedFile('C:\HDT\state.json', '{"status":"Succeeded"}')
        $fs.SeedFile('C:\HDT\Modules\Hephaestus\Hephaestus.psd1', '@{}')
        $fs.SeedFile('C:\HDT\UI\HDTProgress.xaml', '<Window />')
        $fs.SeedFile('C:\HDT\Logs\run-20260828-233000\HDT.log', 'the account of this deployment')
        $fs.SeedFile('C:\HDT\Logs\run-20260828-233000\HDT.jsonl', '{"event":"run.end"}')
        $fs.SeedFile('C:\HDT\Logs\run-20260828-233000\status.json', '{"phase":"FullOS"}')
        $fs.SeedFile('C:\HDT\Logs\run-20260828-233000\Steps\01-Format.log', 'formatted')
        $fs.SeedFile('C:\HDT\Logs\run-20260828-233000\Gather\provenance.json', '{"variable":[]}')

        return $fs
    }

    $script:sweep = {
        param([object] $FileSystem, [object] $Process)

        return (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                -FileSystem $FileSystem -Process $Process -ProcessId 1234 -Confirm:$false)
    }
}

Describe 'Remove-HDTResumeAgent' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTResumeAgent' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it destroys a credential and starts a delete' {
            (Get-Command -Name 'Remove-HDTResumeAgent').Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'takes injected services' -ForEach @('FileSystem', 'Process') {
            (Get-Command -Name 'Remove-HDTResumeAgent').Parameters.Keys | Should -Contain $PSItem
        }
    }

    # THE DEFECT THAT KEPT EVERY DEPLOYED MACHINE'S C:\HDT. Watched on a
    # deployed VM: the cleanup block threw on its very first statement and the
    # catch reported "the resume agent could not be removed", so the engine, the
    # bootstrap credential and the logs all stayed exactly where they were.
    #
    # THE CAUSE WAS ONE MISMATCHED PAIR. IFileSystem.GetChildItem is
    # Directory.GetFileSystemEntries, which returns DIRECTORIES as well as
    # files, and IFileSystem.CopyItem is [System.IO.File]::Copy, which throws
    # when handed one. C:\HDT\Logs holds exactly one entry - the run folder - so
    # the first iteration threw every time, on every machine.
    Context 'a log tree that is a folder of folders, which is every real one' {

        It 'keeps a log tree whose only entry is a directory' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            { & $script:sweep $fs $proc } | Should -Not -Throw

            $fs.TestPath('C:\Windows\Logs\HDT\run-20260828-233000\HDT.log') | Should -BeTrue
        }

        It 'keeps every file at every depth, not just the top one' -ForEach @(
            'C:\Windows\Logs\HDT\run-20260828-233000\HDT.log'
            'C:\Windows\Logs\HDT\run-20260828-233000\HDT.jsonl'
            'C:\Windows\Logs\HDT\run-20260828-233000\status.json'
            'C:\Windows\Logs\HDT\run-20260828-233000\Steps\01-Format.log'
            'C:\Windows\Logs\HDT\run-20260828-233000\Gather\provenance.json'
        ) {
            $fs = & $script:newAgent
            [void] (& $script:sweep $fs (New-HDTFakeProcessService))

            $fs.TestPath($PSItem) | Should -BeTrue
        }

        It 'counts every file it kept, not every entry it looked at' {
            $fs = & $script:newAgent

            $answer = & $script:sweep $fs (New-HDTFakeProcessService)

            # Five under Logs\, plus the run state document beside the agent.
            [int] $answer.LogFileCount | Should -Be 6
        }
    }

    # WHERE THE STATE FILE GOES, AND WHY IT GOES ANYWHERE AT ALL. It is the
    # engine's own account of which step the run reached and what it decided,
    # and it lives beside the agent rather than under Logs\ - so a cleanup that
    # swept only Logs\ deleted the one document that says where a deployment got
    # to.
    Context 'and the state document travels with them' {

        It 'lands under the final log destination' {
            $fs = & $script:newAgent
            [void] (& $script:sweep $fs (New-HDTFakeProcessService))

            $fs.TestPath('C:\Windows\Logs\HDT\state.json') | Should -BeTrue
            $fs.ReadAllText('C:\Windows\Logs\HDT\state.json') | Should -BeLike '*Succeeded*'
        }

        It 'reports where it put them' {
            $fs = & $script:newAgent
            $answer = & $script:sweep $fs (New-HDTFakeProcessService)

            [string] $answer.LogDestination | Should -Be 'C:\Windows\Logs\HDT'
        }
    }

    # THE SECURITY HALF, AND IT IS NOT A TIDY-UP. bootstrap.json carries the
    # deployment share's account and its password, AES-encrypted under a key
    # that is a MODULE CONSTANT - not user-bound, not machine-bound - so
    # anybody holding the file holds the credential. It was left on the disk of
    # every machine HDT has ever deployed.
    #
    # IN PROCESS, AND BEFORE THE HANDOFF. The tree itself cannot be deleted from
    # inside this process - powershell-yaml has YamlDotNet.dll loaded out of it
    # and 5.1 cannot unload an assembly - so the tree goes to a detached
    # deleter. That deleter is a process that might not start. The credential is
    # not allowed to depend on it.
    Context 'the credential goes first, and from inside this process' {

        It 'deletes the bootstrap document' {
            $fs = & $script:newAgent
            [void] (& $script:sweep $fs (New-HDTFakeProcessService))

            $fs.TestPath('C:\HDT\bootstrap.json') | Should -BeFalse
        }

        It 'deletes the state document it has just kept a copy of' {
            $fs = & $script:newAgent
            [void] (& $script:sweep $fs (New-HDTFakeProcessService))

            $fs.TestPath('C:\HDT\state.json') | Should -BeFalse
        }

        It 'deletes the credential even when the detached deleter never starts' {
            # THE WHOLE POINT OF DOING IT HERE. A shell that will not launch, a
            # missing deleter script, an antivirus that blocks the process -
            # none of them may leave the share credential on the disk.
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService
            $proc.FailInteractive = $true

            $answer = & $script:sweep $fs $proc

            [bool] $answer.RemovalStarted | Should -BeFalse
            $fs.TestPath('C:\HDT\bootstrap.json') | Should -BeFalse
        }

        It 'destroys the credential before it asks anything to start' {
            $journal = [System.Collections.ArrayList]::new()

            $fs = & $script:newAgent
            $fs.Journal = $journal
            $proc = New-HDTFakeProcessService
            $proc.Journal = $journal

            [void] (& $script:sweep $fs $proc)

            $delete = @($journal | Where-Object {
                    $_.Operation -eq 'RemoveItem' -and
                    ([string] $_.Arguments[0]) -like '*bootstrap.json'
                })[0]

            $start = @($journal | Where-Object { $_.Operation -eq 'StartInteractive' })[0]

            $delete | Should -Not -BeNullOrEmpty
            $start | Should -Not -BeNullOrEmpty
            [int] $delete.Sequence | Should -BeLessThan ([int] $start.Sequence)
        }
    }

    Context 'and then the tree is handed to something that can actually delete it' {

        It 'starts the detached deleter' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            $answer = & $script:sweep $fs $proc

            [bool] $answer.RemovalStarted | Should -BeTrue
            @($proc.GetOperationName()) | Should -Contain 'StartInteractive'
        }

        It 'tells the deleter which process is holding the tree open' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            [void] (& $script:sweep $fs $proc)

            $argument = [string] @($proc.Operations | Where-Object { $_.Operation -eq 'StartInteractive' })[0].Arguments[1]
            $argument | Should -BeLike '*-ParentProcessId 1234*'
        }

        It 'passes the staged driver folder on, so 4 GB does not stay behind' {
            # THE DELETER CANNOT WORK IT OUT ITSELF and must not try. It runs
            # detached and elevated with -Recurse -Force; a path it GUESSED is
            # the one thing that could erase the machine it just built. So the
            # caller names it and the deleter's own guard checks the name.
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -DriverPath 'C:\Drivers' -FinishAction 'Restart' -DelaySecond 30 `
                    -FileSystem $fs -Process $proc -ProcessId 1234 -Confirm:$false)

            $argument = [string] @($proc.Operations | Where-Object { $_.Operation -eq 'StartInteractive' })[0].Arguments[1]
            $argument | Should -BeLike "*-DriverPath 'C:\Drivers'*"
        }

        It 'names no driver folder when there is none to remove' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            [void] (& $script:sweep $fs $proc)

            $argument = [string] @($proc.Operations | Where-Object { $_.Operation -eq 'StartInteractive' })[0].Arguments[1]
            $argument | Should -Not -BeLike '*-DriverPath*'
        }

        It 'passes the finish action on, because the parent will be dead' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FinishAction 'Restart' -DelaySecond 30 `
                    -FileSystem $fs -Process $proc -ProcessId 1234 -Confirm:$false)

            $argument = [string] @($proc.Operations | Where-Object { $_.Operation -eq 'StartInteractive' })[0].Arguments[1]
            # QUOTED, because the whole thing is one -Command string and a
            # path in it may legally contain a space or an apostrophe.
            $argument | Should -BeLike "*-FinishAction 'Restart'*"
            $argument | Should -BeLike '*-DelaySecond 30*'
        }

        It 'does nothing at all under -WhatIf' {
            $fs = & $script:newAgent
            $proc = New-HDTFakeProcessService

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Process $proc -WhatIf)

            $fs.TestPath('C:\HDT\bootstrap.json') | Should -BeTrue
            $fs.TestPath('C:\Windows\Logs\HDT\run-20260828-233000\HDT.log') | Should -BeFalse
            @($proc.GetOperationName()) | Should -Not -Contain 'StartInteractive'
        }
    }

    Context 'what it refuses to touch' {

        # CLAUDE.md: never pass a variable to a recursive delete without
        # asserting first that it is the thing you meant. This command is handed
        # a path by a payload; a bug upstream must not turn it into a machine
        # with no C:\Windows.

        It 'refuses a path that does not hold a staged agent' -ForEach @(
            'C:\Windows', 'C:\Users\someone', 'D:\Data') {

            # SEEDED SO IT EXISTS. A path that is not there returns quietly by
            # design - a second Finish press must not fail - so the refusal can
            # only be proven against a directory that DOES exist and is not the
            # agent. That is also the dangerous case: the one where a recursive
            # delete would actually have done something.
            $fs = & $script:newAgent
            $fs.SeedFile(('{0}\something-that-matters.txt' -f $PSItem), 'not yours to delete')

            { Remove-HDTResumeAgent -Path $PSItem -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Process (New-HDTFakeProcessService) -Confirm:$false } | Should -Throw

            $fs.TestPath(('{0}\something-that-matters.txt' -f $PSItem)) | Should -BeTrue
            $fs.TestPath('C:\HDT\Start-HDTResume.ps1') | Should -BeTrue
        }

        It 'refuses a folder that is merely named HDT but holds no agent' {
            # A technician's own C:\HDT, or a share root somebody mounted there.
            $fs = New-HDTFakeFileSystem
            $fs.SeedFile('C:\HDT\notes.txt', 'mine')

            { Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Process (New-HDTFakeProcessService) -Confirm:$false } | Should -Throw

            $fs.TestPath('C:\HDT\notes.txt') | Should -BeTrue
        }

        It 'says nothing was there rather than throwing when the folder is gone' {
            # A second Finish press, or a leg that already cleaned up.
            $fs = New-HDTFakeFileSystem

            $answer = & $script:sweep $fs (New-HDTFakeProcessService)

            [bool] $answer.RemovalStarted | Should -BeFalse
        }
    }
}
