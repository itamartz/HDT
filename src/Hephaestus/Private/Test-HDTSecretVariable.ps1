function Test-HDTSecretVariable {
    <#
        .SYNOPSIS
            Whether a deployment variable of this name carries a secret whose
            value must never be written down.

        .DESCRIPTION
            THE ONE PLACE THAT ANSWERS "IS THIS A SECRET". Every writer that
            serialises or displays a variable name beside its value calls this
            and nothing else, because the alternative has already happened here:
            Gather\provenance.json redacted HDTAdminPassword while the log
            stream, the CMTrace file and state.json wrote the same value in
            clear on the same run. One writer asked; three did not.

            WHY THAT IS A PRIVILEGE ESCALATION AND NOT AN INFORMATION LEAK.
            The run's logs and state document are copied to the deployment
            share, which every machine being deployed can read, and the finish
            action moves them to C:\Windows\Logs\HDT on the deployed machine,
            which authenticated users can read. A local administrator password
            written there is readable by any local user of the machine it
            administers.

            TWO RULES, UNIONED, AND BOTH ARE NEEDED.

            THE MAP catches what HDT knows. Get-HDTVariableMap's IsSecret column
            is the declared list - HDTAdminPassword, HDTDomainAdminPassword,
            HDTProductKey, HDTBitLockerPin, HDTUserPassword - and it is the
            authority for every variable HDT ships. A secret added there is
            covered here the same day, with nothing else to update.

            THE PATTERN catches what nobody declared. A customer's rules.yaml
            can set any HDT* name it likes, and a variable HDT has never heard
            of is exactly the one the map cannot cover: HDTJoinPassword,
            HDTApiSecret, HDTVpnCredential. Matching the shape of the name
            catches those on the first run rather than after the first incident.

            NEITHER ALONE IS ENOUGH. The map misses the undeclared name; the
            pattern misses a declared secret whose name says nothing (a licence
            key called HDTProductKey is caught by the pattern only because it
            happens to read like one - HDTAdminPassword's MDT twin AdminPassword
            would not be). Union, not choice.

            IT IS DELIBERATELY WIDE. A false positive costs one diagnostic
            value replaced by "(set, not shown)", with its name, its source and
            its rule still beside it. A false negative costs the local
            administrator password on a share. Those are not comparable, so the
            pattern errs long.

        .PARAMETER Name
            The variable name. Empty is not a secret - it is a caller with
            nothing to classify, and answering true would redact everything.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean.

        .EXAMPLE
            Test-HDTSecretVariable -Name 'HDTAdminPassword'

            True. It is declared secret in Get-HDTVariableMap.

        .EXAMPLE
            Test-HDTSecretVariable -Name 'HDTJoinPassword'

            True, and no map row says so. The name is what catches it.

        .EXAMPLE
            Test-HDTSecretVariable -Name 'HDTComputerName'

            False. Redacting this would answer none of the questions a log exists
            to answer.

        .LINK
            Protect-HDTSecretValue
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    # CACHED, BECAUSE THIS IS ON THE HOT PATH. Write-HDTVariableLog calls it
    # once per resolved variable and a real run resolves well over a hundred;
    # rebuilding the 120-row map each time would put the redaction check on the
    # profile of every deployment. Test-Path rather than a bare read: under
    # Set-StrictMode -Version Latest an unassigned $script: variable throws.
    if (-not (Test-Path -LiteralPath 'variable:script:HDTSecretVariableName')) {
        $known = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($mapped in @(Get-HDTVariableMap)) {
            if ($mapped.IsSecret) { $known[[string] $mapped.HDTName] = $true }
        }

        $script:HDTSecretVariableName = $known
    }

    if ($script:HDTSecretVariableName.ContainsKey($Name)) {
        return $true
    }

    # pin$ AND NOT pin, because HDTPingTimeout and HDTMappingRoot are not
    # secrets and a bare 'pin' would redact both. The suffix is what a variable
    # carrying a PIN actually looks like, and it is the form the map's own
    # coverage test already uses.
    return ($Name -match '(?i)password|passphrase|secret|credential|productkey|apikey|pin$|token$')
}
