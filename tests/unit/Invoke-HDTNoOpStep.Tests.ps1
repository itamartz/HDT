# The NoOp step exists for the engine's own tests, and it is the reason 03-04 can
# prove retry, continueOnError and reboot resume WITHOUT a real flaky thing:
#
#   fail: true           always fails
#   failAttempt: 2       fails attempts 1 and 2 and succeeds on 3
#   requestReboot: true  returns RebootRequested without rebooting anything
#
# It is also the smallest possible proof of DESIGN 12.2.1: a step that reaches
# the outside world only through the injected catalog, and this one reaches only
# the log.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Type, [string] $Name, [hashtable] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index    = 1
            Name     = $Name
            Type     = $Type
            Property = $bag
        }
    }
}

Describe 'Invoke-HDTNoOpStep' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fileSystem = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:registry = New-HDTFakeRegistryService -Journal $script:journal
        $script:process = New-HDTFakeProcessService -Journal $script:journal
        $script:power = New-HDTFakePowerService -Journal $script:journal
        $script:invoker = New-HDTFakeScriptInvoker -Journal $script:journal
        $script:cim = New-HDTFakeCimProvider -Journal $script:journal
        $script:environment = New-HDTFakeEnvironmentProvider -Journal $script:journal

        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Registry $script:registry -Process $script:process -Power $script:power `
            -ScriptInvoker $script:invoker -Cim $script:cim -Environment $script:environment

        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $script:catalog -Log $script:log
    }

    It 'returns Completed' {
        $step = & $script:newStep 'NoOp' 'Do nothing' $null

        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
    }

    It 'logs a step message' {
        $step = & $script:newStep 'NoOp' 'Do nothing' @{ message = 'nothing happened' }

        Invoke-HDTNoOpStep -Step $step -Context $script:context | Out-Null

        @($script:fileSystem.GetOperationName()) | Should -Contain 'AppendAllText'
        $script:fileSystem.File['X:\HDT\Logs\HDT.jsonl'] | Should -BeLike '*nothing happened*'
    }

    It 'returns the message it was given' {
        $step = & $script:newStep 'NoOp' 'Do nothing' @{ message = 'nothing happened' }

        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Message | Should -BeExactly 'nothing happened'
    }

    It 'fails when fail is true' {
        $step = & $script:newStep 'NoOp' 'Break' @{ fail = $true }

        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'Failed'
    }

    It 'returns the exit code it was given' {
        $step = & $script:newStep 'NoOp' 'Break' @{ fail = $true; exitCode = 87 }

        (Invoke-HDTNoOpStep -Step $step -Context $script:context).ExitCode | Should -Be 87
    }

    It 'fails while the attempt is at or below failAttempt' {
        $step = & $script:newStep 'NoOp' 'Flaky' @{ failAttempt = 2 }

        $script:context.Attempt = 1
        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'Failed'

        $script:context.Attempt = 2
        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'Failed'
    }

    It 'succeeds once the attempt is past failAttempt' {
        # This is how 03-04 proves retry without a real flaky thing.
        $step = & $script:newStep 'NoOp' 'Flaky' @{ failAttempt = 2 }

        $script:context.Attempt = 3
        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
    }

    It 'returns RebootRequested when requestReboot is true' {
        $step = & $script:newStep 'NoOp' 'Ask for a reboot' @{ requestReboot = $true }

        (Invoke-HDTNoOpStep -Step $step -Context $script:context).Status | Should -BeExactly 'RebootRequested'
    }

    It 'does not reboot anything when it requests a reboot' {
        $step = & $script:newStep 'NoOp' 'Ask for a reboot' @{ requestReboot = $true }

        Invoke-HDTNoOpStep -Step $step -Context $script:context | Out-Null

        @($script:power.Operations).Count | Should -Be 0
    }

    It 'touches no service other than the log' {
        # DESIGN 12.2.1 in miniature: the ONLY services a NoOp reaches are the
        # two the log writes through.
        $step = & $script:newStep 'NoOp' 'Do nothing' @{ message = 'nothing happened' }

        Invoke-HDTNoOpStep -Step $step -Context $script:context | Out-Null

        foreach ($service in @($script:registry, $script:process, $script:power, $script:invoker, $script:cim, $script:environment)) {
            @($service.Operations).Count | Should -Be 0
        }

        @($script:journal | ForEach-Object { $_.Service }) | Sort-Object -Unique | Should -Be @('Clock', 'FileSystem')
    }

    It 'is discovered as a step type' {
        @(Get-HDTStepType -Name 'NoOp')[0].Source | Should -BeExactly 'Hephaestus'
    }

    It 'describes itself with its message' {
        # Its own Get-HDT<Type>StepDescription, not the dispatcher's default -
        # which is what proves the optional half of the DESIGN 4.2 triple is
        # actually wired up rather than merely absent.
        $step = & $script:newStep 'NoOp' 'Do nothing' @{ message = 'nothing happened' }

        Get-HDTStepDescription -Step $step | Should -BeExactly 'NoOp: nothing happened'
    }

    It 'describes itself by name when it has no message' {
        $step = & $script:newStep 'NoOp' 'Do nothing' $null

        Get-HDTStepDescription -Step $step | Should -BeExactly 'NoOp: Do nothing'
    }
}
