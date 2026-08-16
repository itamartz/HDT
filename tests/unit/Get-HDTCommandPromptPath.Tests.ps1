# "WHAT DOES A COMMAND PROMPT COST TO OPEN?" - one answer, two callers.
#
# Start-HDTCommandPrompt has always resolved ComSpec itself, and that was fine
# while it was the only thing that opened a prompt. F8 in the PROGRESS window is
# the second: that window lives in its own STA runspace with no Hephaestus
# module in it, so it cannot call Start-HDTCommandPrompt at all - it is handed
# the path and starts it.
#
# TWO PLACES RESOLVING ComSpec IS TWO PLACES TO GET IT WRONG, so the rule moved
# here and both callers ask. It is private because nothing outside the module
# has any use for it.
#
# A MISSING ComSpec IS NOT AN ERROR. The technician pressed F8 because something
# on this machine is already wrong; answering "I could not read an environment
# variable" is the least useful thing this could do.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTCommandPromptPath' {

    Context 'what it reads' {

        It 'takes ComSpec when the machine has one' {
            InModuleScope Hephaestus {
                $environment = [pscustomobject] @{}
                $environment | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
                    param([string] $Name)
                    if ($Name -eq 'ComSpec') { return 'X:\Windows\System32\cmd.exe' }
                    return ''
                }

                Get-HDTCommandPromptPath -Environment $environment | Should -BeExactly 'X:\Windows\System32\cmd.exe'
            }
        }

        It 'falls back to cmd.exe when ComSpec is empty' {
            InModuleScope Hephaestus {
                $environment = [pscustomobject] @{}
                $environment | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
                    param([string] $Name)
                    if ($Name -eq 'ComSpec') { return '' }
                    return 'not asked for'
                }

                Get-HDTCommandPromptPath -Environment $environment | Should -BeExactly 'cmd.exe'
            }
        }

        It 'falls back to cmd.exe when ComSpec is nothing but spaces' {
            InModuleScope Hephaestus {
                $environment = [pscustomobject] @{}
                $environment | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
                    param([string] $Name)
                    if ($Name -eq 'ComSpec') { return '   ' }
                    return 'not asked for'
                }

                Get-HDTCommandPromptPath -Environment $environment | Should -BeExactly 'cmd.exe'
            }
        }

        It 'falls back to cmd.exe with no environment provider at all' {
            InModuleScope Hephaestus {
                Get-HDTCommandPromptPath -Environment $null | Should -BeExactly 'cmd.exe'
            }
        }

        It 'never returns nothing, whatever it was given' {
            InModuleScope Hephaestus {
                $environment = [pscustomobject] @{}
                $environment | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
                    param([string] $Name)
                    if ($Name -eq 'ComSpec') { return $null }
                    return $null
                }

                Get-HDTCommandPromptPath -Environment $environment | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'it is the one copy of the rule' {

        It 'is what Start-HDTCommandPrompt uses' {
            # Anti-drift. The whole reason this function exists is that the
            # progress window cannot call Start-HDTCommandPrompt; if that command
            # kept its own copy, the two would answer differently on the machine
            # where it matters.
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Start-HDTCommandPrompt.ps1') -Raw

            $source | Should -Match 'Get-HDTCommandPromptPath'
        }

        It 'is what the progress display hands to its window' {
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Start-HDTProgressDisplay.ps1') -Raw

            $source | Should -Match 'Get-HDTCommandPromptPath'
        }
    }
}
