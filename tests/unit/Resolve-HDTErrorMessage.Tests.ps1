# THE SENTENCE SOMEBODY WROTE, NOT THE FOUR LAYERS OF PLUMBING AROUND IT.
#
# What the console actually showed a technician when a task sequence held two
# steps with the same name:
#
#   Exception calling "Show" with "13" argument(s): "Exception calling
#   "ShowDialog" with "0" argument(s): "Exception calling "ShowEditor" with
#   "10" argument(s): "Exception calling "ShowDialog" with "0" argument(s):
#   "Tattoo: this task sequence holds 2 steps called 'Tattoo', so the one to act
#   on is ambiguous. Rename one of them first.""""
#
# The last clause is the whole message. Everything before it is PowerShell
# reporting that a method called a method called a method - true, and of no use
# to the person standing in front of the window.
#
# WHY IT HAPPENS: every ScriptMethod hop wraps the failure in a
# MethodInvocationException whose Message QUOTES the inner one. Reading
# .Exception.Message gets the outermost, which contains all of them nested.
# .InnerException is the real one, and the innermost is the sentence.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A chain the way PowerShell builds one: each layer quoting the next.
    $script:nested = {
        param([int] $Depth, [string] $Innermost)

        $exception = [System.InvalidOperationException]::new($Innermost)

        for ($i = 1; $i -le $Depth; $i++) {
            $wrapped = 'Exception calling "Show" with "{0}" argument(s): "{1}"' -f $i, $exception.Message
            $exception = [System.Management.Automation.MethodInvocationException]::new($wrapped, $exception)
        }

        return $exception
    }
}

Describe 'Resolve-HDTErrorMessage' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Resolve-HDTErrorMessage' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what it returns' {

        It 'returns the innermost message from a chain <_> deep' -ForEach @(1, 2, 4, 8) {
            $exception = & $script:nested $PSItem 'this task sequence holds 2 steps called Tattoo'

            Resolve-HDTErrorMessage -Exception $exception |
                Should -BeExactly 'this task sequence holds 2 steps called Tattoo'
        }

        It 'returns the message unchanged when nothing wrapped it' {
            $exception = [System.InvalidOperationException]::new('disk 0 carries existing data')

            Resolve-HDTErrorMessage -Exception $exception |
                Should -BeExactly 'disk 0 carries existing data'
        }

        It 'takes an ErrorRecord as well, because that is what a catch block holds' {
            $record = $null
            try {
                throw [System.InvalidOperationException]::new('the share could not be reached')
            } catch {
                $record = $_
            }

            Resolve-HDTErrorMessage -ErrorRecord $record |
                Should -BeExactly 'the share could not be reached'
        }

        It 'says something rather than nothing when handed nothing' {
            # A dialog with an empty body is a dialog that tells a technician
            # less than no dialog at all.
            Resolve-HDTErrorMessage -Exception $null | Should -Not -BeNullOrEmpty
        }

        It 'never returns an empty string for an exception with a blank message' {
            $exception = [System.InvalidOperationException]::new('')

            Resolve-HDTErrorMessage -Exception $exception | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the shape the console hit' {

        It 'unwraps the real thing' {
            # The actual chain, retyped from the dialog.
            $inner = [System.InvalidOperationException]::new(
                "Tattoo: this task sequence holds 2 steps called 'Tattoo', so the one to act on is ambiguous. Rename one of them first.")

            $a = [System.Management.Automation.MethodInvocationException]::new(
                'Exception calling "ShowDialog" with "0" argument(s): "{0}"' -f $inner.Message, $inner)
            $b = [System.Management.Automation.MethodInvocationException]::new(
                'Exception calling "ShowEditor" with "10" argument(s): "{0}"' -f $a.Message, $a)
            $c = [System.Management.Automation.MethodInvocationException]::new(
                'Exception calling "Show" with "13" argument(s): "{0}"' -f $b.Message, $b)

            $answer = Resolve-HDTErrorMessage -Exception $c

            $answer | Should -BeLike '*ambiguous*'
            $answer | Should -Not -BeLike '*Exception calling*'
        }
    }
}
