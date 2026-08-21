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

    # A staged agent, the way Copy-HDTResumeAgent leaves one.
    $script:newAgent = {
        $fs = New-HDTFakeFileSystem
        $fs.SeedFile('C:\HDT\Start-HDTResume.ps1', '# the agent')
        $fs.SeedFile('C:\HDT\bootstrap.json', '{}')
        $fs.SeedFile('C:\HDT\state.json', '{}')
        $fs.SeedFile('C:\HDT\Modules\Hephaestus\Hephaestus.psd1', '@{}')
        $fs.SeedFile('C:\HDT\UI\HDTProgress.xaml', '<Window />')
        $fs.SeedFile('C:\HDT\Logs\LAUNCHER.log', 'the account of this deployment')
        $fs.SeedFile('C:\HDT\Logs\run-20260821-233000.jsonl', '{"event":"run.end"}')

        return $fs
    }
}

Describe 'Remove-HDTResumeAgent' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Remove-HDTResumeAgent' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it deletes a directory tree' {
            (Get-Command -Name 'Remove-HDTResumeAgent').Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'takes an injected file system' {
            (Get-Command -Name 'Remove-HDTResumeAgent').Parameters.Keys | Should -Contain 'FileSystem'
        }
    }

    Context 'the logs go somewhere that outlives the folder' {

        It 'copies them to the log destination before removing anything' {
            $fs = & $script:newAgent

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Confirm:$false)

            $fs.TestPath('C:\Windows\Logs\HDT\LAUNCHER.log') | Should -BeTrue
            $fs.TestPath('C:\Windows\Logs\HDT\run-20260821-233000.jsonl') | Should -BeTrue
        }

        It 'reports what it kept' {
            $fs = & $script:newAgent

            $answer = Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                -FileSystem $fs -Confirm:$false

            [int] $answer.LogFileCount | Should -Be 2
            [string] $answer.LogDestination | Should -Be 'C:\Windows\Logs\HDT'
        }

        It 'still removes the folder when there were no logs to keep' {
            $fs = New-HDTFakeFileSystem
            $fs.SeedFile('C:\HDT\Start-HDTResume.ps1', '# the agent')

            $answer = Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                -FileSystem $fs -Confirm:$false

            [int] $answer.LogFileCount | Should -Be 0
            [bool] $answer.Removed | Should -BeTrue
        }
    }

    Context 'and then the folder goes' {

        It 'removes the agent folder' {
            $fs = & $script:newAgent

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Confirm:$false)

            $fs.TestPath('C:\HDT') | Should -BeFalse
        }

        It 'says it removed it' {
            $fs = & $script:newAgent

            $answer = Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                -FileSystem $fs -Confirm:$false

            [bool] $answer.Removed | Should -BeTrue
            [string] $answer.Path | Should -Be 'C:\HDT'
        }

        It 'does nothing at all under -WhatIf' {
            $fs = & $script:newAgent

            [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -WhatIf)

            $fs.TestPath('C:\HDT') | Should -BeTrue
            $fs.TestPath('C:\Windows\Logs\HDT\LAUNCHER.log') | Should -BeFalse
        }
    }

    Context 'what it refuses to delete' {

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
                    -FileSystem $fs -Confirm:$false } | Should -Throw

            $fs.TestPath(('{0}\something-that-matters.txt' -f $PSItem)) | Should -BeTrue
            $fs.TestPath('C:\HDT\Start-HDTResume.ps1') | Should -BeTrue
        }

        It 'refuses a folder that is merely named HDT but holds no agent' {
            # A technician's own C:\HDT, or a share root somebody mounted there.
            $fs = New-HDTFakeFileSystem
            $fs.SeedFile('C:\HDT\notes.txt', 'mine')

            { Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                    -FileSystem $fs -Confirm:$false } | Should -Throw

            $fs.TestPath('C:\HDT\notes.txt') | Should -BeTrue
        }

        It 'says nothing was there rather than throwing when the folder is gone' {
            # A second Finish press, or a leg that already cleaned up.
            $fs = New-HDTFakeFileSystem

            $answer = Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                -FileSystem $fs -Confirm:$false

            [bool] $answer.Removed | Should -BeFalse
        }
    }
}
