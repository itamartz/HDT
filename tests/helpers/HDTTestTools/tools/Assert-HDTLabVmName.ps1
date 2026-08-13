function Assert-HDTLabVmName {
    <#
        .SYNOPSIS
            Throws unless a name is one the HDT lab helpers may act on.

        .DESCRIPTION
            PROJECT.md's Hyper-V lab safety rules, as code. This host runs the
            user's LIVE lab: CM01 is a Configuration Manager server with a PXE
            responder and DC01 is the domain controller. Damaging either is
            worse than failing a test, so the rules are enforced here rather
            than remembered by whoever is running the suite.

            THREE REFUSALS, in this order:

              1. A WILDCARD. 'HDT-*' passed to Remove-HDTLabVirtualMachine would
                 remove every test VM at once, and someone will eventually type
                 it. It is refused before anything else because it is the only
                 refusal that would otherwise pass rule 3.
              2. A PROTECTED NAME. CM01 and DC01 by name, case-insensitively,
                 belt and braces - neither starts with HDT- so rule 3 would
                 catch them anyway, but a rule that only works by accident is
                 not a rule.
              3. ANYTHING NOT NAMED HDT-*. PROJECT.md rule 1: only ever act on
                 VMs matching that prefix.

            EVERY MESSAGE POINTS AT PROJECT.md, because the person who hits one
            of these is about to argue with it.

        .PARAMETER Name
            The VM name to check.

        .OUTPUTS
            None. Throws, or returns nothing.

        .EXAMPLE
            Assert-HDTLabVmName -Name 'HDT-M3-Deploy'

        .EXAMPLE
            Assert-HDTLabVmName -Name 'CM01'

            Throws. That is the whole point of it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $protected = @('CM01', 'DC01')

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "A lab VM name is required. HDT test VMs are named HDT-* (PROJECT.md, 'Hyper-V lab safety rules', rule 1)."
    }

    if ($Name -match '[\*\?\[\]]') {
        throw ("'{0}' contains a wildcard. A lab helper never accepts one: 'HDT-*' would act on every test VM at once, and an unfiltered Hyper-V pipeline is exactly what PROJECT.md rule 1 forbids. Name one VM." -f $Name)
    }

    foreach ($reserved in $protected) {
        if ($Name -eq $reserved) {
            throw ("'{0}' is a PROTECTED virtual machine and no HDT test may touch it. CM01 is the user's Configuration Manager server (it runs a PXE responder) and DC01 is the lab's domain controller (PROJECT.md, 'Hyper-V lab safety rules')." -f $reserved)
        }
    }

    if ($Name -notlike 'HDT-*') {
        throw ("'{0}' is not an HDT test VM. Lab helpers only ever act on VMs named HDT-*, so a mistyped name cannot reach the user's own machines (PROJECT.md, 'Hyper-V lab safety rules', rule 1)." -f $Name)
    }
}
