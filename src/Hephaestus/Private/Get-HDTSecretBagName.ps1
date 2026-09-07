function Get-HDTSecretBagName {
    <#
        .SYNOPSIS
            The LSA private data name the reboot-surviving secret bag is stored
            under.

        .DESCRIPTION
            ONE PLACE, BECAUSE FOUR COMMANDS HAVE TO AGREE ABOUT IT.
            Save-HDTSecretBag writes it, Restore-HDTSecretBag reads it,
            Clear-HDTSecretBag removes it and Clear-HDTAutoLogon's checklist
            names it in what it cleared. A literal repeated four times is four
            chances for a machine to be left holding a credential under a name
            nothing looks for.

            IT IS NOT 'DefaultPassword', AND IT MUST NOT BE. That name belongs to
            Windows: Winlogon reads the autologon password from it (DESIGN 4.5.2,
            SPIKES S7 and S8), and writing a JSON document there would replace
            the password the machine logs itself on with, stranding the
            deployment at a logon screen. The two secrets have different owners,
            different lifetimes and different readers, so they get different
            names.

            NO L$ OR M$ PREFIX, matching New-HDTLsaService's own note: HDT
            writes plain private-data names.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String.

        .EXAMPLE
            Get-HDTSecretBagName

            HDTSecretBag.

        .LINK
            Save-HDTSecretBag
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return 'HDTSecretBag'
}
