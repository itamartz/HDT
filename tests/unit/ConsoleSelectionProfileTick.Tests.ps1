# WHAT ONE TICK DOES TO THE INCLUDE LIST.
#
# The profile window had a three-state tick box bound straight to a node's State
# with no handler behind it, so ticking 'WinPE' set that one box and left its
# children visibly unticked - while SAVING included the whole branch, because an
# include means the folder and everything under it. The tree was describing a
# different injection from the one that would happen, which is the one thing
# Get-HDTConsoleSelectionProfileTree's own notes say must never be true.
#
# THE TWO EXISTING HALVES ARE PURE AND STAY THAT WAY. Tree-from-includes and
# includes-from-tree were already tested; this is the third, and it is the only
# one that needs to think, because UNTICKING A CHILD OF AN INCLUDED PARENT
# cannot be expressed by removing anything - the parent has to be expanded into
# the siblings that are still wanted.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The lab share's shape: a driver store two vendors deep beside other
    # content folders.
    $script:folder = @(
        [pscustomobject] @{ Path = 'Drivers'; Name = 'Drivers'; Depth = 0; Present = $true; Truncated = $false; InfCount = 0 }
        [pscustomobject] @{ Path = 'Drivers\WinPE'; Name = 'WinPE'; Depth = 1; Present = $true; Truncated = $false; InfCount = 0 }
        [pscustomobject] @{ Path = 'Drivers\WinPE\Dell'; Name = 'Dell'; Depth = 2; Present = $true; Truncated = $false; InfCount = 0 }
        [pscustomobject] @{ Path = 'Drivers\WinPE\HP'; Name = 'HP'; Depth = 2; Present = $true; Truncated = $false; InfCount = 0 }
        [pscustomobject] @{ Path = 'Applications'; Name = 'Applications'; Depth = 0; Present = $true; Truncated = $false; InfCount = 0 }
    )
}

Describe 'Set-HDTConsoleSelectionProfileTick' {

    It 'is reachable inside the module' {
        InModuleScope Hephaestus {
            Get-Command -Name 'Set-HDTConsoleSelectionProfileTick' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'ticking a folder on' {

        It 'includes it' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @() `
                    -Path 'Drivers\WinPE' -State $true | Should -Be @('Drivers\WinPE')
            }
        }

        It 'drops what was already included underneath it, because that is now said twice' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) `
                    -Include @('Drivers\WinPE\Dell', 'Drivers\WinPE\HP') `
                    -Path 'Drivers\WinPE' -State $true | Should -Be @('Drivers\WinPE')
            }
        }

        It 'adds nothing when an ancestor already includes it' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @('Drivers') `
                    -Path 'Drivers\WinPE' -State $true | Should -Be @('Drivers')
            }
        }
    }

    Context 'ticking a folder off' {

        It 'removes it when it is in the list in its own right' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) `
                    -Include @('Drivers\WinPE', 'Applications') `
                    -Path 'Drivers\WinPE' -State $false | Should -Be @('Applications')
            }
        }

        It 'expands an included ancestor into the siblings still wanted' {
            # THE CASE THAT CANNOT BE DONE BY REMOVING SOMETHING. 'Drivers\WinPE'
            # is included and HP is being turned off, so what the profile now
            # means is Dell and not HP - and the only way to say that is to stop
            # naming the parent and start naming the child that stays.
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @('Drivers\WinPE') `
                    -Path 'Drivers\WinPE\HP' -State $false | Should -Be @('Drivers\WinPE\Dell')
            }
        }

        It 'expands every level between the included ancestor and the folder turned off' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                $answer = @(Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @('Drivers') `
                        -Path 'Drivers\WinPE\HP' -State $false)

                # Drivers held only WinPE, and WinPE held Dell and HP - so what
                # survives is Dell alone.
                $answer | Should -Be @('Drivers\WinPE\Dell')
            }
        }

        It 'leaves nothing included when the last thing is turned off' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                @(Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @('Applications') `
                        -Path 'Applications' -State $false).Count | Should -Be 0
            }
        }

        It 'does nothing when the folder was not included anyway' {
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @('Applications') `
                    -Path 'Drivers\WinPE' -State $false | Should -Be @('Applications')
            }
        }
    }

    Context 'what the tree then draws' {

        It 'ticks the children of a folder that was ticked' {
            # THE BUG, AS THE USER MET IT: tick WinPE and its children stayed
            # blank. Round-tripped through the builder, they must not.
            InModuleScope Hephaestus -Parameters @{ F = $script:folder } {
                param($F)

                $include = @(Set-HDTConsoleSelectionProfileTick -Folder ([object[]] $F) -Include @() `
                        -Path 'Drivers\WinPE' -State $true)

                $tree = @(Get-HDTConsoleSelectionProfileTree -Folder ([object[]] $F) -Include ([string[]] $include))

                $drivers = @($tree | Where-Object { $_.Path -eq 'Drivers' })[0]
                $winpe = @($drivers.Children | Where-Object { $_.Path -eq 'Drivers\WinPE' })[0]

                $winpe.State | Should -BeTrue
                foreach ($child in @($winpe.Children)) {
                    $child.State | Should -BeTrue -Because 'an include means the folder AND everything under it'
                }
            }
        }
    }
}
