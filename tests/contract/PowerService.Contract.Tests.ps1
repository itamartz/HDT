# The IPowerService contract (PROJECT constraint 4, DESIGN 12.2.1).
#
#   Restart($DelaySecond)
#   Stop($DelaySecond)
#   Logoff($DelaySecond)
#
# THE REAL ROW'S BEHAVIOUR IS SKIPPED, DELIBERATELY AND PERMANENTLY. A contract
# test may not reboot the machine running it, and there is no dry-run form of
# shutdown.exe or wpeutil that would exercise the same code path. The real
# adapter is a branch-free shell-out (README section 10: adapters stay dumb
# precisely because they are not unit tested).
#
# ANSWERED IN 05-06, and this comment used to say "UNVERIFIED, RECORDED FOR
# PHASE 05: whether shutdown.exe is the right call inside WinPE, or whether it
# must be wpeutil reboot". A read-only mount of the boot image
# Update-HDTBootImage builds says shutdown.exe is NOT IN IT and wpeutil.exe is -
# see tests/integration/WinPeContent.Integration.Tests.ps1, which holds that
# against a real image. So -Environment is now mandatory on the real adapter and
# the decision lives in Get-HDTPowerCommand, which is pure and unit tested.
#
# WHERE THE REAL ADAPTER IS ACTUALLY EXECUTED, since it cannot be here:
# tests/e2e/WinPeSmoke.E2E.Tests.ps1 powers the smoke VM off with it, in WinPE.

$script:HDTImplementation = @(
    @{
        Name    = 'FakePowerService'
        Factory = { New-HDTFakePowerService }
        Skip    = $false
    }
    @{
        Name    = 'PowerService'
        Factory = { New-HDTPowerService -Environment FullOS }
        Skip    = $true
    }
)

Describe 'IPowerService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'the shape' {

        BeforeEach {
            $script:power = & $Factory $script:repoRoot
        }

        It 'exposes Logoff' {
            # MDT's FinishAction LOGOFF, and the third member of the contract.
            # It only does anything in the full OS - Get-HDTPowerCommand refuses
            # to plan one for WinPE, where nobody is logged in - but the method
            # is on every implementation, because a caller holding an
            # IPowerService must not have to ask which world made it.
            $name = @($script:power | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            $name | Should -Contain 'Logoff'
        }

        It 'exposes Restart and Stop' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            # This assertion is safe on BOTH rows, because naming a method is not
            # calling it - which is why it sits outside the skipped context.
            $name = @($script:power | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            $name | Should -Contain 'Restart'
            $name | Should -Contain 'Stop'
        }

        It 'exposes ServiceName' {
            $script:power.ServiceName | Should -BeExactly 'PowerService'
        }

        It 'exposes Operations and GetOperationName' {
            @($script:power | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name }) |
                Should -Contain 'GetOperationName'

            @($script:power.Operations).Count | Should -Be 0
        }
    }

    Context 'behaviour' -Skip:$Skip {

        BeforeEach {
            $script:power = & $Factory $script:repoRoot
        }

        It 'records Restart with the delay' {
            $script:power.Restart(30)

            @($script:power.GetOperationName()) | Should -Be @('Restart')
            @($script:power.Operations[0].Arguments) | Should -Be @(30)
        }

        It 'records Logoff with the delay' {
            $script:power.Logoff(0)

            @($script:power.GetOperationName()) | Should -Be @('Logoff')
            @($script:power.Operations)[0].Arguments | Should -Be @(0)
        }

        It 'records Stop with the delay' {
            $script:power.Stop(0)

            @($script:power.GetOperationName()) | Should -Be @('Stop')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $service = & $Factory $script:repoRoot
            $service.Journal = $journal

            $service.Restart(0)

            @($journal).Count | Should -Be 1
            $journal[0].Service | Should -BeExactly 'PowerService'
            $journal[0].Operation | Should -BeExactly 'Restart'
        }
    }
}


