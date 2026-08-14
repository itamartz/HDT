# The IPowerService contract (PROJECT constraint 4, DESIGN 12.2.1).
#
#   Restart($DelaySecond)
#   Stop($DelaySecond)
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
