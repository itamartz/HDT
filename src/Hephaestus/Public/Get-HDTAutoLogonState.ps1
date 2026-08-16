function Get-HDTAutoLogonState {
    <#
        .SYNOPSIS
            Reports the machine's current autologon state.

        .DESCRIPTION
            Reads the Winlogon values, the RunOnce entry and whether the LSA
            secret exists, and returns them as one object:

                Armed                AutoAdminLogon is '1'
                UserName             DefaultUserName
                DomainName           DefaultDomainName
                Count                AutoLogonCount
                HasRegistryPassword  DefaultPassword exists in the registry
                HasLsaSecret         the DefaultPassword LSA secret exists
                RunOnceCommand       the HDTResume RunOnce value

            IT REPORTS THE SECRETS AS BOOLEANS AND NEVER RETURNS THEIR VALUES.
            Nothing in the engine needs the autologon password back - Winlogon is
            its only consumer and it does not go through here - so returning it
            would only create another place for it to leak.

            HasRegistryPassword is worth having even though HDT says
            there should never be one: a machine built from an image, or by
            another tool, may carry it, and Clear-HDTAutoLogon has to clear both.

            Armed is false for AutoAdminLogon='0', which is precisely what
            Windows leaves behind when AutoLogonCount runs out, so
            that state reads as disarmed rather than as armed-with-a-zero.

        .PARAMETER Registry
            An IRegistryService.

        .PARAMETER Lsa
            An ILsaService.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            (Get-HDTAutoLogonState -Registry $registry -Lsa $lsa).Armed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Registry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

    $autoAdminLogon = $Registry.GetValue($winlogonPath, 'AutoAdminLogon')
    $registryPassword = $Registry.GetValue($winlogonPath, 'DefaultPassword')
    $secret = $Lsa.GetSecret('DefaultPassword')

    return [pscustomobject] ([ordered] @{
            Armed               = ([string] $autoAdminLogon -eq '1')
            UserName            = $Registry.GetValue($winlogonPath, 'DefaultUserName')
            DomainName          = $Registry.GetValue($winlogonPath, 'DefaultDomainName')
            Count               = $Registry.GetValue($winlogonPath, 'AutoLogonCount')
            HasRegistryPassword = ($null -ne $registryPassword)
            HasLsaSecret        = (-not [string]::IsNullOrEmpty($secret))
            RunOnceCommand      = $Registry.GetValue($runOncePath, 'HDTResume')
        })
}
