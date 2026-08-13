# The fake IPowerService exists so the reboot ceremony can be asserted without
# rebooting the machine running the suite. Its whole job is to RECORD and do
# nothing, which is why the assertions here are about $Operations and never
# about an effect.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakePowerService' {

    It 'records Restart with the delay' {
        $power = New-HDTFakePowerService

        $power.Restart(30)

        $power.GetOperationName() | Should -Be @('Restart')
        @($power.Operations[0].Arguments) | Should -Be @(30)
    }

    It 'records Stop with the delay' {
        $power = New-HDTFakePowerService

        $power.Stop(0)

        $power.GetOperationName() | Should -Be @('Stop')
        @($power.Operations[0].Arguments) | Should -Be @(0)
    }

    It 'restarts nothing' {
        # The whole point. There is no assertion available beyond "it recorded
        # and returned", because the alternative outcome would end the test run.
        $power = New-HDTFakePowerService

        { $power.Restart(0) } | Should -Not -Throw
        @($power.Operations).Count | Should -Be 1
    }

    It 'counts repeated restarts' {
        $power = New-HDTFakePowerService

        $power.Restart(0)
        $power.Restart(15)

        $power.GetOperationName() | Should -Be @('Restart', 'Restart')
        $power.Operations[1].Sequence | Should -Be 2
        @($power.Operations[1].Arguments) | Should -Be @(15)
    }

    It 'exposes ServiceName' {
        (New-HDTFakePowerService).ServiceName | Should -BeExactly 'PowerService'
    }
}
