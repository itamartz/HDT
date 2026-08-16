# MDT'S "EXIT TO COMMAND PROMPT", AND THE PROMPT ACTUALLY APPEARS.
#
# The wizard has offered an Open CMD button since W2 and NOTHING ANYWHERE ACTED
# ON IT. Show-HDTWizard returned 'CommandPrompt' by design and left opening the
# prompt to the caller; no caller ever did. Pressing it closed the window and
# produced nothing at all, on every machine, which is the failure this command
# exists to end.
#
# WHY A PROMPT MUST NOT GO THROUGH IProcessService.Start. That method redirects
# both pipes, sets CreateNoWindow and WAITS FOR EXIT - correct for a command
# line step, and exactly wrong here: an interactive prompt has no output to
# capture, must have a window, and must not block the thread that opened it.
# StartInteractive is the separate verb, and the difference is the whole point.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Start-HDTCommandPrompt' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Start-HDTCommandPrompt' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected process service, so no test opens a window' {
            (Get-Command -Name 'Start-HDTCommandPrompt').Parameters.ContainsKey('Process') | Should -BeTrue
        }
    }

    Context 'which shell it opens' {

        It 'opens the shell ComSpec names' {
            # WinPE sets ComSpec like any other Windows, and an image with a
            # different shell in it is the image's business, not this command's.
            $process = New-HDTFakeProcessService
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'X:\Windows\System32\cmd.exe' }

            $result = Start-HDTCommandPrompt -Process $process -Environment $environment

            [string] $result.FilePath | Should -BeExactly 'X:\Windows\System32\cmd.exe'
        }

        It 'falls back to cmd.exe when ComSpec says nothing' -ForEach @(@{ Variable = @{} }, @{ Variable = @{ ComSpec = '' } }, @{ Variable = @{ ComSpec = '   ' } }) {
            # A MISSING ComSpec IS NOT A REASON TO REFUSE. The technician asked
            # for a prompt because something is already wrong with this machine;
            # answering "I could not read an environment variable" is the least
            # useful thing this could do.
            $process = New-HDTFakeProcessService
            $environment = New-HDTFakeEnvironmentProvider -Variable $Variable

            $result = Start-HDTCommandPrompt -Process $process -Environment $environment

            [string] $result.FilePath | Should -BeExactly 'cmd.exe'
        }

        It 'falls back to cmd.exe when there is no environment provider at all' {
            $process = New-HDTFakeProcessService

            $result = Start-HDTCommandPrompt -Process $process -Environment $null

            [string] $result.FilePath | Should -BeExactly 'cmd.exe'
        }
    }

    Context 'how it opens it' {

        It 'starts it interactively, never through the waiting Start' {
            # THE ONE THAT MATTERS. Start redirects both pipes, hides the window
            # and blocks until exit - so a prompt opened through it would be
            # invisible AND would freeze the wizard that opened it.
            $process = New-HDTFakeProcessService

            Start-HDTCommandPrompt -Process $process -Environment $null | Out-Null

            @($process.GetOperationName()) | Should -Be @('StartInteractive')
        }

        It 'opens exactly one prompt' {
            $process = New-HDTFakeProcessService

            Start-HDTCommandPrompt -Process $process -Environment $null | Out-Null

            @($process.Operations).Count | Should -Be 1
        }

        It 'passes no arguments, so the prompt stays open' {
            # cmd.exe /c would run nothing and close again immediately, which
            # from the technician's side is identical to the dead button this
            # command replaces.
            $process = New-HDTFakeProcessService

            Start-HDTCommandPrompt -Process $process -Environment $null | Out-Null

            [string] @($process.Operations)[0].Arguments[1] | Should -BeNullOrEmpty
        }

        It 'opens it in the working directory it was given' {
            $process = New-HDTFakeProcessService

            Start-HDTCommandPrompt -Process $process -Environment $null -WorkingDirectory 'X:\HDT' | Out-Null

            [string] @($process.Operations)[0].Arguments[2] | Should -BeExactly 'X:\HDT'
        }
    }

    Context 'what it answers' {

        It 'reports the process it started' {
            $process = New-HDTFakeProcessService

            $result = Start-HDTCommandPrompt -Process $process -Environment $null

            [bool] $result.Started | Should -BeTrue
            [int] $result.ProcessId | Should -BeGreaterThan 0
        }

        It 'reports a prompt that would not start rather than throwing' {
            # A WIZARD MUST NOT DIE BECAUSE A PROMPT DID NOT OPEN. The window is
            # already closing when this runs; an exception here would take the
            # deployment with it and leave a blank screen - which is worse than
            # the missing prompt it is reporting.
            $process = New-HDTFakeProcessService -FailInteractive

            $result = Start-HDTCommandPrompt -Process $process -Environment $null

            [bool] $result.Started | Should -BeFalse
            [string] $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}
