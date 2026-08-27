function Get-HDTBootCriticalClass {
    <#
        .SYNOPSIS
            The driver classes a boot image actually needs.

        .DESCRIPTION
            MDT'S "network and mass storage drivers only" TICK BOX, as a list.
            WinPE needs exactly two things from a driver store: something that
            can see the disk, and something that can reach the deployment share.
            Everything else - audio, display, Bluetooth, the vendor's fingerprint
            reader - is weight in an image that boots from a network and lives in
            RAM.

            THE CLASSES, AND WHY EACH IS HERE:

              Net           the network card, or the share is unreachable
              SCSIAdapter   the storage controller, or there is no disk
              HDC           the older name for the same job, and vendor packs
                            still ship both - Intel's RST is HDC, a NVMe
                            controller is usually SCSIAdapter
              System        chipset and bus enumerators; a storage controller
                            behind a bus WinPE cannot enumerate is a storage
                            controller it never sees

            MEASURED, NOT GUESSED. On the Dell WinPE 11 pack on the lab share -
            70 .inf files - these four classes are 58 of them, so the filter
            drops 12: Extension, SoftwareComponent, and a vendor management
            component. That is the size of the saving, and it is real but modest;
            the reason to filter is not the megabytes, it is that a boot image
            carrying a display driver has more that can go wrong on a machine
            whose only job is to run WinPE for six minutes.

            THIS IS THE DEFAULT, NOT A LAW. An administrator with a machine that
            needs something stranger passes their own list, and the filter takes
            it. Nothing here refuses a class.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the class names, as an .inf spells them.

        .EXAMPLE
            Get-HDTBootCriticalClass

            Net, SCSIAdapter, HDC, System.

        .EXAMPLE
            Get-HDTDriver -Root 'C:\HDTLab\Share' |
                Where-Object { (Get-HDTBootCriticalClass) -contains $_.Class }

            What a boot image would keep out of the whole store.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('Net', 'SCSIAdapter', 'HDC', 'System')
}
