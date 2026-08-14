function New-HDTPowerService {
    <#
        .SYNOPSIS
            Creates the real IPowerService adapter, which restarts or shuts down
            the machine.

        .DESCRIPTION
            The one place in HDT that reboots anything, behind an interface so
            the whole reboot ceremony (DESIGN 4.3, 4.5) is provable under Pester
            against New-HDTFakePowerService with nothing restarted.

              Restart($DelaySecond)
              Stop($DelaySecond)

            ROADMAP M2 deferred one question to phase 05, and 05-06 answered it
            by mounting the boot image this repository builds:

                Windows\System32\shutdown.exe   ABSENT
                Windows\System32\wpeutil.exe    PRESENT

            So the adapter's old default was not merely unverified, it was
            WRONG: a Restart step in WinPE called a command that is not there.
            Nothing caught it because DEMO-M3 and DEMO-M4 deliberately have no
            Restart step, and the IPowerService contract's real row is skipped
            permanently - a contract test may not reboot the machine running it,
            and there is no dry-run form of shutdown.exe.

            THE FIX IS A MANDATORY PARAMETER, NOT A BETTER DEFAULT. A default is
            what let every caller inherit the wrong answer in silence. The two
            payloads that build a power service already know which world they
            are in: Start-HDTDeployment.ps1 is the WinPE entry point and
            Start-HDTResume.ps1 runs from RunOnce in the deployed OS.

            IT REMAINS BRANCH-FREE, which is what earns a thin adapter its
            exemption from TDD (CLAUDE.md rule 1, tests/helpers/README.md
            section 10). Every decision lives in Get-HDTPowerCommand, which is
            pure and unit tested; this file asks, sleeps and invokes. The sleep
            is unconditional because Start-Sleep -Seconds 0 is a no-op and a
            guard would be a branch - the WinPE plan carries the delay there
            since `wpeutil reboot` has nowhere to put one.

            tests/unit/New-HDTPowerService.Tests.ps1 asserts all of that from the
            token stream, and tests/e2e/WinPeSmoke.E2E.Tests.ps1 is where this
            adapter is EXECUTED: the smoke VM is powered off by this object, in
            WinPE, and the absence of the probe's fallback marker is what proves
            it rather than the machine simply having ended.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Environment
            WinPE or FullOS - which set of commands this machine has. Mandatory
            and undefaulted, deliberately.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Restart and Stop
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $power = New-HDTPowerService -Environment FullOS
            $power.Restart(30)

        .EXAMPLE
            $power = New-HDTPowerService -Environment WinPE
            $power.Stop(0)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The restart itself is a method on the object, invoked by the engine loop.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Environment
    )

    $service = [pscustomobject] @{
        ServiceName = 'PowerService'
        Environment = $Environment
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $null
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    # The plan is fetched, not decided. Note that the recorded operation and its
    # arguments are unchanged from phase 03, so every journal assertion in
    # phases 03 to 05 still means exactly what it meant.
    $service | Add-Member -MemberType ScriptMethod -Name Restart -Value {
        param([int] $DelaySecond)

        $this.Record('Restart', @($DelaySecond))

        $plan = Get-HDTPowerCommand -Environment $this.Environment -Operation 'Restart' -DelaySecond $DelaySecond

        Start-Sleep -Seconds $plan.SleepSecond

        & $plan.Command @($plan.Argument)
    }

    $service | Add-Member -MemberType ScriptMethod -Name Stop -Value {
        param([int] $DelaySecond)

        $this.Record('Stop', @($DelaySecond))

        $plan = Get-HDTPowerCommand -Environment $this.Environment -Operation 'Stop' -DelaySecond $DelaySecond

        Start-Sleep -Seconds $plan.SleepSecond

        & $plan.Command @($plan.Argument)
    }

    return $service
}
