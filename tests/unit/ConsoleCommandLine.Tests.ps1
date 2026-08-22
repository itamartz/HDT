# MDT's Run Command Line dialog, which IS that step's properties page.
#
# WHAT IT REPLACES. The generic sheet showed a Run Command Line step two rows:
# 'Command', and 'successCodes - 2 entries, a table not a value'. So the setting
# MDT calls "Start in" - workingDirectory, which Invoke-HDTCommandLineStep reads
# and every installer that resolves a relative path depends on - could not be
# reached from the console at all, and the exit codes that decide whether the
# step passed could be looked at but not changed.
#
# THE SAME RULE AS THE DISK, IMAGE, VALIDATE AND APPLICATION PAGES: everything
# on the page is decided here, so the host assigns and branches on nothing, and
# what a technician sees can be asserted without a screen (CLAUDE.md rule 1).
#
# TWO FORMS, BECAUSE THE ENGINE HAS TWO. 'command' is a shell line run through
# %ComSpec% /c; 'file' plus 'arguments' is a direct exec. MDT has only the first
# and this page leads with it - but a document using the second is a document
# somebody wrote on purpose, and a page that quietly rewrote it into the other
# form would be editing a step nobody asked it to edit.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'

    $script:text = @'
schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal
steps:
  - name: Run Command Line
    type: CommandLine
    command: setup.exe /q /norestart
    workingDirectory: C:\Deploy\Applications
    successCodes: [0, 1641, 3010]
    rebootCodes: [3010]

  - name: Run the agent directly
    type: CommandLine
    file: setup.exe
    arguments: /q /norestart

  - name: Bare
    type: CommandLine
    command: whoami

  - name: Apply OS
    type: ApplyImage
    os: Win11-LTSC-2024
'@

    $script:line = $script:text -split "`r?`n"
}

Describe 'Get-HDTConsoleCommandLine' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleCommandLine' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleCommandLine').Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'shows the cmdlet that produced the page' {
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run Command Line'

            $page.Command | Should -Match 'Get-HDTConsoleCommandLine'
        }
    }

    Context 'which steps have this page at all' {

        It 'claims a CommandLine step' {
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run Command Line'

            $page.IsCommandLineStep | Should -BeTrue
        }

        It 'leaves every other step alone' {
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Apply OS'

            $page.IsCommandLineStep | Should -BeFalse
        }

        It 'comes back with the same shape for a step that is not there' {
            # The editor rebuilds this pane after every splice, including the
            # one that removed the selected step. A page that threw would take
            # the window down on a successful delete.
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'No such step'

            $page.IsCommandLineStep | Should -BeFalse
            $page.Command | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the shell form, which is what MDT offers' {

        BeforeAll {
            $script:page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run Command Line'
        }

        It 'shows the command line' {
            $script:page.CommandLine | Should -BeExactly 'setup.exe /q /norestart'
        }

        It 'shows Start in, the setting the generic sheet could not reach' {
            $script:page.WorkingDirectory | Should -BeExactly 'C:\Deploy\Applications'
        }

        It 'says it is the shell form, so the page knows which boxes to show' {
            $script:page.UsesFile | Should -BeFalse
        }

        It 'shows the success codes as a list a person can read and retype' {
            $script:page.SuccessCode | Should -BeExactly '0, 1641, 3010'
        }

        It 'shows the reboot codes the same way' {
            $script:page.RebootCode | Should -BeExactly '3010'
        }
    }

    Context 'the direct-exec form, which the engine also runs' {

        BeforeAll {
            $script:direct = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run the agent directly'
        }

        It 'says so, rather than folding it into a command line' {
            $script:direct.UsesFile | Should -BeTrue
        }

        It 'shows the file and the arguments as the two things they are' {
            $script:direct.File | Should -BeExactly 'setup.exe'
            $script:direct.Arguments | Should -BeExactly '/q /norestart'
        }
    }

    Context 'the codes a step does not name' {

        BeforeAll {
            $script:bare = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Bare'
        }

        It 'shows what the engine will actually use, not an empty box' {
            # Invoke-HDTCommandLineStep defaults successCodes to 0 and
            # rebootCodes to 3010. An empty box would say "anything goes", which
            # is the opposite of what this step does.
            $script:bare.SuccessCode | Should -BeExactly '0'
            $script:bare.RebootCode | Should -BeExactly '3010'
        }

        It 'says the value is the default rather than the document' {
            # So Apply can leave the file alone when nobody touched the box.
            # Writing a key the author never named would add lines to a diff
            # that has no edit in it (DESIGN 12).
            $script:bare.SuccessCodeDeclared | Should -BeFalse
            $script:bare.RebootCodeDeclared | Should -BeFalse
        }

        It 'says the opposite for a step that does name them' {
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run Command Line'

            $page.SuccessCodeDeclared | Should -BeTrue
        }

        It 'leaves Start in empty rather than inventing one' {
            # There is no default working directory - the process service is
            # given none - so a box showing 'C:\' would be a lie about what runs.
            $script:bare.WorkingDirectory | Should -BeExactly ''
        }
    }

    Context 'a step that names neither command nor file' {

        It 'says what is wrong with it, because the engine will refuse it' {
            $broken = @'
schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal
steps:
  - name: Half a step
    type: CommandLine
    workingDirectory: C:\Deploy
'@ -split "`r?`n"

            $page = Get-HDTConsoleCommandLine -Line $broken -Path $script:path -Name 'Half a step'

            $page.IsCommandLineStep | Should -BeTrue
            $page.Note | Should -Not -BeNullOrEmpty
        }

        It 'says nothing at all when the step is finished' {
            $page = Get-HDTConsoleCommandLine -Line $script:line -Path $script:path -Name 'Run Command Line'

            $page.Note | Should -BeExactly ''
        }
    }
}
