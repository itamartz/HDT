# ConvertFrom-HDTStepCondition parses a step's condition: into an object.
#
# DESIGN 3.3 says HDT deliberately has no condition language, and DESIGN 4.1 uses
# exactly one shape - "%_HDTPhase%" == "FullOS" - so the grammar here is CLOSED:
#
#   <condition> := <operand> <operator> <operand>
#   <operand>   := '"' anything-but-a-double-quote '"'  |  a token with no
#                  whitespace and no double quote
#   <operator>  := == | != | -eq | -ne | -like | -notlike
#
# Parsing happens at IMPORT time (Assert-HDTSequenceDocument calls this), so a
# malformed condition fails authoring rather than a deployment at 3 a.m. That is
# the whole reason this is a separate function from the evaluator.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
}

Describe 'ConvertFrom-HDTStepCondition' {

    Context 'the shape it accepts' {

        It 'parses two quoted operands' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '"%_HDTPhase%" == "FullOS"'

                $parsed.Left | Should -BeExactly '%_HDTPhase%'
                $parsed.Operator | Should -BeExactly '=='
                $parsed.Right | Should -BeExactly 'FullOS'
            }
        }

        It 'parses a bare left operand' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '%HDTIsLaptop% == "True"'

                $parsed.Left | Should -BeExactly '%HDTIsLaptop%'
                $parsed.Right | Should -BeExactly 'True'
            }
        }

        It 'parses a bare right operand' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '"%HDTIsLaptop%" == True'

                $parsed.Left | Should -BeExactly '%HDTIsLaptop%'
                $parsed.Right | Should -BeExactly 'True'
            }
        }

        It 'keeps the raw text on the result' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '  "%_HDTPhase%" == "FullOS"  '

                $parsed.Text | Should -BeExactly '  "%_HDTPhase%" == "FullOS"  '
            }
        }

        It 'parses <_> as an operator' -ForEach @('==', '!=', '-eq', '-ne', '-like', '-notlike') {
            InModuleScope Hephaestus -Parameters @{ Operator = $_ } {
                param($Operator)

                $parsed = ConvertFrom-HDTStepCondition -Condition ('"%HDTModel%" {0} "Latitude*"' -f $Operator)

                $parsed.Operator | Should -BeExactly $Operator
            }
        }

        It 'tolerates extra whitespace around the operator' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '"%HDTModel%"     ==      "Latitude 7450"'

                $parsed.Left | Should -BeExactly '%HDTModel%'
                $parsed.Operator | Should -BeExactly '=='
                $parsed.Right | Should -BeExactly 'Latitude 7450'
            }
        }

        It 'tolerates leading and trailing whitespace' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition "`t %HDTModel% == True  `t"

                $parsed.Left | Should -BeExactly '%HDTModel%'
                $parsed.Right | Should -BeExactly 'True'
            }
        }

        It 'keeps whitespace inside a quoted operand' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '"%HDTModel%" == "Latitude 7450"'

                $parsed.Right | Should -BeExactly 'Latitude 7450'
            }
        }

        It 'keeps an equals sign inside a quoted operand' {
            InModuleScope Hephaestus {
                $parsed = ConvertFrom-HDTStepCondition -Condition '"%HDTArgument%" == "mode=fast"'

                $parsed.Right | Should -BeExactly 'mode=fast'
            }
        }
    }

    Context 'what it refuses' {

        # Every refusal asserts the ERROR ID, not merely that something threw: a
        # missing implementation throws CommandNotFoundException, which satisfies
        # a bare -Throw and would make these green before the code exists
        # (tests/helpers/README.md 12).

        It 'throws for an empty condition' {
            InModuleScope Hephaestus {
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'throws for one operand' {
            InModuleScope Hephaestus {
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '%HDTModel%' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'throws for an unknown operator' {
            InModuleScope Hephaestus {
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '%HDTModel% =~ "x"' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'throws for three operands' {
            InModuleScope Hephaestus {
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '"%HDTModel%" == "a" "b"' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'throws for an unterminated quote' {
            InModuleScope Hephaestus {
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '"%HDTModel% == "a"' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'throws HDTConfigurationError naming the condition' {
            InModuleScope Hephaestus {
                # "it threw" is not an assertion (tests/helpers/README.md 12): a
                # missing implementation throws CommandNotFoundException and would
                # pass a bare -Throw. The error id and the offending text are what
                # make this test real.
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '%HDTModel% =~ "x"' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*%HDTModel% =~ "x"*'
            }
        }

        It 'refuses a boolean expression' {
            InModuleScope Hephaestus {
                # HDT has no condition language (DESIGN 3.3) and a half-working one
                # is worse than none: an -and that silently parsed as a string
                # comparison would run the wrong branch without saying so.
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition '%A% == "1" -and %B% == "2"' } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }
    }
}
