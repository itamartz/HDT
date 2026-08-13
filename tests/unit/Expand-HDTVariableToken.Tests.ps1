# Expand-HDTVariableToken is DESIGN 3.3's "%Var% expands against already-resolved
# variables".
#
# Three of its behaviours are decisions rather than mechanics, and each has its
# own Context here:
#
#   * recursion  - a token may name a variable whose own value holds a token, so
#                  expansion is recursive rather than single-pass;
#   * cycles     - which is why a cycle must be DETECTED AND REPORTED rather than
#                  hang (ROADMAP M1 "recursive and cyclic %Var% expansion"). The
#                  cycle is caught by the chain of names being expanded, not by a
#                  depth counter, so the message can name the whole cycle;
#   * unresolved - a token naming nothing is left LITERALLY in the output and its
#                  name is reported. MDT leaves such a token alone, and silently
#                  emptying it hides authoring mistakes.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop
}

Describe 'Expand-HDTVariableToken' {

    Context 'substitution' {

        BeforeEach {
            InModuleScope Hephaestus {
                $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $script:scope['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'
                $script:scope['HDTModel'] = 'Latitude 7450'
                $script:scope['HDTIsLaptop'] = $true
                $script:scope['HDTDefaultGateway'] = [string[]] @('10.20.30.254', '10.20.30.1')
            }
        }

        It 'returns a value with no token unchanged' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value 'PC-0001' -Scope $script:scope | Should -BeExactly 'PC-0001'
            }
        }

        It 'expands a single token' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value 'LT-%HDTSerialNumber%' -Scope $script:scope |
                    Should -BeExactly 'LT-FIXTURE-SERIAL-0001'
            }
        }

        It 'expands more than one token in one value' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '%HDTModel%/%HDTSerialNumber%' -Scope $script:scope |
                    Should -BeExactly 'Latitude 7450/FIXTURE-SERIAL-0001'
            }
        }

        It 'expands a token in the middle of a path' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value 'Dell\%HDTModel%\x64' -Scope $script:scope |
                    Should -BeExactly 'Dell\Latitude 7450\x64'
            }
        }

        It 'looks the token name up case-insensitively' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '%hdtmodel%' -Scope $script:scope | Should -BeExactly 'Latitude 7450'
            }
        }

        It 'renders a boolean value as True' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value 'laptop=%HDTIsLaptop%' -Scope $script:scope | Should -BeExactly 'laptop=True'
            }
        }

        It 'joins a list value with a comma' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '%HDTDefaultGateway%' -Scope $script:scope |
                    Should -BeExactly '10.20.30.254,10.20.30.1'
            }
        }
    }

    Context 'recursion' {

        BeforeEach {
            InModuleScope Hephaestus {
                $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $script:scope['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'
                $script:scope['HDTNamePrefix'] = 'LT-%HDTSerialNumber%'
                $script:scope['HDTOne'] = 'deep'
                $script:scope['HDTTwo'] = '%HDTOne%'
                $script:scope['HDTThree'] = '%HDTTwo%'
            }
        }

        It 'expands a token whose value contains another token' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '%HDTNamePrefix%' -Scope $script:scope |
                    Should -BeExactly 'LT-FIXTURE-SERIAL-0001'
            }
        }

        It 'expands three levels deep' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '<%HDTThree%>' -Scope $script:scope | Should -BeExactly '<deep>'
            }
        }
    }

    Context 'cycles' {

        BeforeEach {
            InModuleScope Hephaestus {
                $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $script:scope['HDTDirect'] = '%HDTDirect%'
                $script:scope['HDTA'] = '%HDTB%'
                $script:scope['HDTB'] = '%HDTA%'
            }
        }

        It 'throws for a direct cycle' {
            InModuleScope Hephaestus {
                { Expand-HDTVariableToken -Value '%HDTDirect%' -Scope $script:scope } |
                    Should -Throw -ExpectedMessage '*cyclic*'
            }
        }

        It 'throws for an indirect cycle' {
            InModuleScope Hephaestus {
                { Expand-HDTVariableToken -Value '%HDTA%' -Scope $script:scope } |
                    Should -Throw -ExpectedMessage '*cyclic*'
            }
        }

        It 'names every variable in the cycle' {
            InModuleScope Hephaestus {
                $record = $null
                try { Expand-HDTVariableToken -Value '%HDTA%' -Scope $script:scope } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.Exception.Message | Should -BeLike '*%HDTA%*'
                $record.Exception.Message | Should -BeLike '*%HDTB%*'
            }
        }

        It 'uses the HDTConfigurationError error id for a cycle' {
            InModuleScope Hephaestus {
                $record = $null
                try { Expand-HDTVariableToken -Value '%HDTA%' -Scope $script:scope } catch { $record = $_ }

                $record | Should -Not -BeNullOrEmpty
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }

        It 'completes rather than hanging' {
            # ROADMAP M1: a cyclic expansion is "detected and reported, not hang".
            #
            # This runs in a CHILD PROCESS on purpose. An implementation that
            # recursed without a chain check would not hang politely - it would
            # overflow the stack, and a StackOverflowException cannot be caught,
            # so it would take the whole test host down with it. A job contains
            # that, and the timeout turns a hang into a failed assertion rather
            # than a suite that never finishes.
            # $using: rather than -ArgumentList: PSUseUsingScopeModifierInNewRunspaces
            # does not recognise the param/-ArgumentList form and the lint task
            # fails the build on a warning.
            $manifest = $script:manifestPath

            $job = Start-Job -ScriptBlock {
                Import-Module -Name $using:manifest -Force -ErrorAction Stop
                $module = Get-Module -Name Hephaestus

                # The private function is reached the way InModuleScope reaches
                # it: a scriptblock invoked in the module's own session state.
                & $module {
                    $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $scope['HDTA'] = '%HDTB%'
                    $scope['HDTB'] = '%HDTA%'

                    try {
                        $null = Expand-HDTVariableToken -Value '%HDTA%' -Scope $scope
                        'NO ERROR WAS RAISED'
                    } catch {
                        $_.Exception.Message
                    }
                }
            }

            try {
                $finished = @(Wait-Job -Job $job -Timeout 90)
                $finished.Count | Should -Be 1 -Because 'a cyclic expansion must terminate, not hang'

                $message = @(Receive-Job -Job $job) -join "`n"
                $message | Should -BeLike '*cyclic*'
            } finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'unresolved tokens' {

        BeforeEach {
            InModuleScope Hephaestus {
                $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $script:scope['HDTModel'] = 'Latitude 7450'
                $script:scope['HDTNothing'] = $null
                $script:unresolved = New-Object -TypeName System.Collections.ArrayList
            }
        }

        It 'leaves an unknown token literally in the output' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value 'PC-%HDTMissing%' -Scope $script:scope |
                    Should -BeExactly 'PC-%HDTMissing%'
            }
        }

        It 'records an unknown token in the supplied Unresolved list' {
            InModuleScope Hephaestus {
                $null = Expand-HDTVariableToken -Value 'PC-%HDTMissing%' -Scope $script:scope -Unresolved $script:unresolved

                @($script:unresolved) | Should -Be @('HDTMissing')
            }
        }

        It 'leaves a token whose value is null literally in the output' {
            InModuleScope Hephaestus {
                $result = Expand-HDTVariableToken -Value 'PC-%HDTNothing%' -Scope $script:scope -Unresolved $script:unresolved

                $result | Should -BeExactly 'PC-%HDTNothing%'
                @($script:unresolved) | Should -Be @('HDTNothing')
            }
        }

        It 'records each unknown token only once' {
            InModuleScope Hephaestus {
                $null = Expand-HDTVariableToken -Value '%HDTMissing%-%HDTMissing%-%HDTModel%' -Scope $script:scope -Unresolved $script:unresolved

                @($script:unresolved).Count | Should -Be 1
            }
        }
    }

    Context 'escaping and types' {

        BeforeEach {
            InModuleScope Hephaestus {
                $script:scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $script:scope['HDTModel'] = 'Latitude 7450'
            }
        }

        It 'renders a double percent as a single literal percent' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '100%% complete' -Scope $script:scope | Should -BeExactly '100% complete'
            }
        }

        It 'does not treat a lone percent as a token' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '50% done' -Scope $script:scope | Should -BeExactly '50% done'
            }
        }

        It 'does not treat %1% as a token' {
            InModuleScope Hephaestus {
                # The grammar requires a letter or underscore first, so a batch
                # file's %1 %2 arguments survive a rules.yaml unharmed.
                Expand-HDTVariableToken -Value 'call script.cmd %1% %2%' -Scope $script:scope |
                    Should -BeExactly 'call script.cmd %1% %2%'
            }
        }

        It 'returns an empty string unchanged' {
            InModuleScope Hephaestus {
                Expand-HDTVariableToken -Value '' -Scope $script:scope | Should -BeExactly ''
            }
        }
    }
}
