# Closing the editor with work in it.
#
# THE X IS A WAY OUT AND MUST STAY ONE. Until now Close and the title-bar X both
# shut the window on the spot and threw every splice away without a word - the
# title said "unsaved changes" and pressing X agreed with it silently. Nothing
# reached the share, because Save is the only thing that writes, but the work
# was gone.
#
# SO IT ASKS, AND CLOSING IS STILL ONE OF THE ANSWERS. Save and close, close
# without saving, or stay in the window. An editor that REFUSED to close until
# the document was saved would be worse than one that discarded it: an
# administrator who has made a mess of a sequence needs to leave without writing
# it, and that is exactly when they are least able to fix it first.
#
# IT ONLY ASKS WHEN THERE IS SOMETHING TO LOSE. A window closed without an edit
# in it is closed, immediately - a dialog on every exit is a dialog nobody
# reads, and one that has trained somebody to press the same button every time
# is worse than none at all.
#
# THE WORDING IS DECIDED HERE, not in the adapter. New-HDTConsoleHost calls
# MessageBox with what these commands hand it, so what an administrator is asked
# can be read in a test rather than by provoking a dialog on a screen.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
}

Describe 'Get-HDTConsoleClosePrompt' {

    Context 'a window with nothing in it' {

        It 'does not ask' {
            $prompt = Get-HDTConsoleClosePrompt -DocumentPath $script:path

            $prompt.Ask | Should -BeFalse
        }
    }

    Context 'a window with unsaved edits' {

        BeforeAll { $script:prompt = Get-HDTConsoleClosePrompt -DocumentPath $script:path -Dirty }

        It 'asks' {
            $script:prompt.Ask | Should -BeTrue
        }

        It 'names the document, because two editors may be open on the same id' {
            # Both of this lab's shares hold a DEMO-M4. "Save your changes?" over
            # one of two identical windows is a question with no answer.
            $script:prompt.Message | Should -BeLike '*DEMO-M4*'
            $script:prompt.Message | Should -BeLike '*sequence.yaml*'
        }

        It 'offers three answers, so leaving without saving is one of them' {
            $script:prompt.Button | Should -BeExactly 'YesNoCancel'
        }

        It 'says what each answer does rather than leaving it to the button labels' {
            # 'Yes' and 'No' on their own do not say which one writes.
            $script:prompt.Message | Should -BeLike '*Yes*'
            $script:prompt.Message | Should -BeLike '*No*'
            $script:prompt.Message | Should -BeLike '*Cancel*'
        }

        It 'is a question, not a warning' {
            $script:prompt.Icon | Should -BeExactly 'Question'
            $script:prompt.Title | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-HDTConsoleCloseAnswer' {

    It 'saves and closes on <Answer>' -ForEach @(
        @{ Answer = 'Yes' }
    ) {
        $decision = Resolve-HDTConsoleCloseAnswer -Answer $Answer

        $decision.Save | Should -BeTrue
        $decision.Cancel | Should -BeFalse
    }

    It 'closes without writing on No' {
        $decision = Resolve-HDTConsoleCloseAnswer -Answer 'No'

        $decision.Save | Should -BeFalse
        $decision.Cancel | Should -BeFalse
    }

    It 'stays in the window on Cancel' {
        $decision = Resolve-HDTConsoleCloseAnswer -Answer 'Cancel'

        $decision.Save | Should -BeFalse
        $decision.Cancel | Should -BeTrue
    }

    It 'treats a dismissed dialog as Cancel, never as discard' {
        # A dialog shut with its own X, or by Escape, answered nothing. The safe
        # reading of "no answer" is the one that loses no work.
        $decision = Resolve-HDTConsoleCloseAnswer -Answer 'None'

        $decision.Cancel | Should -BeTrue
        $decision.Save | Should -BeFalse
    }

    It 'names what it decided, for the log line and the test that reads it' {
        (Resolve-HDTConsoleCloseAnswer -Answer 'Yes').Action | Should -BeExactly 'SaveAndClose'
        (Resolve-HDTConsoleCloseAnswer -Answer 'No').Action | Should -BeExactly 'Discard'
        (Resolve-HDTConsoleCloseAnswer -Answer 'Cancel').Action | Should -BeExactly 'Stay'
    }
}
