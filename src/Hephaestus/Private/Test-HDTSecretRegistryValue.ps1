function Test-HDTSecretRegistryValue {
    <#
        .SYNOPSIS
            Whether a registry value of this name carries a secret whose value
            must never be written down.

        .DESCRIPTION
            THE ONE PLACE THAT ANSWERS IT FOR THE REGISTRY ADAPTER, the way
            Test-HDTSecretVariable answers it for the variable bag.

            WHY IT EXISTS AT ALL. New-HDTRegistryService used to log the name,
            the type and the LENGTH of every value it wrote and never the value,
            because any caller may put a secret through SetValue and DESIGN
            4.5.2's guarantee must not depend on every future caller
            remembering. The reasoning was right and the trade was wrong: it
            made every registry write in the engine unreadable in order to
            protect one value, and "Make = Dell Inc." has no secret in it. The
            silence is replaced by this - an enforced guarantee that names the
            few values which must not travel and lets the rest be read.

            TWO RULES, UNIONED, for the reason Test-HDTSecretVariable gives.

            THE DENY-LIST catches the names this engine and Windows itself use.
            DefaultPassword is Winlogon's, and it is the one whose disclosure is
            a privilege ESCALATION rather than a leak: the logs a run produces
            are copied to the deployment share and then to C:\Windows\Logs\HDT
            on the deployed machine, which authenticated users can read, so a
            local administrator password written there is readable by any local
            user of the machine it administers. DESIGN 4.5.2 stores it as an LSA
            secret and Set-HDTAutoLogon removes the registry value
            unconditionally - and this list does not depend on either of those
            staying true, because a guarantee that holds only while the code
            around it is correct is not a guarantee.

            THE PATTERN catches what nobody declared, and it is
            Test-HDTSecretVariable's own: a site may tattoo anything under any
            value name through a Tattoo step's values: block, and
            HDTJoinPassword or VpnCredential arriving there should be caught on
            the first run rather than after the first incident.

            IT IS DELIBERATELY WIDE, for the same asymmetry: a false positive
            costs one diagnostic value replaced by a visible redaction that
            still names it, its type and its length. A false negative costs a
            password on a share.

            AND THE CALLER MAY OVERRIDE IT UPWARDS, never downwards.
            SetValue's Sensitive switch marks a value regardless of name; there
            is no switch that un-marks one this returns true for.

        .PARAMETER Name
            The registry value name. Empty is not a secret - it is a caller with
            nothing to classify, and answering true would redact everything.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean.

        .EXAMPLE
            Test-HDTSecretRegistryValue -Name 'DefaultPassword'

            True. Winlogon's autologon password, named on the deny-list rather
            than left to the pattern.

        .EXAMPLE
            Test-HDTSecretRegistryValue -Name 'Make'

            False. A tattoo that could not say the machine is a Dell answers
            none of the questions a log exists to answer.

        .LINK
            Format-HDTRegistryLogValue

        .LINK
            Test-HDTSecretVariable
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

    # THE NAMES WRITTEN DOWN, not derived. Winlogon's cleartext password value
    # and the encrypted variant older tooling wrote beside it; both are read by
    # LSA-aware and registry-only autologon implementations alike, and either
    # one on a share is the escalation described above.
    $deny = @('DefaultPassword', 'DefaultPasswordEncrypted')

    if ($deny -contains $Name) {
        return $true
    }

    return (Test-HDTSecretVariable -Name $Name)
}
