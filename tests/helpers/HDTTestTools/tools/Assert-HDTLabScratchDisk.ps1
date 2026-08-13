function Assert-HDTLabScratchDisk {
    <#
        .SYNOPSIS
            Throws unless a disk row is one an integration test may destroy.

        .DESCRIPTION
            The last guard between tests/integration and the developer's own
            disk. New-HDTLabScratchDisk mounts a VHDX and then asks Get-Disk
            which number it landed on; if that lookup ever returned the wrong
            row - a mount that silently failed, a disk that went offline and
            back, a race with another mount - the integration suite would go on
            to call ClearDisk on it.

            SO THE DISK IS CHECKED, NOT THE MOUNT. IsBoot or IsSystem means this
            is the machine, and the answer is no, whatever the caller believes
            it mounted.

            It takes a ROW rather than a disk number precisely so it can be
            proven from a unit test with nothing mounted: the tests inject
            tests/fixtures/disk/host-nvme-disk.json, which is this host's own
            disk with IsBoot and IsSystem both true.

        .PARAMETER Disk
            An IDiskService GetDisk() row, or anything with Number, IsBoot and
            IsSystem.

        .OUTPUTS
            None. Throws, or returns nothing.

        .EXAMPLE
            Assert-HDTLabScratchDisk -Disk $row
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Disk
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A mount that misbehaved yields no row at all, and "no row" must never read
    # as "not the system disk".
    if ($null -eq $Disk) {
        throw 'No disk row was found for the scratch VHDX. An integration test refuses to guess which disk it mounted rather than write to whichever one is in front of it.'
    }

    $property = @($Disk.PSObject.Properties.Name)

    $read = {
        param([string] $Name, [object] $Default)

        if ($property -contains $Name) {
            return $Disk.$Name
        }

        return $Default
    }

    $number = & $read 'Number' '?'
    $friendlyName = [string] (& $read 'FriendlyName' 'unknown')

    if ([bool] (& $read 'IsBoot' $false)) {
        throw ("Disk {0} ({1}) is the disk this machine booted from. An integration test never writes to it (PROJECT.md, 'Scratch areas')." -f $number, $friendlyName)
    }

    if ([bool] (& $read 'IsSystem' $false)) {
        throw ("Disk {0} ({1}) carries this machine's system partition. An integration test never writes to it (PROJECT.md, 'Scratch areas')." -f $number, $friendlyName)
    }
}
