function Get-HDTLabOfflineComputerName {
    <#
        .SYNOPSIS
            Reads the computer name out of a deployed VHDX without booting it.

        .DESCRIPTION
            HOW THE UNATTEND IS PROVEN TO HAVE APPLIED. ComputerName is written
            by Setup in the specialize pass, into

              SYSTEM\ControlSet001\Control\ComputerName\ComputerName

            of the deployed machine's own registry. Reading it offline means the
            assertion does not depend on getting a shell inside a VM.

            The method is SPIKES S8's exactly: mount the VHDX READ-ONLY,
            reg load the hive under a scratch key, read, and UNLOAD IN A
            finally. S8 also proved why the finally matters - a hive left loaded
            holds the file open and the VHDX cannot be dismounted, which
            eventually leaves a mounted disk on the host.

            [gc]::Collect() before the unload is not superstition: reg unload
            fails while any handle into the hive is still open, and PowerShell's
            registry provider keeps one until the objects are collected.

        .PARAMETER VhdPath
            The deployed VHDX.

        .PARAMETER HiveKey
            The scratch key name to load under HKLM. Defaults to HDTOFFLINE.

        .OUTPUTS
            System.String - the computer name, or an empty string when the hive
            could not be read.

        .EXAMPLE
            Get-HDTLabOfflineComputerName -VhdPath 'C:\HDTLab\vms\HDT-M3-Deploy\os.vhdx'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $VhdPath,

        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9]+$')]
        [string] $HiveKey = 'HDTOFFLINE'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
        throw ("'{0}' does not exist." -f $VhdPath)
    }

    $name = ''
    $mounted = $false

    try {
        # READ ONLY. This is evidence, and evidence is not written to.
        Mount-DiskImage -ImagePath $VhdPath -StorageType VHDX -Access ReadOnly | Out-Null
        $mounted = $true

        $number = [int] (Get-DiskImage -ImagePath $VhdPath).Number

        $windowsVolume = @(Get-Partition -DiskNumber $number -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                Where-Object { Test-Path -LiteralPath ('{0}:\Windows\System32\config\SYSTEM' -f $_.DriveLetter) })

        if ($windowsVolume.Count -eq 0) {
            Write-Warning ("no volume on '{0}' carries a Windows\System32\config\SYSTEM hive." -f $VhdPath)
            return ''
        }

        $hivePath = '{0}:\Windows\System32\config\SYSTEM' -f $windowsVolume[0].DriveLetter
        $loaded = $false

        try {
            & reg.exe load ("HKLM\{0}" -f $HiveKey) $hivePath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning ("reg load of '{0}' exited {1}." -f $hivePath, $LASTEXITCODE)
                return ''
            }
            $loaded = $true

            $key = 'HKLM:\{0}\ControlSet001\Control\ComputerName\ComputerName' -f $HiveKey
            if (Test-Path -LiteralPath $key) {
                $name = [string] (Get-ItemProperty -LiteralPath $key -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
            }
        } finally {
            if ($loaded) {
                # SPIKES S8: the provider holds a handle into the hive until the
                # objects are collected, and reg unload fails while it does.
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()

                & reg.exe unload ("HKLM\{0}" -f $HiveKey) | Out-Null
            }
        }
    } finally {
        if ($mounted) {
            Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    return $name
}
