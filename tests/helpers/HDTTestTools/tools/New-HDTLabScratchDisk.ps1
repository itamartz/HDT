function New-HDTLabScratchDisk {
    <#
        .SYNOPSIS
            Creates a VHDX under C:\HDTLab, mounts it, and returns the disk
            number it landed on.

        .DESCRIPTION
            The disk tests/integration is allowed to clear, initialise,
            partition and format. It exists so that the destructive half of
            IDiskService can be proven against a REAL disk that belongs to
            nobody.

            THREE REFUSALS BEFORE ANYTHING IS CREATED:

              1. A path outside C:\HDTLab. PROJECT.md names it as the scratch
                 area; anywhere else is somebody's data.
              2. A path that is not a .vhdx. Gen2 and the UEFI layout need VHDX,
                 and a typo'd extension would be created silently.
              3. A size under 1 GB, which is smaller than any layout HDT can
                 apply and is almost always a units mistake.

            AND ONE AFTER: Assert-HDTLabScratchDisk on the row that came back,
            so a mount that misbehaved cannot hand an integration test the
            developer's own disk.

            The VHDX is created with Hyper-V's New-VHD, which is why the
            integration task checks for it by name. It is mounted with
            Mount-DiskImage rather than Mount-VHD so it behaves like any other
            disk image to the Storage module.

        .PARAMETER Path
            Where the VHDX goes. Must be under C:\HDTLab and end in .vhdx.

        .PARAMETER SizeByte
            Its size. 40 GB is enough for uefi-standard plus a Windows 11 apply.

        .PARAMETER Dynamic
            Create it dynamically expanding. Without this it is fixed, which on
            a 40 GB disk takes minutes and gains nothing.

        .OUTPUTS
            A hashtable with DiskNumber and Path.

        .EXAMPLE
            $scratch = New-HDTLabScratchDisk -Path 'C:\HDTLab\scratch\integration\disk.vhdx' -SizeByte 42949672960 -Dynamic
            $scratch.DiskNumber
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [long] $SizeByte,

        [Parameter()]
        [switch] $Dynamic
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $scratchRoot = 'C:\HDTLab'
    $minimumSizeByte = 1073741824

    if (-not ($Path -like ('{0}\*' -f $scratchRoot))) {
        throw ("'{0}' is not under {1}. Integration tests create and destroy their own disks in the scratch area and nowhere else (PROJECT.md, 'Scratch areas')." -f $Path, $scratchRoot)
    }

    if ([System.IO.Path]::GetExtension($Path) -ne '.vhdx') {
        throw ("'{0}' is not a .vhdx. The lab targets Generation 2 and the UEFI disk layout, both of which need VHDX (PROJECT.md, 'Hyper-V lab safety rules', rule 6)." -f $Path)
    }

    if ($SizeByte -lt $minimumSizeByte) {
        throw ("{0} bytes is under the 1 GB minimum for a scratch disk. No HDT disk layout fits in less, so this is almost always a units mistake." -f $SizeByte)
    }

    if (-not $PSCmdlet.ShouldProcess($Path, ('Create and mount a {0} byte scratch VHDX' -f $SizeByte))) {
        return $null
    }

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-HDTLabScratchDisk -Path $Path -Confirm:$false
    }

    if ($Dynamic) {
        Hyper-V\New-VHD -Path $Path -SizeBytes $SizeByte -Dynamic | Out-Null
    } else {
        Hyper-V\New-VHD -Path $Path -SizeBytes $SizeByte -Fixed | Out-Null
    }

    Mount-DiskImage -ImagePath $Path -StorageType VHDX -Access ReadWrite | Out-Null

    $image = Get-DiskImage -ImagePath $Path
    $disk = @(Get-Disk | Where-Object { $_.Number -eq $image.Number })

    $row = $null
    if ($disk.Count -eq 1) {
        $row = $disk[0]
    }

    # The guard, on the row that actually came back.
    Assert-HDTLabScratchDisk -Disk $row

    return @{
        DiskNumber = [int] $row.Number
        Path       = $Path
    }
}
