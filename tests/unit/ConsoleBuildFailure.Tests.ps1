# What the build window says when a build died without reporting why.
#
# A RUNSPACE CAN FAIL BEFORE THE COMMAND RUNS AT ALL - a module that will not
# import, for instance - and Update-HDTBootImage never gets far enough to report
# its own failure. The error exists only in the runspace's streams, and if the
# window does not go looking for it the technician is told nothing.
#
# EndInvoke IS WHAT RAISES THE RUNSPACE'S TERMINATING ERROR, and that is the
# lesson this was built from. A build that threw OUTSIDE its own try - the ISO
# step is outside it - reports nothing and leaves Streams.Error EMPTY, so the
# window said "the build ended without saying why" about a failure PowerShell
# had been holding all along.
#
# THE ORDER IS THEREFORE NOT ARBITRARY. What EndInvoke raised comes first
# because it is the terminating error; the error stream is the fallback for a
# non-terminating failure that still stopped the build; and the generic sentence
# is what is left when there genuinely is nothing.
#
# AND THE GENERIC SENTENCE IS STILL AN ANSWER. A blank detail box on a build
# that failed reads as a window that is broken rather than a build that is.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Get-HDTConsoleBuildFailure' {

    Context 'a build whose runspace raised a terminating error' {

        It 'says what EndInvoke raised' {
            Get-HDTConsoleBuildFailure -Raised 'oscdimg exited with 1' |
                Should -BeExactly 'oscdimg exited with 1'
        }

        # THE ONE THAT WAS BEING HELD ALL ALONG.
        It 'prefers it over the error stream, which is empty in that case' {
            Get-HDTConsoleBuildFailure -Raised 'oscdimg exited with 1' -Streamed @() |
                Should -BeExactly 'oscdimg exited with 1'
        }

        It 'prefers it even when the stream also has something to say' {
            # The terminating error is the one that stopped the build.
            Get-HDTConsoleBuildFailure -Raised 'oscdimg exited with 1' -Streamed @('a warning about a driver') |
                Should -BeExactly 'oscdimg exited with 1'
        }
    }

    Context 'a build that failed without a terminating error' {

        It 'falls back to the first thing in the error stream' {
            Get-HDTConsoleBuildFailure -Streamed @('the module would not import', 'and then this') |
                Should -BeExactly 'the module would not import'
        }

        It 'falls back when what was raised is blank rather than absent' {
            Get-HDTConsoleBuildFailure -Raised '' -Streamed @('the module would not import') |
                Should -BeExactly 'the module would not import'
        }

        It 'treats a whitespace-only raise as nothing raised' {
            Get-HDTConsoleBuildFailure -Raised '   ' -Streamed @('the module would not import') |
                Should -BeExactly 'the module would not import'
        }
    }

    # A BLANK BOX READS AS A BROKEN WINDOW.
    Context 'a build that left nothing behind at all' {

        It 'still says something' {
            Get-HDTConsoleBuildFailure | Should -BeExactly 'the build ended without saying why'
        }

        It 'says it for empty inputs on both sides' {
            Get-HDTConsoleBuildFailure -Raised '' -Streamed @() |
                Should -BeExactly 'the build ended without saying why'
        }

        It 'says it when the stream holds only blanks' {
            Get-HDTConsoleBuildFailure -Streamed @('', '   ') |
                Should -BeExactly 'the build ended without saying why'
        }

        It 'accepts a null stream' {
            Get-HDTConsoleBuildFailure -Raised '' -Streamed $null |
                Should -BeExactly 'the build ended without saying why'
        }
    }

    Context 'a stream whose first entry is blank but whose second is not' {

        It 'skips the blank rather than reporting it' {
            Get-HDTConsoleBuildFailure -Streamed @('', 'the module would not import') |
                Should -BeExactly 'the module would not import'
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleBuildFailure -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleBuildFailure'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
