function Get-HDTLabMemoryBudget {
    <#
        .SYNOPSIS
            The lab memory budget: how much memory the HDT test VMs may hold
            together, and how much any one of them may take.

        .DESCRIPTION
            THIS IS THE ONLY FILE IN THE REPOSITORY THAT MAY CARRY EITHER BYTE
            VALUE, and tests/contract/LabMemoryBudget.Contract.Tests.ps1 fails
            the build if a second file grows a copy.

            That contract exists because the number used to live in SIX places -
            New-HDTLabVirtualMachine, and five tests/e2e/*.E2E.Tests.ps1 files
            that each re-implemented the same running-total check inline. Raising
            it meant finding all six, and nothing would have told anybody about
            the one they missed. CLAUDE.md rule 8: one place of truth, and the
            callers ask.

            WHY 32 GB AND NOT 64. The host has 63.7 GB and it is the user's own
            machine, running their work as well as this lab. Half of it is a
            budget the test VMs may spend without the host starting to page;
            all of it is not a budget at all. It was 12 GB until 2026-09-06,
            which stopped being workable when the lab gained a WSUS server and a
            WDS server that between them held exactly 12 GB - so the harness
            could not create a single test VM.

            WHY 8 GB PER VM. The lab standard is 4 GB and nothing under test has
            needed more; the cap is double that so a deliberate 8 GB run is
            possible and a mistyped 64 GB one is not.

            WHICH VMs THE COMBINED BUDGET COUNTS is Get-HDTLabMemoryUse's
            question, not this one: only the VMs this harness created and
            stamped. This function is pure - no parameters, no Hyper-V, no host
            state - so it can be read on any machine, including one with no
            Hyper-V role at all.

        .OUTPUTS
            A [pscustomobject] with CombinedByte, PerVmByte, CombinedText and
            PerVmText. The two text values exist so a refusal can say "32 GB"
            rather than a bare eleven-digit number, which is what a technician
            reading the failure actually needs.

        .EXAMPLE
            (Get-HDTLabMemoryBudget).CombinedByte

        .EXAMPLE
            $budget = Get-HDTLabMemoryBudget
            throw ("over the {0} lab budget" -f $budget.CombinedText)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        CombinedByte = [long] 34359738368   # 32 GB of memory, across every VM the harness created
        PerVmByte    = [long] 8589934592    # 8 GB, the most memory any one test VM may take
        CombinedText = '32 GB'
        PerVmText    = '8 GB'
    }
}
