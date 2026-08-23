function New-HDTClock {
    <#
        .SYNOPSIS
            Creates the real IClock adapter over the system clock.

        .DESCRIPTION
            The one place in HDT that reads the wall clock or waits. PROJECT
            constraint 4 forbids engine logic from doing either directly, so the
            log writer, the state document and the retry policy all receive this
            object and can be swapped for New-HDTFakeClock in a test - which is
            what lets a backoff of several minutes be proven in microseconds.

            Two methods:

              GetUtcNow()               [datetime], always Kind = Utc
              Sleep([int] $Millisecond) blocks for that long, returns nothing

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

            Every call is recorded in $Operations, before it can throw, exactly
            as the fakes record (tests/helpers/README.md section 4), so an
            ordered-operation assertion in a contract file holds against either
            implementation.

            This is the only file in the engine permitted to name
            [datetime]::UtcNow. Everything else asks an IClock.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services, so a test can assert one ordered list
            spanning the filesystem, the clock and the registry.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with GetUtcNow and Sleep
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $clock = New-HDTClock
            $clock.GetUtcNow()

            The time the engine stamps a log record with. Every command that records
            one takes a clock rather than calling [datetime] itself, so a test can
            hand over a fixed one and assert on the stamp.

        .EXAMPLE
            $clock.Sleep(2)
            @($clock.GetOperationName())

            A real wait, and the operation list that proves it happened. The fake
            clock records the same call and returns instantly, which is how a
            retry policy is tested without waiting for it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'Clock'
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

    $service | Add-Member -MemberType ScriptMethod -Name GetUtcNow -Value {
        $this.Record('GetUtcNow', @())

        return [datetime]::UtcNow
    }

    $service | Add-Member -MemberType ScriptMethod -Name Sleep -Value {
        param([int] $Millisecond)

        $this.Record('Sleep', @($Millisecond))

        Start-Sleep -Milliseconds $Millisecond
    }

    return $service
}
