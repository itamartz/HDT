function Get-HDTWizardHarvest {
    <#
        .SYNOPSIS
            Which boxes on the Welcome screen are read back when it closes.

        .DESCRIPTION
            THE WELCOME SCREEN WAS DECORATIVE, AND A REAL BOOT PROVED IT. It
            carries a deploy-root box, a static-address pane and a credential
            pane; Show-HDTWizard returned nothing but an Action, and every
            character a technician typed into any of them was discarded. A
            machine whose share had moved showed the screen, took the corrected
            UNC, threw it away, and died on the old one:

                FATAL: ... "NewMapping" ... The network path was not found.

            This is the list of what to read back, and it is a COMMAND rather
            than a list inside the adapter for the usual reason: which control
            answers which value is a decision, and New-HDTWizardHost is exempt
            from tests only for as long as it makes none.

            NAME AND PROPERTY, NOT NAME ALONE. A TextBox answers Text, a
            PasswordBox answers Password and a RadioButton answers IsChecked -
            and a host that worked that out from the control's type would be
            deciding something. The pair is what wizard.yaml's collect
            declarations already use for the share pages.

            A NAME THE SCREEN DOES NOT HAVE IS NOT AN ERROR. The host skips it,
            because a page is allowed to omit a pane - HDTSkipStaticIp hides the
            address boxes entirely - and a harvest that threw would turn a
            legitimately simpler screen into a crash.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per control, with Name
            and Property.

        .EXAMPLE
            $harvest = Get-HDTWizardHarvest
            @($harvest.Name)

            The controls the Welcome screen answers with, by name. The window is
            markup; this is the list of things worth reading back off it.

        .EXAMPLE
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWizard.xaml' -Collect $harvest

            Handed to the window so the host reads exactly these and nothing else. A
            control renamed in the markup without its name changed here comes back
            empty rather than wrong.

    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pair = @(
        # THE ONE THAT MATTERS MOST: the share this machine could not reach.
        @{ Name = 'HDTDeployRootBox'; Property = 'Text' }

        # The static address pane. HDTUseStaticRadio is what says whether any of
        # the four below were meant at all - a box holding the DHCP lease it was
        # shown is not a request to set that address statically.
        @{ Name = 'HDTUseStaticRadio'; Property = 'IsChecked' }
        @{ Name = 'HDTIpAddressBox'; Property = 'Text' }
        @{ Name = 'HDTSubnetMaskBox'; Property = 'Text' }
        @{ Name = 'HDTGatewayBox'; Property = 'Text' }
        @{ Name = 'HDTDnsBox'; Property = 'Text' }

        # The account that reaches the share. The password is read here and is
        # never logged, never written to RESULT.json and never put on a summary.
        @{ Name = 'HDTUserIdBox'; Property = 'Text' }
        @{ Name = 'HDTUserDomainBox'; Property = 'Text' }
        @{ Name = 'HDTPasswordBox'; Property = 'Password' }
    )

    return [pscustomobject[]] @($pair | ForEach-Object {
            [pscustomobject] @{
                Name     = [string] $_.Name
                Property = [string] $_.Property
            }
        })
}
