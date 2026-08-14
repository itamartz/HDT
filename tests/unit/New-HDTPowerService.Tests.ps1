# The IPowerService adapter, tested the only way an adapter that ends machines
# can be: by its metadata and its token stream.
#
# NOTHING HERE CALLS Restart OR Stop. The IPowerService contract says why, and
# says it permanently: a contract test may not reboot the machine running it, and
# there is no dry-run form of shutdown.exe. What CAN be asserted without a
# casualty is that the adapter has no decision left in it - CLAUDE.md rule 1
# exempts a thin adapter from TDD only WHILE IT STAYS BRANCH-FREE, and this file
# is what keeps that true.
#
# The decision it used to be missing lives in Get-HDTPowerCommand, which is pure
# and has 26 tests of its own. The adapter's job is now to ask, sleep, and
# invoke.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:sourcePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTPowerService.ps1'

    $script:token = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:sourcePath, [ref] $script:token, [ref] $null)

    # The comment-free token stream, so the prose above and the help inside may
    # discuss shutdown.exe and `if` freely without tripping the assertions.
    $script:code = (@($script:token |
                Where-Object { $_.Kind -ne 'Comment' } |
                ForEach-Object { [string] $_.Text }) -join ' ')
}

Describe 'New-HDTPowerService' {

    Context 'nobody can get the wrong world by accident' {

        It 'takes -Environment' {
            @((Get-Command -Name 'New-HDTPowerService').Parameters.Keys) | Should -Contain 'Environment'
        }

        It 'makes -Environment mandatory' {
            # ASSERTED ON THE METADATA, NOT BY CALLING IT WITHOUT ONE: a missing
            # mandatory parameter prompts in an interactive host, and a test that
            # hangs is worse than one that fails.
            #
            # Mandatory is the whole fix. A default of FullOS would have left
            # every existing caller on shutdown.exe - which is exactly the defect
            # this plan found, since shutdown.exe is not in WinPE at all.
            $attribute = @((Get-Command -Name 'New-HDTPowerService').Parameters['Environment'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })

            @($attribute).Count | Should -BeGreaterThan 0
            @($attribute)[0].Mandatory | Should -BeTrue
        }

        It 'accepts WinPE and FullOS and nothing else' {
            $set = @((Get-Command -Name 'New-HDTPowerService').Parameters['Environment'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues })

            @($set) | Should -Be @('WinPE', 'FullOS')
        }

        It 'no longer takes -Command' {
            # -Command existed so "the answer can be supplied without changing a
            # step or this adapter" (its own help, phase 03). The answer is in
            # now, and an override would be a way to put shutdown.exe back into
            # WinPE from a sequence file.
            @((Get-Command -Name 'New-HDTPowerService').Parameters.Keys) | Should -Not -Contain 'Command'
        }
    }

    Context 'what it carries' {

        It 'reports the environment it was built for' {
            foreach ($environment in @('WinPE', 'FullOS')) {
                $power = New-HDTPowerService -Environment $environment
                [string] $power.Environment | Should -BeExactly $environment
            }
        }

        It 'is still an IPowerService' {
            $power = New-HDTPowerService -Environment 'WinPE'

            $name = @($power | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })
            $name | Should -Contain 'Restart'
            $name | Should -Contain 'Stop'
            $name | Should -Contain 'GetOperationName'

            [string] $power.ServiceName | Should -BeExactly 'PowerService'
            @($power.Operations).Count | Should -Be 0
        }
    }

    Context 'it stays dumb' {

        It 'asks Get-HDTPowerCommand rather than deciding' {
            $script:code | Should -Match 'Get-HDTPowerCommand'
        }

        It 'can actually reach it from a caller outside the module' {
            # NOT PEDANTRY. Get-HDTPowerCommand is PRIVATE - the module exports
            # only Public\. A ScriptMethod resolves its commands in the session
            # state its scriptblock was created in, so this works only because
            # the scriptblock literal is inside the module. Get that wrong and
            # the failure is a CommandNotFoundException on the one machine
            # nobody can attach a debugger to, at the moment it was supposed to
            # reboot.
            #
            # Asserted, not invoked: invoking Restart would restart this machine.
            foreach ($name in @('Restart', 'Stop')) {
                $block = (New-HDTPowerService -Environment WinPE).PSObject.Methods[$name].Script

                [string] $block.Module.Name | Should -BeExactly 'Hephaestus'
                @(& $block.Module { Get-Command -Name 'Get-HDTPowerCommand' -ErrorAction SilentlyContinue }).Count |
                    Should -Be 1 -Because "the $name method resolves commands in that module's session state"
            }
        }

        It 'names neither executable itself' {
            # The two command names appear in exactly one file in src/, and it is
            # not this one. If they were here too, the decision would be in two
            # places and one of them would eventually be wrong.
            $script:code | Should -Not -Match 'shutdown\.exe'
            $script:code | Should -Not -Match 'wpeutil'
        }

        It 'has no branch in Restart or Stop' {
            # THE LITERAL REASON CLAUDE.md rule 1 lets this file exist without a
            # test that executes it. Scoped to the two methods that end a
            # machine, and NOT to the whole file: Record carries the journal
            # guard every adapter in this repository has, which decides nothing
            # about the outside world and is exercised on the fake row of the
            # IPowerService contract.
            $method = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Add-Member' -and
                        (@($node.CommandElements | ForEach-Object { [string] $_.Extent.Text }) -contains 'Restart' -or
                        @($node.CommandElements | ForEach-Object { [string] $_.Extent.Text }) -contains 'Stop')
                    }, $true))

            @($method).Count | Should -Be 2 -Because 'Restart and Stop are both added, and finding fewer means this assertion is looking at the wrong thing'

            foreach ($node in $method) {
                @($node.FindAll({
                            param($inner)
                            $inner -is [System.Management.Automation.Language.IfStatementAst] -or
                            $inner -is [System.Management.Automation.Language.SwitchStatementAst]
                        }, $true)) | Should -BeNullOrEmpty -Because 'a branch here is a decision that belongs in Get-HDTPowerCommand, where it would be tested'
            }
        }

        It 'sleeps unconditionally, because Start-Sleep 0 is a no-op' {
            # The WinPE plan carries the delay as SleepSecond, since wpeutil has
            # nowhere to put one. Guarding the sleep with `if ($n -gt 0)` would
            # be a branch, and this is the cheaper way to not have one.
            $script:code | Should -Match 'Start-Sleep'
        }
    }
}
