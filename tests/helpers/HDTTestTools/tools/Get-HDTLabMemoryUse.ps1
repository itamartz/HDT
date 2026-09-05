function Get-HDTLabMemoryUse {
    <#
        .SYNOPSIS
            How much host memory the running VMs this harness created are
            holding, and which VMs were counted and which were ignored.

        .DESCRIPTION
            THE BUDGET COUNTS WHAT THIS HARNESS CREATED, AND NOTHING ELSE - and
            it knows which those are without a list of names anywhere.

            A VM counts when both are true: it is Running, and its Notes field
            carries the marker New-HDTLabVirtualMachine stamped into it at
            creation (Get-HDTLabVmStamp, Test-HDTLabVmStamped). Everything else
            is ignored and reported as ignored.

            WHY IT IS DONE THIS WAY. This host carries HDT-* machines this
            repository did not build - a WSUS server and a WDS server, at the
            time of writing - and until 2026-09-06 the budget counted them. They
            held 12 GB between them, which was the entire budget, so the harness
            refused to create any test VM at all and nothing in phase 08 could
            run.

            The obvious fix is a list of names to skip. It is the wrong fix, and
            CLAUDE.md says why: "the rule is the HDT-* prefix, not a list of
            names - a name list rots, and this one did." It rots in the dangerous
            direction, too. The next infrastructure VM somebody builds is not on
            the list, so it silently eats the budget and - through the same
            stamp check in Remove-HDTLabVirtualMachine - becomes something a
            failing test's AfterAll would delete. A skip-list is a promise that
            somebody will remember; a stamp is a record of what happened.

            So membership is a fact about the VM, written by the code that
            created it, and the machines this repository did not build fall out
            by construction rather than by being named here. Nothing in this
            function knows or may know what any of them is called - a unit test
            parses this file and fails if a VM name appears in its code.

            REPORTING THE IGNORED SET IS NOT DECORATION. A technician who reads
            "0 bytes already assigned" while Hyper-V Manager plainly shows two
            running VMs will conclude the check is broken. The count of ignored
            machines, in the message, is what turns that into "counted none of
            them, on purpose, and here is how many".

            MemoryAssigned is the correct property, not MemoryStartup:
            SPIKES S23 records that it is what the host has actually handed the
            VM, which is the number the host's own free memory responds to.

        .PARAMETER VirtualMachine
            VM rows to examine instead of asking Hyper-V. When supplied, this
            function makes NO Hyper-V call at all - which is what lets the unit
            suite assert every rule above on a machine with no Hyper-V role and
            without creating, starting or reading a single VM. A row needs
            Name, State, MemoryAssigned and Notes: the four properties
            Hyper-V\Get-VM returns and the only four the live path reads.

        .OUTPUTS
            A [pscustomobject] with AssignedByte [long], Counted [string[]] and
            Ignored [string[]].

        .EXAMPLE
            (Get-HDTLabMemoryUse).AssignedByte
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $VirtualMachine
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($PSBoundParameters.ContainsKey('VirtualMachine')) {
        $row = @($VirtualMachine)
    } else {
        # NAME-FILTERED, NEVER AN UNFILTERED PIPELINE (PROJECT.md rule 1), and
        # module-qualified because PowerCLI shadows Get-VM on this host
        # (SPIKES S8).
        $row = @(Hyper-V\Get-VM -Name 'HDT-*' -ErrorAction SilentlyContinue)
    }

    $assigned = [long] 0
    $counted = @()
    $ignored = @()

    foreach ($vm in $row) {
        if ($null -eq $vm) { continue }

        $name = [string] $vm.Name
        $note = ''
        if ($null -ne $vm.Notes) { $note = [string] $vm.Notes }

        if (([string] $vm.State) -eq 'Running' -and (Test-HDTLabVmStamped -Note $note)) {
            $assigned += [long] $vm.MemoryAssigned
            $counted += $name
        } else {
            $ignored += $name
        }
    }

    return [pscustomobject] @{
        AssignedByte = [long] $assigned
        Counted      = [string[]] $counted
        Ignored      = [string[]] $ignored
    }
}
