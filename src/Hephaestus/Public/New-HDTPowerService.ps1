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

            A branch-free shell-out to shutdown.exe, which is what keeps the
            untested surface bounded (DESIGN 12.2.3, tests/helpers/README.md
            section 10). The real row of the IPowerService contract is skipped
            permanently and deliberately: a contract test may not reboot the
            machine running it, and there is no dry-run form of shutdown.exe that
            would exercise the same path.

            UNVERIFIED, RECORDED FOR PHASE 05: whether shutdown.exe is the right
            call inside WinPE, or whether it must be `wpeutil reboot`. Nothing in
            phase 03 reboots anything, so the question is deferred honestly
            rather than guessed at - and -Command exists so the answer can be
            supplied without changing a step or this adapter.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Command
            The executable that performs the restart. Defaults to shutdown.exe.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Restart and Stop
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $power = New-HDTPowerService
            $power.Restart(30)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The restart itself is a method on the object, invoked by the engine loop.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Command = 'shutdown.exe'
    )

    $service = [pscustomobject] @{
        ServiceName = 'PowerService'
        Command     = $Command
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

    $service | Add-Member -MemberType ScriptMethod -Name Restart -Value {
        param([int] $DelaySecond)

        $this.Record('Restart', @($DelaySecond))

        & $this.Command '/r' '/t' ([string] $DelaySecond) '/f'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Stop -Value {
        param([int] $DelaySecond)

        $this.Record('Stop', @($DelaySecond))

        & $this.Command '/s' '/t' ([string] $DelaySecond) '/f'
    }

    return $service
}
