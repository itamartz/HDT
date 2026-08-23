function New-HDTFeatureService {
    <#
        .SYNOPSIS
            The real IFeatureService: a thin adapter over Get-WindowsFeature and
            Install-WindowsFeature.

        .DESCRIPTION
            DESIGN 10.2's Install-WindowsFeature wrapper. Rule 5 forbids engine
            logic from calling it directly, so the InstallRoles step receives this
            object and can be handed New-HDTFakeFeatureService in a test.

            IT IS BRANCH-FREE, WHICH IS WHY IT IS NOT UNIT TESTED (rule 1's
            adapter exception). Every decision - is this feature name real, is it
            already installed, which of these still have to be installed, does the
            result mean restart - is made by the step against the flat listing
            this returns. The adapter's whole job is to call the cmdlet and
            project its output.

            THE TWO CMDLETS LIVE IN THE ServerManager MODULE, which exists only on
            a Windows Server SKU. Nothing here imports it: it auto-loads on a
            server, and on a client the call fails with a CommandNotFoundException
            naming Get-WindowsFeature - which is a better message than an import
            error naming a module an administrator has never heard of. The
            contract test skips this row on a client for the same reason.

            InstallState IS PASSED THROUGH AS THE STRING Get-WindowsFeature
            reports: Installed, Available or Removed. Removed - the payload is
            gone from the image - is the state that makes source: necessary, and
            an adapter that collapsed it into Available would make the .NET 3.5
            case undiagnosable.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every call
            is appended to it as well as to $Operations.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying GetFeature and
            InstallFeature, plus Operations, GetOperationName and ServiceName.

        .EXAMPLE
            $feature = New-HDTFeatureService
            $feature.GetFeature('Web-Server')

            Whether a Windows Server role is installed. On a client SKU this reports
            nothing rather than throwing - ServerManager is not there to ask, and
            an InstallRoles step on a client is a failed step, not a crash.

        .EXAMPLE
            @($feature.GetOperationName())

            What was asked of it, which is what Invoke-HDTInstallRolesStep's tests
            assert on rather than installing a role.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds the service object; installing is done by the caller through it, and the step that calls it declares SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'FeatureService'
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
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetFeature -Value {
        $this.Record('GetFeature', @())

        $row = @(Get-WindowsFeature | ForEach-Object {
                [pscustomobject] @{
                    Name         = [string] $_.Name
                    DisplayName  = [string] $_.DisplayName
                    InstallState = [string] $_.InstallState
                }
            })

        # The unary comma is mandatory: a ScriptMethod collapses a single-element
        # array to a scalar without it.
        return , ([object[]] $row)
    }

    $service | Add-Member -MemberType ScriptMethod -Name InstallFeature -Value {
        param([string[]] $Name, [bool] $IncludeManagementTools, [string] $Source)

        $this.Record('InstallFeature', @($Name, $IncludeManagementTools, $Source))

        $argument = @{ Name = [string[]] $Name }
        if ($IncludeManagementTools) { $argument['IncludeManagementTools'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($Source)) { $argument['Source'] = $Source }

        $result = Install-WindowsFeature @argument

        return [pscustomobject] @{
            Success       = [bool] $result.Success
            RestartNeeded = ([string] $result.RestartNeeded -ne 'No')
            ExitCode      = [int] $result.ExitCode
            Message       = [string] $result.ExitCode
            FeatureResult = [string[]] @($result.FeatureResult | ForEach-Object { [string] $_.Name })
        }
    }

    return $service
}
