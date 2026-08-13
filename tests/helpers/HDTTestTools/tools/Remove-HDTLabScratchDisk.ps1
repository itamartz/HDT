function Remove-HDTLabScratchDisk {
    <#
        .SYNOPSIS
            Dismounts and deletes a scratch VHDX.

        .DESCRIPTION
            The other half of New-HDTLabScratchDisk, called from an AfterAll
            that RUNS EVEN WHEN THE TESTS FAILED - which is why it is
            deliberately forgiving: a disk that was never created, never
            mounted, or already dismounted is not an error. A teardown that
            throws on the first absent thing is a teardown that leaves a mounted
            VHDX and 40 GB behind.

            The path guard is the same one New-HDTLabScratchDisk applies, and it
            is NOT forgiving: this function deletes a file.

        .PARAMETER Path
            The VHDX to dismount and delete. Must be under C:\HDTLab.

        .OUTPUTS
            None.

        .EXAMPLE
            Remove-HDTLabScratchDisk -Path 'C:\HDTLab\scratch\integration\disk.vhdx'
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $scratchRoot = 'C:\HDTLab'

    if (-not ($Path -like ('{0}\*' -f $scratchRoot))) {
        throw ("'{0}' is not under {1}. This function deletes a file, so it refuses any path outside the scratch area (PROJECT.md, 'Scratch areas')." -f $Path, $scratchRoot)
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Dismount and delete the scratch VHDX')) {
        return
    }

    # Best effort, in this order: a file that is still mounted cannot be deleted.
    try {
        $image = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
        if ($null -ne $image -and $image.Attached) {
            Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-Warning ("could not dismount '{0}': {1}" -f $Path, $_.Exception.Message)
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}
