# Test-HDTRuleMatch answers the one question rule evaluation asks of every rule:
# does this rule's `when` apply to the machine in front of us (DESIGN 3.3, "a rule
# applies if every when key matches")?
#
# Four decisions are encoded here rather than left to -like:
#
#   * an ABSENT key never matches, and neither does a $null one. A rule keyed on a
#     fact this machine does not have must not fire;
#   * a LIST value matches if ANY element matches - HDTDefaultGateway is a list on
#     a multi-NIC machine, and MDT's DefaultGateway behaves the same;
#   * the operator is chosen PER PATTERN: -like when the pattern holds * or ?,
#     -eq otherwise. A model name containing '[' is a real thing, and -like would
#     read it as a character class;
#   * comparison is on ConvertTo-HDTComparableString output, so `HDTIsLaptop: true`
#     in YAML matches the [bool] fact Win32_SystemEnclosure produced.
#
# It is private, so every assertion runs inside InModuleScope. The `when` mapping
# is built inline in the shape Import-HDTRuleDocument produces - an ordered,
# case-insensitive dictionary - rather than by a helper, because a function
# defined inside one InModuleScope block is not visible inside the next one.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTRuleMatch' {

    BeforeEach {
        InModuleScope Hephaestus {
            $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:scope['HDTModel'] = 'Latitude 7450'
            $script:scope['HDTMake'] = 'Dell Inc.'
            $script:scope['HDTIsLaptop'] = $true
            $script:scope['HDTMemory'] = 32768
            $script:scope['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'
            $script:scope['HDTTPMVersion'] = $null
            $script:scope['HDTDefaultGateway'] = [string[]] @('10.20.30.254', '10.20.30.1')
            $script:scope['HDTIPAddress'] = [string[]] @()
            $script:scope['HDTBracketModel'] = 'Model[1]'
            $script:scope['HDTExpectedModel'] = 'Latitude 7450'

            $script:when = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }

    Context 'no condition' {

        It 'matches when When is null' {
            InModuleScope Hephaestus {
                Test-HDTRuleMatch -When $null -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches when When is empty' {
            InModuleScope Hephaestus {
                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }
    }

    Context 'single key' {

        It 'matches an exact string' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude 7450'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches case-insensitively' {
            InModuleScope Hephaestus {
                $script:when['hdtmodel'] = 'LATITUDE 7450'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match a different value' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude 7440'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }

        It 'matches a boolean fact against a YAML true' {
            InModuleScope Hephaestus {
                $script:when['HDTIsLaptop'] = $true

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches an integer fact against a YAML integer' {
            InModuleScope Hephaestus {
                $script:when['HDTMemory'] = 32768

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match when the key is absent from the scope' {
            InModuleScope Hephaestus {
                $script:when['HDTNeverGathered'] = 'anything'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }

        It 'does not match when the scope value is null' {
            InModuleScope Hephaestus {
                # A machine with no TPM. HDTTPMVersion exists as a fact and is
                # $null; a rule keyed on it must not fire.
                $script:when['HDTTPMVersion'] = '2.0'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }
    }

    Context 'wildcards' {

        It 'matches a trailing wildcard' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude*'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches a leading wildcard' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = '*7450'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches a single-character wildcard' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude 745?'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match a wildcard that fails' {
            InModuleScope Hephaestus {
                $script:scope['HDTModel'] = '82RF'
                $script:when['HDTModel'] = 'Latitude*'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }

        It 'treats a bracket in a pattern with no wildcard as a literal' {
            InModuleScope Hephaestus {
                # -like would read [1] as a character class and match 'Model1'
                # while failing 'Model[1]'. -eq is chosen because the pattern
                # holds no * or ?.
                $script:when['HDTBracketModel'] = 'Model[1]'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }
    }

    Context 'multiple keys' {

        It 'matches when every key matches' {
            InModuleScope Hephaestus {
                # The DESIGN 3.3 'Latitude naming' rule, verbatim.
                $script:when['HDTModel'] = 'Latitude*'
                $script:when['HDTIsLaptop'] = $true

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match when one key of two fails' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude*'
                $script:when['HDTIsLaptop'] = $false

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }

        It 'does not match when one key of three is absent' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = 'Latitude*'
                $script:when['HDTIsLaptop'] = $true
                $script:when['HDTNeverGathered'] = 'x'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }
    }

    Context 'list values' {

        It 'matches when any element of a list matches' {
            InModuleScope Hephaestus {
                $script:when['HDTDefaultGateway'] = '10.20.30.1'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'matches a wildcard against any element of a list' {
            InModuleScope Hephaestus {
                $script:when['HDTDefaultGateway'] = '10.20.30.*'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match when no element matches' {
            InModuleScope Hephaestus {
                $script:when['HDTDefaultGateway'] = '192.168.0.1'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }

        It 'does not match an empty list' {
            InModuleScope Hephaestus {
                $script:when['HDTIPAddress'] = '10.20.30.101'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }
    }

    Context 'tokens in the pattern' {

        It 'expands a %Var% in the pattern before comparing' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = '%HDTExpectedModel%'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeTrue
            }
        }

        It 'does not match when the pattern token is unresolved' {
            InModuleScope Hephaestus {
                $script:when['HDTModel'] = '%HDTNeverGathered%'

                Test-HDTRuleMatch -When $script:when -Scope $script:scope | Should -BeFalse
            }
        }
    }
}
