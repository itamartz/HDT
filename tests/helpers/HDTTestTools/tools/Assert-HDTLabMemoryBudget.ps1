function Assert-HDTLabMemoryBudget {
    <#
        .SYNOPSIS
            Refuses to start a test VM that would break the lab memory budget.

        .DESCRIPTION
            PROJECT.md's Hyper-V lab safety rules, rule 4, in one place that
            every caller asks. Two refusals:

              * more memory than one test VM may take, and
              * more memory than the VMs this harness created may hold together.

            THE NUMBERS COME FROM Get-HDTLabMemoryBudget AND ARE NEVER WRITTEN
            HERE. Until 2026-09-06 the budget existed as a literal in six files -
            this helper's ancestor and five e2e suites that each re-implemented
            the running total inline - and raising it meant finding all six.
            CLAUDE.md rule 8: one place of truth, and a contract test that fails
            the build when a second copy appears.

            WHICH VMs COUNT is Get-HDTLabMemoryUse's rule: running, and stamped
            by this harness at creation. The lab's own infrastructure matches
            HDT-* and carries no stamp, so it does not eat the budget for the
            machines under test - and no name of any machine appears in this
            rule, because a name list rots.

            THE REFUSAL NAMES THE IGNORED VMs' COUNT ON PURPOSE. Somebody
            reading "0 bytes already assigned" with two VMs plainly running in
            Hyper-V Manager would otherwise conclude the check is broken and go
            looking for a bug that is not there.

        .PARAMETER MemoryByte
            The startup memory the VM about to be created will take.

        .PARAMETER Name
            The VM about to be created, quoted back in the refusal so the person
            reading the failure knows which one it stopped.

        .PARAMETER VirtualMachine
            Passed straight through to Get-HDTLabMemoryUse. It exists so the
            unit suite can assert both refusals against hand-made VM rows on a
            machine with no Hyper-V role, and it is not used by the live path.

        .OUTPUTS
            None. It returns nothing and throws on refusal.

        .EXAMPLE
            Assert-HDTLabMemoryBudget -MemoryByte 4294967296 -Name 'HDT-M3-Deploy'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [long] $MemoryByte,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $VirtualMachine
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $budget = Get-HDTLabMemoryBudget

    if ($MemoryByte -gt $budget.PerVmByte) {
        throw ("{0} bytes is more than one HDT test VM may take. '{1}' is capped at {2} - 4 GB is the lab standard - because the whole budget is {3} across the VMs this harness created and the host's free memory moves with whatever else the user is running (PROJECT.md, 'Hyper-V lab safety rules', rule 4). The numbers live in tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryBudget.ps1." -f
            $MemoryByte, $Name, $budget.PerVmText, $budget.CombinedText)
    }

    if ($PSBoundParameters.ContainsKey('VirtualMachine')) {
        $use = Get-HDTLabMemoryUse -VirtualMachine $VirtualMachine
    } else {
        $use = Get-HDTLabMemoryUse
    }

    if (($use.AssignedByte + $MemoryByte) -gt $budget.CombinedByte) {
        $countedText = '(none)'
        if (@($use.Counted).Count -gt 0) {
            $countedText = (@($use.Counted) -join ', ')
        }

        throw ("Starting '{0}' with {1} bytes would put this harness's VMs over the {2} lab budget: {3} bytes are already assigned to {4} running VM(s) it created - {5}. Shut one down first (PROJECT.md, 'Hyper-V lab safety rules', rule 4). {6} other running HDT-* VM(s) were ignored because they carry no HDTTestTools stamp: this repository did not create them, so they are neither counted here nor removable through Remove-HDTLabVirtualMachine." -f
            $Name, $MemoryByte, $budget.CombinedText, $use.AssignedByte, @($use.Counted).Count, $countedText, @($use.Ignored).Count)
    }
}
