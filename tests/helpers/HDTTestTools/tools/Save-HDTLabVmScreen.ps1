function Save-HDTLabVmScreen {
    <#
        .SYNOPSIS
            Saves a screenshot of a lab VM's console as a PNG.

        .DESCRIPTION
            SPIKES S4's other half:
            Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage,
            given the VM's Msvm_VirtualSystemSettingData, returns raw 16-bit
            pixels - two bytes each, RGB565.

            THIS IS DIAGNOSIS, NOT ASSERTION. A screenshot is what a human looks
            at when something went wrong. The E2E asserts that a machine reached
            full Windows from the INTEGRATION SERVICES HEARTBEAT, which WinPE
            never reports and full Windows always does - a deterministic signal,
            where reading pixels is not.

            THE DECODE LIVES IN ConvertFrom-HDTThumbnailImage, which is tested.
            It reads LITTLE-endian, and SPIKES S4 - which said big-endian - had
            the symptom backwards: every capture this lab took came out in false
            colour, a dark WinPE background as saturated magenta. Text stayed
            legible, which is how it survived unnoticed for so long. Proven on
            this host against a frame whose true colours were known.

        .PARAMETER Name
            The VM. Must be HDT-*.

        .PARAMETER Path
            Where to write the PNG.

        .PARAMETER Width
            Thumbnail width. 800x600 is what S4 captured.

        .PARAMETER Height
            Thumbnail height.

        .OUTPUTS
            System.String - the path written, or nothing when the capture failed.

        .EXAMPLE
            Save-HDTLabVmScreen -Name 'HDT-M3-Deploy' -Path 'C:\HDTLab\scratch\e2e\winpe.png'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateRange(64, 1920)]
        [int] $Width = 800,

        [Parameter()]
        [ValidateRange(64, 1200)]
        [int] $Height = 600
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Assert-HDTLabVmName -Name $Name

    $vm = @(Hyper-V\Get-VM -Name $Name)
    if ($vm.Count -ne 1) {
        Write-Warning ("no single VM named '{0}' to photograph." -f $Name)
        return ''
    }

    $guid = [string] $vm[0].Id

    $system = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' |
            Where-Object { $_.Name -eq $guid })

    if ($system.Count -ne 1) {
        Write-Warning ("could not find Msvm_ComputerSystem for '{0}'." -f $Name)
        return ''
    }

    $setting = @(Get-CimAssociatedInstance -InputObject $system[0] `
            -ResultClassName 'Msvm_VirtualSystemSettingData' -ErrorAction SilentlyContinue |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' })

    if ($setting.Count -eq 0) {
        Write-Warning ("could not find Msvm_VirtualSystemSettingData for '{0}'." -f $Name)
        return ''
    }

    $service = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemManagementService'

    $result = Invoke-CimMethod -InputObject $service -MethodName 'GetVirtualSystemThumbnailImage' -Arguments @{
        TargetSystem  = $setting[0]
        WidthPixels   = [uint16] $Width
        HeightPixels  = [uint16] $Height
    }

    if ([int] $result.ReturnValue -ne 0 -or $null -eq $result.ImageData) {
        Write-Warning ("GetVirtualSystemThumbnailImage returned {0} for '{1}'." -f $result.ReturnValue, $Name)
        return ''
    }

    # THE PIXELS ARE ARITHMETIC AND THE ARITHMETIC IS TESTED. See
    # ConvertFrom-HDTThumbnailImage: this function is an adapter over WMI and
    # holds no maths of its own.
    $bitmap = ConvertFrom-HDTThumbnailImage -Data ([byte[]] $result.ImageData) -Width $Width -Height $Height

    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }

    return $Path
}
