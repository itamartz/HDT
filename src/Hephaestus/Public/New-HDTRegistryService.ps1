function New-HDTRegistryService {
    <#
        .SYNOPSIS
            Creates the real IRegistryService adapter, read subset, over the
            registry provider.

        .DESCRIPTION
            The one place in HDT that reads the registry. PROJECT constraint 4
            forbids engine logic from touching it directly, so
            Get-HDTMachineFact receives this object and can be swapped for
            New-HDTFakeRegistryService in a test.

            It implements the read subset the fact gatherer needs - TestPath and
            GetValue - which today is the SecureBoot state key of DESIGN 3.2.1.
            Phase 03 extends the same interface with the write half for the
            autologon lifecycle in DESIGN 4.5, so these two names are chosen to
            make that extension additive.

            GetValue returns $null for a missing key and for a missing value
            name, and never throws. That is the contract, not a branch on data:
            on a BIOS machine
            HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State genuinely
            does not exist, and a gatherer that had to catch would swallow real
            errors too.

            Paths are PowerShell provider paths (HKLM:\...). The long hive names
            - HKEY_LOCAL_MACHINE\ and friends - are accepted as synonyms, because
            that is how a runbook or a rules file tends to write them.

            Every call is recorded in $Operations, before it can throw, exactly
            as the fakes record (tests/helpers/README.md section 4), so
            provenance and query-order assertions work against either
            implementation.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .OUTPUTS
            System.Management.Automation.PSCustomObject with TestPath and
            GetValue ScriptMethods. Note that Get-Member -MemberType Method does
            NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $registry = New-HDTRegistryService
            $registry.GetValue('HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State', 'UEFISecureBootEnabled')

            Returns 1 on a Secure Boot machine and $null on a BIOS machine, which
            is what HDTSecureBootEnabled is derived from.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    $service = [pscustomobject] @{
        Operations = [System.Collections.ArrayList]::new()
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name NormalizePath -Value {
        param([string] $Path)

        $normalized = $Path
        $normalized = $normalized -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'
        $normalized = $normalized -replace '^HKEY_CURRENT_USER\\', 'HKCU:\'
        $normalized = $normalized -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\'
        $normalized = $normalized -replace '^HKEY_USERS\\', 'HKU:\'

        return $normalized.TrimEnd('\')
    }

    $service | Add-Member -MemberType ScriptMethod -Name TestPath -Value {
        param([string] $Path)

        $this.Record('TestPath', @($Path))

        return [bool] (Test-Path -LiteralPath $this.NormalizePath($Path))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param([string] $Path, [string] $Name)

        $this.Record('GetValue', @($Path, $Name))

        $item = Get-ItemProperty -LiteralPath $this.NormalizePath($Path) -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            return $null
        }

        $property = $item.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }

        return $property.Value
    }

    return $service
}
