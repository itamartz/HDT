function Get-HDTPresentDevice {
    <#
        .SYNOPSIS
            The devices this machine reports, with the ids a driver match is
            made of.

        .DESCRIPTION
            WHAT THE PnP FALLBACK ASKS THE MACHINE. Group match needs make and
            model and Get-HDTMachineFact already answers those; this is the
            other half, for the model no rule recognised.

            THE CLASS COMES FROM PNPClass, AND THAT IS NOT A DETAIL.
            Win32_PnPEntity carries BOTH Class and PNPClass, and Class is null
            on every row - checked on real hardware, 32 of 32. A caller that
            grouped by Class would get one enormous null bucket and read it as a
            machine with no device classes at all.

            HardwareID AND CompatibleID STAY SEPARATE, AND STAY IN ORDER.
            Windows publishes HardwareID most specific first and CompatibleID as
            the generic tail behind it, and Get-HDTDriverMatch ranks on exactly
            that: the index of the match, with every CompatibleID behind every
            HardwareID. Sorting these, deduping them, or merging the two lists
            would throw away the only specificity signal there is.

            A DEVICE WITH NO HARDWARE IDS IS DROPPED HERE. A running Windows
            reports a few hundred entries and a tenth of them are software
            enumerations carrying no ids at all - they can never match a driver,
            and dropping them here is one filter rather than one in every
            caller.

            NULL BECOMES AN EMPTY ARRAY. CIM answers null for a device with no
            CompatibleID; engine code runs under StrictMode, where that is an
            error at the point somebody reads .Count rather than at the point it
            was produced.

        .PARAMETER Cim
            The ICimProvider to read through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per device, with Name,
            Class, DeviceId, HardwareID, CompatibleID, Manufacturer and Service.

        .EXAMPLE
            Get-HDTPresentDevice

            Every device on this machine that could match a driver.

        .EXAMPLE
            Get-HDTPresentDevice | Where-Object { $_.Class -in @('Net', 'SCSIAdapter') }

            Network and mass storage - the classes a machine needs before it can
            reach a deployment share or see its own disk.

        .EXAMPLE
            Get-HDTDriverMatch -Device (Get-HDTPresentDevice) -Driver (Get-HDTDriver -Root 'C:\HDTLab\Share')

            What a PnP fallback would inject here.

        .LINK
            Get-HDTDriverMatch

        .LINK
            Get-HDTMachineFact
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNull()]
        [object] $Cim = (New-HDTCimProvider)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $device = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Cim.GetInstance('Win32_PnPEntity'))) {
        if ($null -eq $current) { continue }

        $hardware = @()
        if ($null -ne $current.PSObject.Properties['HardwareID'] -and $null -ne $current.HardwareID) {
            $hardware = @($current.HardwareID)
        }

        # NO IDS, NO MATCH, NO ROW.
        if ($hardware.Count -eq 0) { continue }

        $compatible = @()
        if ($null -ne $current.PSObject.Properties['CompatibleID'] -and $null -ne $current.CompatibleID) {
            $compatible = @($current.CompatibleID)
        }

        $read = {
            param([string] $Name)

            if ($null -eq $current.PSObject.Properties[$Name]) { return '' }

            return [string] $current.PSObject.Properties[$Name].Value
        }

        [void] $device.Add([pscustomobject] @{
                Name         = & $read 'Name'
                Class        = & $read 'PNPClass'
                DeviceId     = & $read 'PNPDeviceID'
                HardwareID   = [string[]] $hardware
                CompatibleID = [string[]] $compatible
                Manufacturer = & $read 'Manufacturer'
                Service      = & $read 'Service'
            })
    }

    return [pscustomobject[]] @($device)
}
