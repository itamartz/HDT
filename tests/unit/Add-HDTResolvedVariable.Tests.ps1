# Add-HDTResolvedVariable is the SINGLE WRITER of the resolution result, and the
# only place that enforces DESIGN 3.1's precedence.
#
# The precedence is not a comparison anywhere in the engine: Resolve-HDTVariable
# applies the five sources in order and this function refuses to overwrite a
# variable that is already resolved. First writer wins, so applying the sources in
# the DESIGN 3.1 order IS the precedence, and a later fallback rule can only fill
# what nothing above it set.
#
# It is also where the RAW value goes into the scope and the EXPANDED value goes
# into the result. Keeping raw values in the scope is what makes a cycle
# detectable: two variables referencing each other only look cyclic before
# expansion.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Add-HDTResolvedVariable' {

    BeforeEach {
        InModuleScope Hephaestus {
            # The resolution result in the shape Resolve-HDTVariable builds it.
            $script:resolution = [pscustomobject] @{
                Variable   = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                Provenance = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                Unresolved = New-Object -TypeName System.Collections.ArrayList
            }

            $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:scope['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'
            $script:scope['HDTModel'] = 'Latitude 7450'
        }
    }

    It 'assigns a variable that is not yet resolved' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'LAB-CLIENT' -Source 'CommandLine'

            $script:resolution.Variable['HDTTaskSequenceID'] | Should -BeExactly 'LAB-CLIENT'
        }
    }

    It 'returns true when it assigned' {
        InModuleScope Hephaestus {
            $assigned = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'LAB-CLIENT' -Source 'CommandLine'

            $assigned | Should -BeTrue
        }
    }

    It 'refuses to overwrite an already-resolved variable' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'CMD-CLIENT' -Source 'CommandLine'
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'LAB-CLIENT' -Source 'Rule' -Rule 'Lab subnet' -RuleIndex 1

            $script:resolution.Variable['HDTTaskSequenceID'] | Should -BeExactly 'CMD-CLIENT'
        }
    }

    It 'returns false when it refused' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'CMD-CLIENT' -Source 'CommandLine'
            $assigned = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'LAB-CLIENT' -Source 'Rule' -Rule 'Lab subnet' -RuleIndex 1

            $assigned | Should -BeFalse
        }
    }

    It 'leaves the first provenance record intact when it refuses' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'CMD-CLIENT' -Source 'CommandLine'
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTTaskSequenceID' -Value 'LAB-CLIENT' -Source 'Rule' -Rule 'Lab subnet' -RuleIndex 1

            $record = $script:resolution.Provenance['HDTTaskSequenceID']
            $record.Source | Should -BeExactly 'CommandLine'
            $record.Rule | Should -BeNullOrEmpty
            @($script:resolution.Provenance.Keys).Count | Should -Be 1
        }
    }

    It 'writes the raw value into the scope' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTComputerName' -Value 'LT-%HDTSerialNumber%' -Source 'Rule' -Rule 'Latitude naming' -RuleIndex 2

            # RAW, not expanded. This is the property a cycle is detected by.
            $script:scope['HDTComputerName'] | Should -BeExactly 'LT-%HDTSerialNumber%'
        }
    }

    It 'stores the expanded value in the result' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTComputerName' -Value 'LT-%HDTSerialNumber%' -Source 'Rule' -Rule 'Latitude naming' -RuleIndex 2

            $script:resolution.Variable['HDTComputerName'] | Should -BeExactly 'LT-FIXTURE-SERIAL-0001'
        }
    }

    It 'records RawValue and Expanded when expansion changed the value' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTComputerName' -Value 'LT-%HDTSerialNumber%' -Source 'Rule' -Rule 'Latitude naming' -RuleIndex 2

            $record = $script:resolution.Provenance['HDTComputerName']
            $record.RawValue | Should -BeExactly 'LT-%HDTSerialNumber%'
            $record.Value | Should -BeExactly 'LT-FIXTURE-SERIAL-0001'
            $record.Expanded | Should -BeTrue
        }
    }

    It 'records Expanded false when the value contained no token' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTJoinDomain' -Value 'lab.contoso.com' -Source 'Rule' -Rule 'Lab subnet' -RuleIndex 1

            $script:resolution.Provenance['HDTJoinDomain'].Expanded | Should -BeFalse
        }
    }

    It 'numbers provenance records from one, in assignment order' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope -Name 'HDTOne' -Value '1' -Source 'CommandLine'
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope -Name 'HDTTwo' -Value '2' -Source 'CommandLine'
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope -Name 'HDTThree' -Value '3' -Source 'CommandLine'

            @($script:resolution.Provenance.Keys) | Should -Be @('HDTOne', 'HDTTwo', 'HDTThree')
            @(@($script:resolution.Provenance.Values) | ForEach-Object { $_.Order }) | Should -Be @(1, 2, 3)
        }
    }

    It 'records the source' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTModel' -Value 'Latitude 7450' -Source 'GatheredFact'

            $script:resolution.Provenance['HDTModel'].Source | Should -BeExactly 'GatheredFact'
        }
    }

    It 'records the rule name and index for a rule source' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTJoinDomain' -Value 'lab.contoso.com' -Source 'Rule' `
                -Rule 'Lab subnet' -RuleIndex 1 -File 'C:\ws\rules.yaml'

            $record = $script:resolution.Provenance['HDTJoinDomain']
            $record.Rule | Should -BeExactly 'Lab subnet'
            $record.RuleIndex | Should -Be 1
            $record.File | Should -BeExactly 'C:\ws\rules.yaml'
        }
    }

    It 'expands every element of an array value' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTApplications' -Value @('7Zip', 'Driver-%HDTModel%') -Source 'Rule' -Rule 'Apps' -RuleIndex 1

            @($script:resolution.Variable['HDTApplications']) | Should -Be @('7Zip', 'Driver-Latitude 7450')
        }
    }

    It 'leaves a boolean value untouched' {
        InModuleScope Hephaestus {
            $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                -Name 'HDTSkipWizard' -Value $true -Source 'Rule' -Rule 'Lab subnet' -RuleIndex 1

            $script:resolution.Variable['HDTSkipWizard'] | Should -BeOfType ([bool])
            $script:resolution.Variable['HDTSkipWizard'] | Should -BeTrue
        }
    }

    It 'rejects a name starting with an underscore' {
        InModuleScope Hephaestus {
            # DESIGN 3.2: _HDT* is engine-owned. Assert-HDTRuleDocument holds this
            # for rules.yaml, but the command line and a setFrom script never pass
            # through that validator, so the single writer holds it too.
            { Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                    -Name '_HDTLogPath' -Value 'X:\HDT\Logs' -Source 'CommandLine' } |
                Should -Throw -ExpectedMessage '*_HDTLogPath*'
        }
    }

    It 'rejects a source outside the closed set' {
        InModuleScope Hephaestus {
            # The offered source is named in the message. Asserting only that
            # something threw would pass against CommandNotFoundException, which
            # is exactly the green that means nothing.
            { Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                    -Name 'HDTModel' -Value 'Latitude 7450' -Source 'Guesswork' } |
                Should -Throw -ExpectedMessage '*Guesswork*'
        }
    }

    Context 'a value the engine published rather than resolved' {

        # NOT ONE OF THE FIVE PRECEDENCE SOURCES, AND THAT IS THE POINT.
        # HDTDeploymentMethod is a fact about how this machine booted - read
        # from the provider baked into the boot image by Update-HDTBootImage -
        # not a preference an administrator expressed anywhere. It is none of
        # the seven names already in the set: it is not gathered off the
        # machine, so GatheredFact would be a lie that Invoke-HDTGatherStep
        # would then report as "could not be determined" on every Gather step
        # in every sequence.

        It 'accepts Engine as a source' {
            InModuleScope Hephaestus {
                $assigned = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                    -Name 'HDTDeploymentMethod' -Value 'MEDIA' -Source 'Engine'

                $assigned | Should -BeTrue
                $script:resolution.Variable['HDTDeploymentMethod'] | Should -BeExactly 'MEDIA'
            }
        }

        It 'records Engine in the provenance the same way it records GatheredFact' {
            InModuleScope Hephaestus {
                $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                    -Name 'HDTDeploymentMethod' -Value 'MEDIA' -Source 'Engine'
                $null = Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                    -Name 'HDTModel' -Value 'Latitude 7450' -Source 'GatheredFact'

                $engine = $script:resolution.Provenance['HDTDeploymentMethod']
                $fact = $script:resolution.Provenance['HDTModel']

                # SAME RECORD SHAPE, so a consumer switching on Source does not
                # have to know this one is different.
                @($engine.PSObject.Properties.Name) | Should -Be @($fact.PSObject.Properties.Name)

                $engine.Source | Should -BeExactly 'Engine'
                $engine.Name | Should -BeExactly 'HDTDeploymentMethod'
                $engine.Value | Should -BeExactly 'MEDIA'
                $engine.RawValue | Should -BeExactly 'MEDIA'
                $engine.Order | Should -Be 1
            }
        }

        It 'still refuses a source outside the closed set' {
            InModuleScope Hephaestus {
                # Widening a closed set is not opening it. The set is still
                # closed, and the message still names what was offered.
                { Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                        -Name 'HDTDeploymentMethod' -Value 'MEDIA' -Source 'BootImage' } |
                    Should -Throw -ExpectedMessage '*BootImage*'
            }
        }

        It 'refuses an _HDT name from the engine too, because the single writer holds that rule for every source' {
            InModuleScope Hephaestus {
                { Add-HDTResolvedVariable -Resolution $script:resolution -Scope $script:scope `
                        -Name '_HDTDeployRoot' -Value 'D:' -Source 'Engine' } |
                    Should -Throw -ExpectedMessage '*_HDTDeployRoot*'
            }
        }
    }
}
