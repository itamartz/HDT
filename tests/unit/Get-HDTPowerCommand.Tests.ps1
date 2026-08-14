# The answer to ROADMAP M2's deferred question, as pure logic.
#
# M2 asked, and named phase 05 as the owner: "does WinPE need `wpeutil reboot`
# rather than `shutdown.exe`". The answer is not a preference. A read-only mount
# of the boot image Update-HDTBootImage builds says:
#
#     Windows\System32\shutdown.exe   ABSENT
#     Windows\System32\wpeutil.exe    PRESENT, 32768 bytes
#
# tests/integration/WinPeContent.Integration.Tests.ps1 makes that a standing
# assertion against a real mounted image. This file is what the engine does
# about it.
#
# THE DECISION IS PURE AND THE ADAPTER IS DUMB, which is the split the whole
# repository runs on (CLAUDE.md rule 1: an adapter is exempt from TDD only while
# it stays branch-free). So every branch lives here, where it is asserted as an
# EXACT command and an EXACT argument array rather than by pattern - a `/t 30`
# that came out `/t30` would pass a -Match and fail on a machine.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # One call, one place. Every It below goes through this rather than repeating
    # the InModuleScope ceremony, because the private function is not exported.
    $script:HDTPowerPlan = {
        param([string] $Environment, [string] $Operation, [int] $DelaySecond)

        InModuleScope Hephaestus -Parameters @{
            Environment = $Environment; Operation = $Operation; DelaySecond = $DelaySecond
        } {
            param($Environment, $Operation, $DelaySecond)
            Get-HDTPowerCommand -Environment $Environment -Operation $Operation -DelaySecond $DelaySecond
        }
    }
}

