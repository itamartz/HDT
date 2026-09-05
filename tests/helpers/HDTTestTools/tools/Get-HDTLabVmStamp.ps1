function Get-HDTLabVmStamp {
    <#
        .SYNOPSIS
            The marker New-HDTLabVirtualMachine writes into the Notes field of
            every VM it creates.

        .DESCRIPTION
            THE STAMP DOES TWO JOBS, and the string is written to do both.

            To a human reading Hyper-V Manager it says the machine is
            disposable: it was created by a test run, nobody is keeping it, and
            deleting it costs nothing. That matters on a host that also carries
            the user's own VMs and the lab's infrastructure.

            To the harness it says "mine". Get-HDTLabMemoryUse counts only
            stamped VMs against the memory budget, and Remove-HDTLabVirtualMachine
            refuses to touch a VM that does not carry it. A GUID would do this
            second job perfectly and the first not at all, which is why the
            marker is a sentence.

            WHY A STAMP RATHER THAN A LIST. CLAUDE.md: "the rule is the HDT-*
            prefix, not a list of names - a name list rots, and this one did."
            The lab now runs HDT-* machines this repository did not build. A list
            of their names would be out of date the first time somebody builds
            another one, and out of date in the dangerous direction: a VM missing
            from the list is a VM the teardown helper would remove. So membership
            is recorded by the harness, at the moment it creates the VM, as a
            fact about what it did - never as something somebody remembered.

            Pure. No Hyper-V, no host state, no parameters.

        .OUTPUTS
            [string] - the exact text written to Notes.

        .EXAMPLE
            Hyper-V\Set-VM -Name 'HDT-M3-Deploy' -Notes (Get-HDTLabVmStamp)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return 'Created by HDT tests/helpers/HDTTestTools. This VM is disposable and counts against the lab memory budget.'
}
