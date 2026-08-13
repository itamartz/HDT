function New-HDTRegistryService {
    <#
        .SYNOPSIS
            Creates the real IRegistryService adapter over the registry provider.

        .DESCRIPTION
            The one place in HDT that reads the registry. PROJECT constraint 4
            forbids engine logic from touching it directly, so
            Get-HDTMachineFact receives this object and can be swapped for
            New-HDTFakeRegistryService in a test.

            Six methods. TestPath and GetValue are the read subset the fact
            gatherer needs, which today is the SecureBoot state key of DESIGN
            3.2.1. NewKey, SetValue, RemoveValue and RemoveKey are the write half
            the autologon lifecycle of DESIGN 4.5 runs on.

            REMOVING SOMETHING THAT IS NOT THERE IS NOT AN ERROR. DESIGN 4.5.3's
            teardown runs on machines in unknown states - an image that already
            carried a DefaultPassword, a run that died between two writes - and a
            teardown that throws on the first absent value is a teardown that
            does not finish, leaving a machine armed with six of nine artifacts
            cleared.

            SetValue creates the key first because New-ItemProperty fails on a
            key that does not exist. RemoveKey goes through Get-Item so that an
            absent key is a no-op while a key with children and no Recurse still
            throws - the same two behaviours the fake has, expressed as a
            pipeline rather than as a branch.

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

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the six
            IRegistryService ScriptMethods. Note that Get-Member -MemberType
            Method does NOT list a ScriptMethod - use -MemberType Method,
            ScriptMethod.

        .EXAMPLE
            $registry = New-HDTRegistryService
            $registry.GetValue('HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State', 'UEFISecureBootEnabled')

            Returns 1 on a Secure Boot machine and $null on a BIOS machine, which
            is what HDTSecureBootEnabled is derived from.

        .EXAMPLE
            $registry = New-HDTRegistryService
            $registry.SetValue('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'AutoLogonCount', 3, 'DWord')

            Three more autologons, as DESIGN 4.5.1 arms them. SPIKES.md S8
            observed the count reading 2, 1, 0 across those three legs.
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

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'RegistryService'
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

    $service | Add-Member -MemberType ScriptMethod -Name NewKey -Value {
        param([string] $Path)

        $this.Record('NewKey', @($Path))

        # -Force is what makes this idempotent and what creates intermediate
        # keys, so there is no "does it exist" branch to get wrong.
        New-Item -Path $this.NormalizePath($Path) -Force -ErrorAction Stop | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param([string] $Path, [string] $Name, [object] $Value, [string] $Type)

        $this.Record('SetValue', @($Path, $Name, $Value, $Type))

        $full = $this.NormalizePath($Path)
        New-Item -Path $full -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -LiteralPath $full -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveValue -Value {
        param([string] $Path, [string] $Name)

        $this.Record('RemoveValue', @($Path, $Name))

        # Absent is not an error: teardown runs on machines in unknown states.
        Remove-ItemProperty -LiteralPath $this.NormalizePath($Path) -Name $Name -Force -ErrorAction SilentlyContinue
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveKey -Value {
        param([string] $Path, [bool] $Recurse)

        $this.Record('RemoveKey', @($Path, $Recurse))

        # Get-Item yields nothing for an absent key, so the pipeline is a no-op
        # there; a key with children and no Recurse still reaches Remove-Item and
        # still throws. One pipeline, both behaviours, no branch on data.
        Get-Item -LiteralPath $this.NormalizePath($Path) -ErrorAction SilentlyContinue |
            Remove-Item -Recurse:$Recurse -Force -Confirm:$false -ErrorAction Stop
    }

    return $service
}
