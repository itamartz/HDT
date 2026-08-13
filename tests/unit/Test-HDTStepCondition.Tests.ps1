# Test-HDTStepCondition evaluates a parsed condition against the live variable
# dictionary. It is the runtime half of the closed grammar
# ConvertFrom-HDTStepCondition defines.
#
# Two behaviours are decisions rather than mechanics:
#
#   * An ABSENT condition is true. A step with no condition: always runs, and a
#     group with no condition: imposes nothing on its children.
#   * An UNRESOLVED %Var% is left LITERAL (02-03's rule), so the comparison
#     simply fails and the token name is reported through -Unresolved. It is NOT
#     an error and it does NOT become the empty string: a condition that silently
#     collapsed to "" is how MDT-era task sequences ran the wrong branch.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
}

Describe 'Test-HDTStepCondition' {

    BeforeEach {
        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:variable['_HDTPhase'] = 'FullOS'
        $script:variable['HDTModel'] = 'Latitude 7450'
        $script:variable['HDTIsLaptop'] = $true
        $script:variable['HDTMinRam'] = 4096
    }

    Context 'no condition' {

        It 'returns true for $null' {
            Test-HDTStepCondition -Condition $null -Variable $script:variable | Should -BeTrue
        }

        It 'returns true for an empty string' {
            Test-HDTStepCondition -Condition '' -Variable $script:variable | Should -BeTrue
        }

        It 'returns true for whitespace' {
            Test-HDTStepCondition -Condition "   `t " -Variable $script:variable | Should -BeTrue
        }
    }

    Context 'comparison' {

        It 'compares two literals' {
            Test-HDTStepCondition -Condition '"a" == "a"' -Variable $script:variable | Should -BeTrue
            Test-HDTStepCondition -Condition '"a" == "b"' -Variable $script:variable | Should -BeFalse
        }

        It 'expands a variable on the left' {
            Test-HDTStepCondition -Condition '"%HDTModel%" == "Latitude 7450"' -Variable $script:variable | Should -BeTrue
        }

        It 'expands a variable on the right' {
            Test-HDTStepCondition -Condition '"Latitude 7450" == "%HDTModel%"' -Variable $script:variable | Should -BeTrue
        }

        It 'compares case-insensitively' {
            Test-HDTStepCondition -Condition '"%HDTModel%" == "LATITUDE 7450"' -Variable $script:variable | Should -BeTrue
        }

        It 'compares a boolean variable against the string True' {
            Test-HDTStepCondition -Condition '"%HDTIsLaptop%" == "True"' -Variable $script:variable | Should -BeTrue
        }

        It 'compares an integer variable' {
            Test-HDTStepCondition -Condition '"%HDTMinRam%" == "4096"' -Variable $script:variable | Should -BeTrue
        }

        It 'evaluates != as the negation of ==' {
            Test-HDTStepCondition -Condition '"%HDTModel%" != "Latitude 7450"' -Variable $script:variable | Should -BeFalse
            Test-HDTStepCondition -Condition '"%HDTModel%" != "OptiPlex"' -Variable $script:variable | Should -BeTrue
        }

        It 'evaluates -like with a trailing wildcard' {
            Test-HDTStepCondition -Condition '"%HDTModel%" -like "Latitude*"' -Variable $script:variable | Should -BeTrue
            Test-HDTStepCondition -Condition '"%HDTModel%" -like "OptiPlex*"' -Variable $script:variable | Should -BeFalse
        }

        It 'evaluates -notlike' {
            Test-HDTStepCondition -Condition '"%HDTModel%" -notlike "OptiPlex*"' -Variable $script:variable | Should -BeTrue
        }

        It 'evaluates -eq and -ne as aliases of == and !=' {
            Test-HDTStepCondition -Condition '"%HDTModel%" -eq "Latitude 7450"' -Variable $script:variable | Should -BeTrue
            Test-HDTStepCondition -Condition '"%HDTModel%" -ne "Latitude 7450"' -Variable $script:variable | Should -BeFalse
        }

        It 'evaluates the DESIGN 4.1 example against a FullOS phase' {
            # DESIGN 4.1 prints == "OS", but DESIGN 4.4.1 defines _HDTPhase as
            # WinPE or FullOS, so "OS" never matched anything. This is the
            # corrected form, and 03-05 corrects the design text.
            Test-HDTStepCondition -Condition '"%_HDTPhase%" == "FullOS"' -Variable $script:variable | Should -BeTrue

            $script:variable['_HDTPhase'] = 'WinPE'
            Test-HDTStepCondition -Condition '"%_HDTPhase%" == "FullOS"' -Variable $script:variable | Should -BeFalse
        }
    }

    Context 'unresolved tokens' {

        It 'returns false when the variable does not exist' {
            Test-HDTStepCondition -Condition '"%HDTNoSuchVariable%" == "x"' -Variable $script:variable | Should -BeFalse
        }

        It 'does not throw when the variable does not exist' {
            { Test-HDTStepCondition -Condition '"%HDTNoSuchVariable%" == "x"' -Variable $script:variable } |
                Should -Not -Throw
        }

        It 'reports the unresolved token through -Unresolved' {
            $unresolved = New-Object -TypeName System.Collections.ArrayList

            Test-HDTStepCondition -Condition '"%HDTNoSuchVariable%" == "x"' -Variable $script:variable -Unresolved $unresolved |
                Out-Null

            @($unresolved) | Should -Contain 'HDTNoSuchVariable'
        }

        It 'leaves the token literal, so a token comparison against itself is true' {
            # The honest consequence of 02-03's rule, stated here so nobody later
            # "fixes" the evaluator into emptying an unresolved token.
            Test-HDTStepCondition -Condition '"%HDTNoSuchVariable%" == "%HDTNoSuchVariable%"' -Variable $script:variable |
                Should -BeTrue
        }
    }

    Context 'what it refuses' {

        It 'throws HDTConfigurationError for a malformed condition' {
            $record = $null
            try { Test-HDTStepCondition -Condition '%HDTModel% =~ "x"' -Variable $script:variable } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Test-HDTStepCondition -ErrorAction Stop

            # Assert the NAME first: Get-Help falls back to a fuzzy search and
            # will happily return a sibling command's help
            # (tests/helpers/README.md 12).
            $help.Name | Should -BeExactly 'Test-HDTStepCondition'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
