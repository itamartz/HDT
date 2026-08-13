# The Restart step ASKS for a reboot. It does not perform one.
#
# The reboot ceremony is: arm autologon -> save state -> log reboot.arm ->
# restart, and a failure between any two of those must leave a machine that can
# still be recovered. That ordering belongs to the loop (03-04), which owns the
# state document; a step that rebooted itself could not be checkpointed, which is
# the bug this whole design exists to avoid.
#
# So the assertions here are as much about what it does NOT do as what it does.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{ Index = 1; Name = $Name; Type = 'Restart'; Property = $bag }
    }
}

Describe 'Invoke-HDTRestartStep' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fileSystem = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:registry = New-HDTFakeRegistryService -Journal $script:journal
        $script:power = New-HDTFakePowerService -Journal $script:journal

        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Registry $script:registry -Power $script:power

        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $script:catalog -Log $script:log
    }

    It 'returns RebootRequested' {
        $step = & $script:newStep 'Restart' $null

        (Invoke-HDTRestartStep -Step $step -Context $script:context).Status | Should -BeExactly 'RebootRequested'
    }

    It 'returns the delay in the result data' {
        $step = & $script:newStep 'Restart' ([ordered] @{ delaySeconds = 30 })

        (Invoke-HDTRestartStep -Step $step -Context $script:context).Data.DelaySecond | Should -Be 30
    }

    It 'defaults the delay to zero' {
        $step = & $script:newStep 'Restart' $null

        (Invoke-HDTRestartStep -Step $step -Context $script:context).Data.DelaySecond | Should -Be 0
    }

    It 'returns the message it was given' {
        $step = & $script:newStep 'Restart' ([ordered] @{ message = 'restarting to finish setup' })

        (Invoke-HDTRestartStep -Step $step -Context $script:context).Message |
            Should -BeExactly 'restarting to finish setup'
    }

    It 'does not call the power service' {
        # The ceremony belongs to the loop, which owns the state document.
        $step = & $script:newStep 'Restart' ([ordered] @{ delaySeconds = 30 })

        Invoke-HDTRestartStep -Step $step -Context $script:context | Out-Null

        @($script:power.Operations).Count | Should -Be 0
    }

    It 'does not touch the registry' {
        # Nor does it arm autologon (DESIGN 4.5): that is the loop's, and it must
        # happen only once the state document has been saved.
        $step = & $script:newStep 'Restart' $null

        Invoke-HDTRestartStep -Step $step -Context $script:context | Out-Null

        @($script:registry.Operations).Count | Should -Be 0
    }

    It 'logs a step message' {
        $step = & $script:newStep 'Restart' ([ordered] @{ message = 'restarting to finish setup' })

        Invoke-HDTRestartStep -Step $step -Context $script:context | Out-Null

        [string] $script:fileSystem.File['X:\HDT\Logs\HDT.jsonl'] | Should -BeLike '*restarting to finish setup*'
    }

    It 'touches no service other than the log' {
        $step = & $script:newStep 'Restart' $null

        Invoke-HDTRestartStep -Step $step -Context $script:context | Out-Null

        @($script:journal | ForEach-Object { $_.Service }) | Sort-Object -Unique | Should -Be @('Clock', 'FileSystem')
    }

    Context 'the step contract' {

        It 'is discovered as a step type' {
            @(Get-HDTStepType -Name 'Restart')[0].Source | Should -BeExactly 'Hephaestus'
        }

        It 'describes the delay it will ask for' {
            $step = & $script:newStep 'Restart' ([ordered] @{ delaySeconds = 30 })

            Get-HDTStepDescription -Step $step | Should -BeLike '*30*'
        }
    }
}
