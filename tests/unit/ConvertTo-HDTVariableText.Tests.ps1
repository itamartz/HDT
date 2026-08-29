# FOUND ON A LIVE MACHINE, IN THE RESOLVED-VARIABLE OUTPUT:
#
#     HDTIPAddress = 'System.Object[]' (GatheredFact)
#
# A multi-homed machine's own addresses, rendered as the name of their type.
# The cause is the format operator: `'{1}' -f $name, $value, $source` builds an
# argument ARRAY, and an array argument nests rather than flattens, so {1} is an
# Object[] and .ToString() on one is 'System.Object[]'. A [string] cast would
# have SPACE-joined it, string interpolation likewise - three renderings of one
# value, none of them the one a rule matches.
#
# THE RULE ENGINE ALREADY HAD AN ANSWER AND IT WAS WRITTEN DOWN TWICE.
# Expand-HDTVariableToken comma-joins a list so %HDTDefaultGateway% substitutes
# '10.20.30.254,10.20.30.1', and Invoke-HDTApplyUnattendStep carries a copy of
# the same four lines with a comment saying it has to, "or the two disagree
# about what a multi-valued variable is". A third copy at a log line is a fourth
# thing to forget. This is that rendering, held once.
#
# COMMA IS MDT'S SHAPE FOR THIS FACT, not a preference. ZTIGather.xml declares
# the gathered adapter settings as type="string" - OSDAdapter0IPAddressList at
# line 195 is described "Comma delimited list of IPAddress Lists", and
# SubnetMask, Gateways and DNSServerList at 196-199 the same way. MDT reserves
# type="list" - the shape that surfaces as Applications001, Applications002 -
# for authored inputs like Applications and DriverPaths (lines 334-351), never
# for a gathered address.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'ConvertTo-HDTVariableText' {

    Context 'a scalar renders exactly as the rule engine compares it' {

        It 'returns null for null' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value $null | Should -BeNullOrEmpty
            }
        }

        It 'returns a string unchanged' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value 'Latitude 7450' | Should -BeExactly 'Latitude 7450'
            }
        }

        It 'renders a boolean the way a when clause spells it' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value $true | Should -BeExactly 'True'
                ConvertTo-HDTVariableText -Value $false | Should -BeExactly 'False'
            }
        }

        It 'renders a number in the invariant culture' {
            InModuleScope Hephaestus {
                $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
                try {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('de-DE')
                    ConvertTo-HDTVariableText -Value ([int] 32768) | Should -BeExactly '32768'
                } finally {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
                }
            }
        }

        It 'renders an empty string as an empty string' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value '' | Should -BeExactly ''
            }
        }
    }

    Context 'a list is comma delimited, which is what MDT calls this fact' {

        It 'never renders the name of the type' {
            InModuleScope Hephaestus {
                # THE REGRESSION. This is the exact output a multi-homed machine
                # produced in the log.
                $text = ConvertTo-HDTVariableText -Value ([string[]] @('192.168.2.39', 'fe80::1'))

                $text | Should -Not -Match 'System\.Object'
                $text | Should -Not -Match 'System\.String'
            }
        }

        It 'joins a string array on commas' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value ([string[]] @('10.20.30.101', '10.20.30.102')) |
                    Should -BeExactly '10.20.30.101,10.20.30.102'
            }
        }

        It 'joins an object array, which is the shape a resolution stores' {
            InModuleScope Hephaestus {
                # Add-HDTResolvedVariable rebuilds an expanded list with @(),
                # so what reaches provenance is an Object[] and not the
                # [string[]] the fact table wrote.
                ConvertTo-HDTVariableText -Value (@([string[]] @('10.20.30.101', '10.20.30.102'))) |
                    Should -BeExactly '10.20.30.101,10.20.30.102'
            }
        }

        It 'renders a single element list as the bare element' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value ([string[]] @('192.168.2.39')) | Should -BeExactly '192.168.2.39'
            }
        }

        It 'renders an empty list as an empty string' {
            InModuleScope Hephaestus {
                # A machine with no IP enabled adapter. Empty, not the word null:
                # the variable exists and holds nothing.
                ConvertTo-HDTVariableText -Value ([string[]] @()) | Should -BeExactly ''
            }
        }

        It 'renders each element the way it renders that element alone' {
            InModuleScope Hephaestus {
                ConvertTo-HDTVariableText -Value @($true, [int] 32768, 'text') | Should -BeExactly 'True,32768,text'
            }
        }
    }

    Context 'it agrees with the substitution a rule would see' {

        It 'produces the same text a percent token expands to' {
            InModuleScope Hephaestus {
                $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $scope['HDTIPAddress'] = [string[]] @('10.20.30.101', 'fe80::01', '10.20.30.102')

                $expanded = Expand-HDTVariableToken -Value '%HDTIPAddress%' -Scope $scope

                ConvertTo-HDTVariableText -Value $scope['HDTIPAddress'] | Should -BeExactly $expanded
            }
        }
    }
}
