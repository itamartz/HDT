function Remove-HDTLabVirtualMachine {
    <#
        .SYNOPSIS
            Stops and removes an HDT test VM, and optionally its files.

        .DESCRIPTION
            The destructive lab helper, and the one PROJECT.md rule 1 was
            written about: "never Get-VM | Remove-VM or any unfiltered
            pipeline."

            Assert-HDTLabVmName runs FIRST and refuses a wildcard and
            anything not named HDT-*. The wildcard refusal is the one that
            matters here: 'HDT-*' is a legal Hyper-V name filter and would
            remove every test VM at once.

            AND IT REFUSES A VM IT DID NOT CREATE. The name rule alone is no
            longer enough: this host runs HDT-* infrastructure this repository
            never built, and the prefix cannot tell the difference. The stamp
            can. New-HDTLabVirtualMachine writes a marker into the Notes field of
            every VM it makes (Get-HDTLabVmStamp), this helper refuses any VM
            that does not carry it, and the refusal happens after the lookup and
            BEFORE Stop-VM - because a server turned off and then refused is a
            server that is off.

            IT IS CALLED FROM AN AfterAll THAT RUNS ON FAILURE TOO, so a VM that
            is not there is not an error - but the name guard still applies,
            because a typo must not silently become a no-op that hides which VM
            was meant.

        .PARAMETER Name
            The VM to remove. Must be a single HDT-* name.

        .PARAMETER KeepFile
            Leave the VHDXs and the VM folder on disk. Removing the VM
            definition without its disks is what you want when the disk is the
            evidence.

        .OUTPUTS
            None.

        .EXAMPLE
            Remove-HDTLabVirtualMachine -Name 'HDT-M3-Deploy'
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [switch] $KeepFile
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $vmRoot = 'C:\HDTLab\vms'

    # Before anything, and belt and braces on top of the HDT-* rule.
    Assert-HDTLabVmName -Name $Name

    # THE LOOKUP AND THE STAMP GUARD COME BEFORE ShouldProcess, DELIBERATELY,
    # and it cost a defect to learn why (2026-09-06). They used to sit after it.
    # ShouldProcess returns $false under -WhatIf, the command returned there,
    # and the guard below was never reached - so
    #
    #   Remove-HDTLabVirtualMachine -Name 'HDT-WSUS-01' -WhatIf
    #
    # answered 'What if: Performing the operation "Stop and remove the HDT lab
    # VM" on target "HDT-WSUS-01"'. The real removal was always refused; only
    # the PREVIEW lied, which is worse than it sounds, because -WhatIf is what
    # a careful operator runs before the real thing and what they will believe.
    #
    # A REFUSAL IS NOT AN EFFECT, so it does not belong behind ShouldProcess.
    # ShouldProcess asks "may I do this?"; this asks "is this mine to do at
    # all?", and the answer to the second is the same in a dry run.
    $vm = @(Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue)

    if ($vm.Count -eq 0) {
        Write-Verbose ("no VM named '{0}' to remove" -f $Name)
    } else {
        # THE SECOND GUARD, AND THE ONE THE NAME RULE CANNOT COVER. HDT-* stopped
        # meaning "ours" the day the lab gained infrastructure servers that match
        # the prefix and that this repository did not build. This helper is
        # called from an AfterAll that runs on FAILURE too, so the accident it
        # has to make impossible is a broken test turning off a server nobody
        # meant to touch.
        #
        # Expressed as "carries no stamp", never as a list of names: a list rots,
        # and it rots dangerously - the machine somebody builds tomorrow is not
        # on it. A VM this harness created was stamped when it was created, and
        # anything else is somebody's, however its name reads.
        if (-not (Test-HDTLabVmStamped -Note ([string] $vm[0].Notes))) {
            throw ("'{0}' carries no HDTTestTools stamp in its Notes, so this repository did not create it and will not remove it - whatever its name says. A VM the harness made is stamped '{1}' the moment it is made; this one is somebody's own machine that happens to match HDT-*. Remove it by hand if that is really what you meant (PROJECT.md, 'Hyper-V lab safety rules', rule 1)." -f
                $Name, (Get-HDTLabVmStamp))
        }
    }

    # AND ONLY NOW MAY IT ASK. Everything above this line decides whether the
    # VM is ours to touch at all; everything below it has an effect - the VM,
    # its disks, and the folder under C:\HDTLab\vms. One gate covers all three,
    # which is why it is here and not inside the branch above: the folder
    # delete at the bottom runs even for a VM that no longer exists, and a
    # -WhatIf that skipped only the Hyper-V half would still delete the disks.
    if (-not $PSCmdlet.ShouldProcess($Name, 'Stop and remove the HDT lab VM')) {
        return
    }

    if ($vm.Count -gt 0) {
        if ($vm[0].State -ne 'Off') {
            Hyper-V\Stop-VM -Name $Name -TurnOff -Force -Confirm:$false
        }

        # The VHDX paths BEFORE the VM is removed, because afterwards there is
        # nothing to ask.
        $attached = @(Hyper-V\Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue |
                ForEach-Object { [string] $_.Path })

        Hyper-V\Remove-VM -Name $Name -Force -Confirm:$false

        if (-not $KeepFile) {
            foreach ($path in $attached) {
                # Assert-HDTLabVmPath, not a -like: a VHDX sitting loose at the
                # root of C:\HDTLab\vms matches 'C:\HDTLab\vms\*' and belongs to
                # nobody this helper knows about. SPIKES S7's disk lived exactly
                # there.
                try {
                    Assert-HDTLabVmPath -Path $path -Name $Name
                } catch {
                    Write-Warning ("refusing to delete '{0}': {1}" -f $path, $_.Exception.Message)
                    continue
                }

                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if (-not $KeepFile) {
        $vmPath = Join-Path -Path $vmRoot -ChildPath $Name

        # THE GUARD ON THE RECURSIVE DELETE. An empty or odd $Name makes
        # Join-Path yield the root, and Remove-Item -Recurse -Force on the root
        # empties the whole lab. During 04-04 the contents of C:\HDTLab\vms were
        # lost and the cause was never established; this makes that class of
        # accident impossible from here whatever else is true.
        Assert-HDTLabVmPath -Path $vmPath -Name $Name

        if (Test-Path -LiteralPath $vmPath -PathType Container) {
            Remove-Item -LiteralPath $vmPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
