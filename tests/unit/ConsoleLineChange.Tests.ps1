# Whether an edit actually changed the document.
#
# EVERY PAGE ON THE EDITOR COMMITS BY ITSELF - there is no Apply button anywhere
# - so its writes run on leaving a box and on leaving a STEP, not only when
# somebody asked for one. Walking through a sequence and reading it therefore
# runs the same code path as editing it.
#
# SO MARKING THE WINDOW DIRTY UNCONDITIONALLY IS WRONG TWICE OVER. It lights
# Save up for somebody who only looked, and then Save writes a file with no edit
# in it - re-serialising a document whose comments and ordering are the whole
# reason the editor splices lines instead of round-tripping YAML.
#
# THE COMPARISON IS ORDINAL AND LINE BY LINE. A YAML document differing only in
# case is a different document, and two lines that differ in trailing whitespace
# differ - the splice is textual, so the test for "did it change" has to be too.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'Test-HDTConsoleLineChange' {

    Context 'a document nobody edited' {

        It 'reports no change' {
            $line = [string[]] @('name: DEMO-05', 'description: a client')

            Test-HDTConsoleLineChange -Before $line -After $line | Should -BeFalse
        }

        It 'reports no change for an equal copy rather than the same object' {
            Test-HDTConsoleLineChange -Before ([string[]] @('a', 'b')) -After ([string[]] @('a', 'b')) |
                Should -BeFalse
        }
    }

    Context 'a line that was edited' {

        It 'reports the change' {
            Test-HDTConsoleLineChange -Before ([string[]] @('name: DEMO-05')) `
                -After ([string[]] @('name: DEMO-06')) | Should -BeTrue
        }

        It 'notices a change on the last line, not only the first' {
            Test-HDTConsoleLineChange -Before ([string[]] @('a', 'b', 'c')) `
                -After ([string[]] @('a', 'b', 'd')) | Should -BeTrue
        }

        # THE SPLICE IS TEXTUAL, so the test has to be.
        It 'notices a change of case' {
            Test-HDTConsoleLineChange -Before ([string[]] @('name: demo')) `
                -After ([string[]] @('name: DEMO')) | Should -BeTrue
        }

        It 'notices trailing whitespace' {
            Test-HDTConsoleLineChange -Before ([string[]] @('name: demo')) `
                -After ([string[]] @('name: demo ')) | Should -BeTrue
        }
    }

    Context 'a line that was added or removed' {

        It 'reports a longer document as changed' {
            Test-HDTConsoleLineChange -Before ([string[]] @('a')) -After ([string[]] @('a', 'b')) |
                Should -BeTrue
        }

        It 'reports a shorter document as changed' {
            Test-HDTConsoleLineChange -Before ([string[]] @('a', 'b')) -After ([string[]] @('a')) |
                Should -BeTrue
        }
    }

    Context 'an empty document' {

        It 'reports no change between two empty ones' {
            Test-HDTConsoleLineChange -Before ([string[]] @()) -After ([string[]] @()) | Should -BeFalse
        }

        It 'reports a change when lines arrive in an empty one' {
            Test-HDTConsoleLineChange -Before ([string[]] @()) -After ([string[]] @('a')) | Should -BeTrue
        }

        It 'accepts a null side rather than failing' {
            Test-HDTConsoleLineChange -Before $null -After ([string[]] @('a')) | Should -BeTrue
            Test-HDTConsoleLineChange -Before $null -After $null | Should -BeFalse
        }
    }

    Context 'a document with a blank line in it' {

        # EVERY SEQUENCE THIS TOOLKIT WRITES HAS BLANK LINES - between groups,
        # around the commentary the templates carry, wherever a person put one.
        # The document IS the argument here, so refusing a blank line refuses
        # every real document.
        #
        # IT WAS NOT THEORETICAL. This guard has one caller - the partition
        # page's $partitionAttempt - and every press of New, Edit, Remove or
        # either arrow died on it with "Cannot bind argument to parameter
        # 'Before' because it is an empty string", printed on the strip where
        # the command should have been. Nothing caught it because the tests
        # exercise the COMMANDS and the button sweep skips these five.
        It 'compares two documents that contain blank lines' {
            $line = [string[]] @('id: DEMO', '', 'name: demo', '')

            Test-HDTConsoleLineChange -Before $line -After $line | Should -BeFalse
        }

        It 'sees a change made in a document that contains blank lines' {
            $before = [string[]] @('id: DEMO', '', 'name: demo')
            $after = [string[]] @('id: DEMO', '', 'name: renamed')

            Test-HDTConsoleLineChange -Before $before -After $after | Should -BeTrue
        }

        It 'sees a blank line being added, because that is a change to the file' {
            Test-HDTConsoleLineChange -Before ([string[]] @('a', 'b')) -After ([string[]] @('a', '', 'b')) |
                Should -BeTrue
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Test-HDTConsoleLineChange -ErrorAction Stop

        $help.Name | Should -BeExactly 'Test-HDTConsoleLineChange'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