# EVERY CALLER OF THE POWER SERVICE, NOT THE ONE THAT WAS WRONG.
#
# -Environment is mandatory and undefaulted so nobody inherits the wrong world
# by accident, and that was enough while every caller had exactly one world to
# be in. M9 ended that: a Refresh is a wipe-and-load launched from the RUNNING
# Windows (DESIGN 3.2), so Start-HDTDeployment.ps1 - which was THE WinPE entry
# point, with a literal WinPE here and a unit test pinning it on purpose - can
# now be started on a leg where that literal is a lie. Templates\refresh.yaml's
# first leg ends with a Restart under runIn: FullOS, and the literal made it
# `wpeutil reboot` on a machine that has no wpeutil.
#
# THE RULE IS ABOUT THE FILE, NOT ABOUT A LIST OF FILENAMES. A script that
# DERIVES the phase can start on either leg, so its power service must carry the
# derived value; a script that derives no phase has one world by construction -
# Start-HDTResume.ps1 runs from RunOnce in the deployed OS, which has
# shutdown.exe and no wpeutil - and a literal is the honest answer there.
# Written this way, a THIRD entry point added tomorrow is judged by what it
# does, and a fourth that starts deriving a phase is caught the moment it does.
#
# BOTH SIDES ARE ASSERTED NON-EMPTY. A set-driven rule that matches nothing
# passes forever, and this one is looking for the absence of a literal.
Describe 'every caller of the power service tells it the truth about its world' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:caller = @()

        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') -Filter '*.ps1' -Recurse -File |
                    Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })) {

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)

            $build = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'New-HDTPowerService'
                    }, $true))

            if ($build.Count -eq 0) { continue }

            # A file that asks Get-HDTDeploymentPhase can start on either leg.
            # A file that never asks has one world by construction.
            $derives = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Get-HDTDeploymentPhase'
                    }, $true)).Count -gt 0

            foreach ($command in $build) {
                $element = @($command.CommandElements)
                $argument = $null

                for ($i = 0; $i -lt $element.Count - 1; $i++) {
                    if ($element[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $element[$i].ParameterName -eq 'Environment') {

                        $argument = $element[$i + 1]
                    }
                }

                # Computed before the literal, not inside it: an `if` in a
                # hashtable value position is a parse error in 5.1.
                $text = '<missing>'
                if ($null -ne $argument) { $text = [string] $argument.Extent.Text }

                $script:caller += [pscustomobject] @{
                    File       = $file.Name
                    Derives    = $derives
                    Argument   = $argument
                    IsVariable = ($argument -is [System.Management.Automation.Language.VariableExpressionAst])
                    Text       = $text
                }
            }
        }
    }

    It 'finds the callers at all' {
        @($script:caller).Count | Should -BeGreaterOrEqual 2 -Because 'src/ has at least the two payload entry points, and a rule that matches nothing proves nothing'
    }

    It 'gives every one of them an -Environment' {
        $missing = @($script:caller | Where-Object { $null -eq $_.Argument })

        $missing | Should -BeNullOrEmpty -Because ('-Environment is mandatory, and these pass none: {0}' -f
            (@($missing | ForEach-Object { $_.File }) -join ', '))
    }

    It 'makes a file that derives the phase carry that derived value, never a literal' {
        $eitherLeg = @($script:caller | Where-Object { $_.Derives })

        @($eitherLeg).Count | Should -BeGreaterOrEqual 1 -Because 'Start-HDTDeployment.ps1 derives its phase since M9, and is reached from both the WinPE startnet.cmd path and the full-OS Start-HDTRefresh launcher'

        $pinned = @($eitherLeg | Where-Object { -not $_.IsVariable })

        $pinned | Should -BeNullOrEmpty -Because ('a file that can start on either leg must not assert which one it is, and these do: {0}' -f
            (@($pinned | ForEach-Object { '{0} -Environment {1}' -f $_.File, $_.Text }) -join ', '))
    }

    It 'leaves a single-world file its literal' {
        $oneLeg = @($script:caller | Where-Object { -not $_.Derives })

        @($oneLeg).Count | Should -BeGreaterOrEqual 1 -Because 'Start-HDTResume.ps1 runs from RunOnce in the deployed OS and derives nothing'

        foreach ($row in $oneLeg) {
            $row.Text | Should -BeIn @('WinPE', 'FullOS', "'WinPE'", "'FullOS'") -Because (
                '{0} names one world for a reason; anything else there is a variable whose value nothing in this file decided' -f $row.File)
        }
    }
}
