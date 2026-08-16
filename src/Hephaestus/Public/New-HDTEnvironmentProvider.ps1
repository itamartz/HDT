function New-HDTEnvironmentProvider {
    <#
        .SYNOPSIS
            Creates the real IEnvironmentProvider adapter over the process
            environment.

        .DESCRIPTION
            The one place in HDT that reads environment variables. PROJECT
            constraint 4 forbids engine logic from using $env: directly, so
            Get-HDTMachineFact receives this object and can be swapped for
            New-HDTFakeEnvironmentProvider - which is the only way a UEFI
            machine, a BIOS machine and a machine with firmware_type unset can
            all be proven from one desk.

            The fact gatherer reads firmware_type for HDTIsUEFI, and
            PROCESSOR_ARCHITEW6432 / PROCESSOR_ARCHITECTURE for HDTArchitecture.

            GetVariable returns $null for a variable that is not set, which
            [System.Environment]::GetEnvironmentVariable already does, and
            compares names case-insensitively, which Windows already does. The
            adapter therefore stays branch-free apart from recording.

            Every lookup is recorded in $Operations, before it can throw, exactly
            as the fakes record (tests/helpers/README.md section 4).

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .OUTPUTS
            System.Management.Automation.PSCustomObject with a GetVariable
            ScriptMethod. Note that Get-Member -MemberType Method does NOT list a
            ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $environment = New-HDTEnvironmentProvider
            $environment.GetVariable('firmware_type')

            Returns 'UEFI' on a UEFI machine, which is what HDTIsUEFI is derived
            from.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    $provider = [pscustomobject] @{
        Operations = [System.Collections.ArrayList]::new()
    }

    $provider | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })
    }

    $provider | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $provider | Add-Member -MemberType ScriptMethod -Name GetVariable -Value {
        param([string] $Name)

        $this.Record('GetVariable', @($Name))

        return [System.Environment]::GetEnvironmentVariable($Name)
    }

    return $provider
}
