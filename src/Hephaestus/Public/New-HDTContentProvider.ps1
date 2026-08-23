function New-HDTContentProvider {
    <#
        .SYNOPSIS
            Builds the IContentProvider a provider name asks for.

        .DESCRIPTION
            THE ONE PLACE A PROVIDER NAME BECOMES A PROVIDER. bootstrap.json
            carries a string; a step takes an object; this is the two-branch
            factory in between, and it is nothing else.

            It exists so that Start-HDTDeployment.ps1 does not carry a switch of
            its own. The interface exists so a cloud transport can
            land later - and a later Http provider should be a third branch in
            one file rather than an edit to every caller.

            Http IS NAMED RATHER THAN LUMPED IN WITH A TYPO. Somebody asking for
            it is entitled to "not in v1", not to "unknown
            provider".

            Every argument beyond -Provider and -Root is passed straight through
            to whichever implementation was asked for, including -Journal, so a
            cross-service assertion sees the provider's calls in the same ordered
            list as every other service's.

        .PARAMETER Provider
            Smb or Local. Deliberately NOT a ValidateSet: the refusal has to name
            the value, name the two legal names, and say something specific about
            Http - and a ValidateSet failure says none of that.

        .PARAMETER Root
            The content root. A UNC share for Smb; a resolved local path for
            Local, from Resolve-HDTDeployRoot.

        .PARAMETER Credential
            The deployment account, for Smb. Ignored by Local, which has nothing
            to authenticate to.

        .PARAMETER AllowAnonymous
            Connect with no credential. The refusal to fall back to
            guest starts at "no credential is exactly the fallback", so this is
            explicit or it does not happen.

        .PARAMETER SmbService
            An ISmbService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Journal
            The shared cross-service operation journal.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - an IContentProvider.

        .EXAMPLE
            $credential = Get-Credential -UserName 'svc-hdt-deploy' -Message 'The deployment account'
            New-HDTContentProvider -Provider Local -Root 'D:\Share'

        .EXAMPLE
            New-HDTContentProvider -Provider Smb -Root '\\server\HdtShare' -Credential $credential

            What a PXE-booted machine builds from its bootstrap document.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Provider,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [pscredential] $Credential,

        [Parameter()]
        [switch] $AllowAnonymous,

        [Parameter()]
        [AllowNull()]
        [object] $SmbService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $shared = @{}
    if ($null -ne $FileSystem) { $shared['FileSystem'] = $FileSystem }
    if ($null -ne $Journal) { $shared['Journal'] = $Journal }

    if ($Provider -eq 'Local') {
        return (New-HDTLocalContentProvider -Root $Root @shared)
    }

    if ($Provider -eq 'Smb') {
        $argument = $shared.Clone()
        if ($null -ne $Credential) { $argument['Credential'] = $Credential }
        if ($AllowAnonymous.IsPresent) { $argument['AllowAnonymous'] = $true }
        if ($null -ne $SmbService) { $argument['SmbService'] = $SmbService }

        return (New-HDTSmbContentProvider -Root $Root @argument)
    }

    if ($Provider -eq 'Http') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("provider 'Http' is not implemented in v1. IContentProvider exists so that a cloud transport can land later without a second code path; today the transports HDT builds are Smb and Local.") `
                    -TargetObject $Provider))
    }

    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                -Message ("provider '{0}' is not a transport HDT can build. The providers are Smb and Local." -f $Provider) `
                -TargetObject $Provider))
}
