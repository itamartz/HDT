function Assert-HDTLabVmPath {
    <#
        .SYNOPSIS
            Throws unless a path belongs to the one lab VM being removed.

        .DESCRIPTION
            THE GUARD ON THE DELETE ITSELF, and it exists because of what
            happened during 04-04: the contents of C:\HDTLab\vms were lost -
            HDT-PE-Test, the SPIKES S7/S8 deployed disk that sat loose at the
            root of that folder, and a leftover spike folder.

            The cause was never established. No helper names anything but the
            exact VM it is given, and the developer was working in the same lab
            at the time, so it may not have been HDT's code at all. WHAT IS
            ESTABLISHED IS THAT THE DELETE WAS NOT NARROW ENOUGH TO MAKE THE
            ACCIDENT IMPOSSIBLE, and that is a defect in the one piece of code
            whose entire job is to make it impossible.

            Three refusals, each closing a way the lab could be emptied:

              1. THE VM ROOT ITSELF. Join-Path 'C:\HDTLab\vms' '' yields
                 'C:\HDTLab\vms\', and Remove-Item -Recurse -Force on that
                 empties the lab. An empty name can only arrive through a bug,
                 which is precisely when a guard has to hold.
              2. ANYTHING OUTSIDE THE VM ROOT.
              3. ANYTHING IN THE ROOT THAT IS NOT THIS VM'S OWN FOLDER - another
                 VM's folder, or a file sitting loose beside them.
                 HDT-PE-Test-osdisk.vhdx lived exactly there, and it belonged to
                 no HDT-M3 VM.

            It takes a PATH AND A NAME rather than looking anything up, so it can
            be proven from a unit test with no Hyper-V and nothing on disk.

        .PARAMETER Path
            The file or folder about to be deleted.

        .PARAMETER Name
            The VM the caller is removing.

        .OUTPUTS
            None. Throws, or returns nothing.

        .EXAMPLE
            Assert-HDTLabVmPath -Path 'C:\HDTLab\vms\HDT-M3-Smoke' -Name 'HDT-M3-Smoke'

        .EXAMPLE
            Assert-HDTLabVmPath -Path 'C:\HDTLab\vms' -Name 'HDT-M3-Smoke'

            Throws. That is the whole point of it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $vmRoot = 'C:\HDTLab\vms'

    Assert-HDTLabVmName -Name $Name

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "No path was given to delete. A lab helper deletes one VM's own folder and nothing else (PROJECT.md, 'Hyper-V lab safety rules', rule 5)."
    }

    $trimmed = $Path.TrimEnd('\', '/')
    $rootTrimmed = $vmRoot.TrimEnd('\')

    if ($trimmed -eq $rootTrimmed) {
        throw ("'{0}' is the lab VM root itself. Removing it recursively would empty the whole lab - every test VM, and anything else parked beside them (PROJECT.md, 'Hyper-V lab safety rules', rule 5)." -f $vmRoot)
    }

    if (-not ($trimmed -like ('{0}\*' -f $rootTrimmed))) {
        throw ("'{0}' is not under {1}. A lab helper never deletes anything outside the lab VM root (PROJECT.md, 'Hyper-V lab safety rules', rule 5)." -f $Path, $vmRoot)
    }

    # It must be this VM's own folder, or something inside it.
    $own = '{0}\{1}' -f $rootTrimmed, $Name

    if ($trimmed -ne $own -and -not ($trimmed -like ('{0}\*' -f $own))) {
        throw ("'{0}' does not belong to '{1}'. A lab helper deletes that VM's own folder and the disks attached to it, and nothing else in {2} - a file sitting loose beside the VM folders belongs to nobody the helper knows about (PROJECT.md, 'Hyper-V lab safety rules', rule 1)." -f
            $Path, $Name, $vmRoot)
    }
}
