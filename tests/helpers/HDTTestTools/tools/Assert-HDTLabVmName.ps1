function Assert-HDTLabVmName {
    <#
        .SYNOPSIS
            Throws unless a name is one the HDT lab helpers may act on.

        .DESCRIPTION
            PROJECT.md's Hyper-V lab safety rules, as code. This host is the
            user's own machine and carries VMs this repository did not create.
            Damaging one is worse than failing a test, so the rules are
            enforced here rather than remembered by whoever is running the
            suite.

            TWO REFUSALS, in this order:

              1. A WILDCARD. 'HDT-*' passed to Remove-HDTLabVirtualMachine would
                 remove every test VM at once, and someone will eventually type
                 it. It is refused before anything else because it is the only
                 refusal that would otherwise pass rule 2.
              2. ANYTHING NOT NAMED HDT-*. PROJECT.md rule 1: only ever act on
                 VMs matching that prefix.

            THERE IS NO LIST OF PROTECTED NAMES, and there deliberately is not
            one. This function used to carry 'CM01' and 'DC01' explicitly, as
            belt and braces over rule 2. Those two machines were retired on
            2026-08-29, and the named check had been protecting nothing for a
            while before anyone noticed - the E2E snapshot built on the same two
            names compared an empty array with an empty array and passed.
            Rule 2 covers every VM on this host and every one it ever gets;
            adding today's names back would only rot the same way.

            EVERY MESSAGE POINTS AT PROJECT.md, because the person who hits one
            of these is about to argue with it.

        .PARAMETER Name
            The VM name to check.

        .OUTPUTS
            None. Throws, or returns nothing.

        .EXAMPLE
            Assert-HDTLabVmName -Name 'HDT-M3-Deploy'

        .EXAMPLE
            Assert-HDTLabVmName -Name 'SomeoneElsesServer'

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

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "A lab VM name is required. HDT test VMs are named HDT-* (PROJECT.md, 'Hyper-V lab safety rules', rule 1)."
    }

    if ($Name -match '[\*\?\[\]]') {
        throw ("'{0}' contains a wildcard. A lab helper never accepts one: 'HDT-*' would act on every test VM at once, and an unfiltered Hyper-V pipeline is exactly what PROJECT.md rule 1 forbids. Name one VM." -f $Name)
    }

    if ($Name -notlike 'HDT-*') {
        throw ("'{0}' is not an HDT test VM, so it is PROTECTED and no HDT test may touch it. Lab helpers only ever act on VMs named HDT-*, which is every VM this repository created and no VM it did not (PROJECT.md, 'Hyper-V lab safety rules', rule 1)." -f $Name)
    }
}
