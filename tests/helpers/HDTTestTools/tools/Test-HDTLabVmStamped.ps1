function Test-HDTLabVmStamped {
    <#
        .SYNOPSIS
            Whether a VM's Notes field carries the marker the harness stamps
            into every VM it creates.

        .DESCRIPTION
            The question both the memory budget and the teardown helper ask:
            did this repository create this machine?

            IT IS A SUBSTRING TEST AND NOT AN EQUALITY TEST, deliberately. An
            operator who opens Hyper-V Manager and adds a line to a VM's notes -
            "rebuilt for the WSUS spike", "do not snapshot" - has not disowned
            the machine, and equality would say they had. The consequences of
            that are asymmetric and both bad: the VM silently stops counting
            against the memory budget, and, far worse,
            Remove-HDTLabVirtualMachine stops recognising it and leaves it
            behind for somebody to find. A note that still carries the stamp
            still means the harness made it.

            $null and empty are $false, which is what every VM on this host that
            the harness did not create carries. Case-insensitive, because -like
            is, and nothing here depends on the case.

            Pure. No Hyper-V, no host state.

        .PARAMETER Note
            The VM's Notes field. May be $null or empty - a VM that was never
            given notes is the normal case, not an error.

        .OUTPUTS
            [bool]

        .EXAMPLE
            Test-HDTLabVmStamped -Note ([string] $vm.Notes)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Note
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Note)) {
        return $false
    }

    return ($Note -like ('*{0}*' -f (Get-HDTLabVmStamp)))
}