Describe 'Get-HDTPowerCommand' {

    Context 'the four combinations, as exact strings' {

        # WinPE takes wpeutil and a verb; the full OS takes shutdown.exe and
        # switches. There is no third row and there is no overlap: the two
        # commands do not exist in each other's world.
        $script:HDTPowerCase = @(
            @{
                Environment = 'FullOS'; Operation = 'Restart'; Delay = 30
                Command     = 'shutdown.exe'; Argument = @('/r', '/t', '30', '/f'); Sleep = 0
            }
            @{
                Environment = 'FullOS'; Operation = 'Stop'; Delay = 0
                Command     = 'shutdown.exe'; Argument = @('/s', '/t', '0', '/f'); Sleep = 0
            }
            @{
                Environment = 'WinPE'; Operation = 'Restart'; Delay = 0
                Command     = 'wpeutil.exe'; Argument = @('reboot'); Sleep = 0
            }
            @{
                Environment = 'WinPE'; Operation = 'Stop'; Delay = 0
                Command     = 'wpeutil.exe'; Argument = @('shutdown'); Sleep = 0
            }
        )

        It 'runs <Command> for <Operation> in <Environment>' -ForEach $script:HDTPowerCase {
            $plan = & $script:HDTPowerPlan $Environment $Operation $Delay

            [string] $plan.Command | Should -BeExactly $Command
        }

        It 'passes exactly <Argument> for <Operation> in <Environment>' -ForEach $script:HDTPowerCase {
            $expected = $Argument
            $plan = & $script:HDTPowerPlan $Environment $Operation $Delay

            @($plan.Argument) | Should -Be $expected
        }

        It 'reports the environment and the operation it was asked for: <Environment>/<Operation>' -ForEach $script:HDTPowerCase {
            $plan = & $script:HDTPowerPlan $Environment $Operation $Delay

            [string] $plan.Environment | Should -BeExactly $Environment
            [string] $plan.Operation | Should -BeExactly $Operation
        }

        It 'sleeps <Sleep> second(s) before <Operation> in <Environment>' -ForEach $script:HDTPowerCase {
            $plan = & $script:HDTPowerPlan $Environment $Operation $Delay

            [int] $plan.SleepSecond | Should -Be $Sleep
        }
    }

    Context 'the delay, which the two worlds honour differently' {

        It 'gives shutdown.exe the delay and sleeps for none of it' {
            # shutdown.exe /t is the delay. Sleeping as well would double it.
            $plan = & $script:HDTPowerPlan 'FullOS' 'Restart' 45

            @($plan.Argument) | Should -Be @('/r', '/t', '45', '/f')
            [int] $plan.SleepSecond | Should -Be 0
        }

        It 'sleeps the delay itself in WinPE, because wpeutil has no delay verb' {
            # wpeutil reboot | shutdown take no arguments at all. Dropping the
            # delay silently would make `delaySecond:` a lie in WinPE; sleeping
            # is the only honest way to honour it, and the plan says so out loud
            # rather than the adapter deciding.
            $plan = & $script:HDTPowerPlan 'WinPE' 'Restart' 45

            @($plan.Argument) | Should -Be @('reboot')
            [int] $plan.SleepSecond | Should -Be 45
        }

        It 'refuses a negative delay by name' {
            { & $script:HDTPowerPlan 'FullOS' 'Restart' -5 } |
                Should -Throw -ErrorId 'HDTConfigurationError,Get-HDTPowerCommand'
        }

        It 'says the offending value in the refusal' {
            $message = ''
            try {
                & $script:HDTPowerPlan 'WinPE' 'Stop' -1
            } catch {
                $message = [string] $_.Exception.Message
            }

            $message | Should -Match '-1'
        }
    }

    Context 'what it refuses to be asked' {

        # Asserted on the ValidateSet message rather than on "it threw": a
        # function that does not exist also throws, and these two would have
        # been green before a line of it was written (SPIKES S9.15b).

        It 'takes no environment but WinPE and FullOS' {
            { & $script:HDTPowerPlan 'Winpe2' 'Restart' 0 } |
                Should -Throw -ExpectedMessage '*does not belong to the set*WinPE*FullOS*'
        }

        It 'takes no operation but Restart and Stop' {
            { & $script:HDTPowerPlan 'WinPE' 'Hibernate' 0 } |
                Should -Throw -ExpectedMessage '*does not belong to the set*Restart*Stop*'
        }
    }

    Context 'the fact it exists for' {

        It 'never yields shutdown.exe in WinPE' {
            # THE ASSERTION THIS WHOLE FILE IS FOR. shutdown.exe is not in the
            # boot image - not a different flavour of it, not a stub, ABSENT -
            # so a plan naming it in WinPE is a plan that cannot execute.
            foreach ($operation in @('Restart', 'Stop')) {
                $plan = & $script:HDTPowerPlan 'WinPE' $operation 0
                [string] $plan.Command | Should -Not -BeExactly 'shutdown.exe'
            }
        }

        It 'never yields wpeutil.exe in the full OS' {
            # And the converse, which is just as real: wpeutil.exe ships with
            # WinPE and is not on a deployed Windows install.
            foreach ($operation in @('Restart', 'Stop')) {
                $plan = & $script:HDTPowerPlan 'FullOS' $operation 0
                [string] $plan.Command | Should -Not -BeExactly 'wpeutil.exe'
            }
        }

        It 'carries a reason a log can print' {
            # A log line saying "ran wpeutil.exe reboot" is not as useful as one
            # that says why, on the machine where somebody is reading it at 3am.
            $plan = & $script:HDTPowerPlan 'WinPE' 'Restart' 0

            [string] $plan.Reason | Should -Not -BeNullOrEmpty
            [string] $plan.Reason | Should -Match 'WinPE'
        }
    }

    Context 'it is pure' {

        It 'reads no environment variable and invokes nothing' {
            # A decision that read $env:SystemRoot or called an executable could
            # not be asserted on a developer machine for the world it is deciding
            # about. Asserted over the comment-free token stream so the prose
            # above may discuss wpeutil.exe freely.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private/Get-HDTPowerCommand.ps1'
            Test-Path -LiteralPath $path | Should -BeTrue

            $token = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $null)

            $text = (@($token |
                        Where-Object { $_.Kind -ne 'Comment' } |
                        ForEach-Object { [string] $_.Text }) -join ' ')

            $text | Should -Not -Match '\$env:'
            $text | Should -Not -Match 'Start-Sleep'
            $text | Should -Not -Match 'Test-Path'
        }
    }
}
