function Export-HDTDeviceInventory {
    <#
        .SYNOPSIS
            Writes the machine's PnP devices and their hardware ids to
            Gather\devices.json.

        .DESCRIPTION
            THE FACT GATHER NEVER RECORDED. Get-HDTMachineFact captures twenty
            things about a machine - make, model, serial, UUID, SKU, memory,
            firmware, TPM, chassis, MAC, IP - and NOT ONE hardware id. Make and
            model tell an administrator which driver PACK to fetch. The hardware
            id is the only thing that identifies the specific device that did not
            come up, and without it a deployment that finished with no network
            card can be diagnosed as far as "it is a Latitude 5490" and no
            further.

            SO IT IS A FILE, NOT A HUNDRED VARIABLES. A machine reports dozens of
            devices with several ids each; turning that into engine variables
            would bury the twenty facts a rule actually reads under a hundred
            nothing ever matches on. This sits beside facts.json and
            provenance.json in the run's log directory, where it can be diffed
            against the next machine and read by a person.

            IT IS MDT'S SHAPE. ZTIDrivers.wsf shells Microsoft.BDD.PnpEnum.exe
            and writes PnpEnum.xml into the log directory - a device inventory
            file beside the logs, which is exactly this. HDT differs twice, and
            both are deliberate:

              WRITTEN AT GATHER, NOT INSIDE THE DRIVER STEP. MDT's only exists
              because the driver step needed it, so a run that died before
              drivers left no inventory - which is most of the runs somebody
              wants one for.

              READ THROUGH CIM, NOT A COMPILED ENUMERATOR.
              Microsoft.BDD.PnpEnum.exe is an MDT binary and HDT takes no MDT
              dependency. Win32_PnPEntity answers the same question, and SPIKES
              S19 proved it populated inside HDT's own boot image: 44 devices,
              42 with hardware ids, in 498 ms.

            HARDWARE IDS ARE RELIABLE IN WinPE, AND THAT IS WHY THIS CAN BE
            TRUSTED THERE. They come from BUS ENUMERATION rather than from a
            driver: the PCI bus reports what a device answers on its
            configuration space, so a device with no driver loaded at all still
            publishes PCI\VEN_8086&DEV_15D7&SUBSYS_08161028&REV_21. The id does
            not depend on WinPE having anything that can drive the device.

            WHAT IT DELIBERATELY DOES NOT RECORD IS PROBLEM STATE. WinPE's view
            of "this device has no driver" is a fact about WINPE'S driver set,
            not about the Windows being deployed - a boot image legitimately
            lacks audio, display and fingerprint drivers, so recording problem
            codes would flag a dozen devices on every healthy machine and mean
            nothing. Ids are recorded; the editorial is left out.

            THE DOCUMENT:

              { "schemaVersion": 1,
                "generated": "2026-08-13T00:11:02.4810000Z",
                "deviceCount": 44,
                "device": [ { "name": "...", "class": "Net", "deviceId": "...",
                              "hardwareId": [ ... ], "compatibleId": [ ... ],
                              "manufacturer": "...", "service": "..." } ] }

            THE TIMESTAMP IS FORMATTED BEFORE SERIALISATION, the same rule
            Export-HDTMachineFact carries: ConvertTo-Json renders a raw
            [datetime] as "\/Date(1786579862481)\/" under Windows PowerShell 5.1,
            and 5.1 is the engine that runs in WinPE, where this file is written.

            THE ID LISTS KEEP THEIR ORDER AND STAY SEPARATE. Windows publishes
            HardwareID most specific first with CompatibleID as the generic tail
            behind it, and that order is the only specificity signal there is -
            Get-HDTDriverMatch ranks on exactly it. Sorting, deduping or merging
            the two lists here would throw it away.

        .PARAMETER Device
            Get-HDTPresentDevice's answer, or any collection of rows carrying
            Name, Class, DeviceId, HardwareID, CompatibleID, Manufacturer and
            Service. An empty collection writes an empty inventory rather than
            refusing: a machine that reported nothing is a finding, and a missing
            file cannot be told apart from a step that never ran.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\Gather\devices.json.
            Parent directories are created by the filesystem service.

        .PARAMETER FileSystem
            An IFileSystem - New-HDTFileSystem in production,
            New-HDTFakeFileSystem in a test. Defaults to the real one.

        .PARAMETER Timestamp
            The instant recorded as "generated". Mandatory, and deliberately so:
            the engine has an IClock and must pass its answer, and a test passes
            a fixed one so it can assert an exact document. A default of "now"
            would put a real clock reading inside engine code.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None.

        .EXAMPLE
            $clock = New-HDTClock
            $device = Get-HDTPresentDevice
            Export-HDTDeviceInventory -Device $device -Path 'X:\HDT\Logs\Gather\devices.json' -Timestamp $clock.GetUtcNow()

            Records every hardware id this machine publishes, where a technician
            can read it after the deployment rather than by rebuilding it.

        .EXAMPLE
            $inventory = ConvertFrom-Json -InputObject (Get-Content -Raw 'X:\HDT\Logs\Gather\devices.json')
            $inventory.device | Where-Object { $_.class -eq 'Net' } | Select-Object name, hardwareId

            The network cards a deployed machine had, and the exact ids to search
            a vendor's driver page for.

        .EXAMPLE
            Export-HDTDeviceInventory -Device $device -Path 'X:\HDT\Logs\Gather\devices.json' -Timestamp $clock.GetUtcNow() -WhatIf

            Names the file and writes nothing.

        .LINK
            Get-HDTPresentDevice

        .LINK
            Export-HDTMachineFact
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Device,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # A ROW ASSEMBLED BY HAND NEED NOT CARRY EVERY PROPERTY, and StrictMode
    # makes reading an absent one an error rather than a null. The same reader
    # Get-HDTDriverMatch uses, for the same reason.
    $read = {
        param([object] $Row, [string] $Name)

        if ($null -eq $Row) { return $null }
        if ($null -eq $Row.PSObject.Properties[$Name]) { return $null }

        return $Row.PSObject.Properties[$Name].Value
    }

    $entry = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $Device) {
        if ($null -eq $current) { continue }

        # [string[]] @(...) RATHER THAN THE VALUE AS IT CAME. CIM answers null
        # for a device with no CompatibleID - the captured Bluetooth PAN row is
        # one - and a null here becomes the word null in the file, which a
        # consumer cannot tell apart from "this writer did not know". An empty
        # array says the machine was asked and had none.
        $hardware = [string[]] @()
        $value = & $read $current 'HardwareID'
        if ($null -ne $value) { $hardware = [string[]] @($value) }

        $compatible = [string[]] @()
        $value = & $read $current 'CompatibleID'
        if ($null -ne $value) { $compatible = [string[]] @($value) }

        # THE CLASS CAN BE EMPTY AND THE ROW STILL COUNTS. SPIKES S19 booted
        # HDT's own boot image and found PNPClass populated on 32 of 44 rows -
        # one VMBUS entry carries neither a name nor a class. It still publishes
        # the ids that identify it, which is the reason this file exists, so an
        # unclassified device is written rather than dropped.
        [void] $entry.Add([ordered] @{
                name         = [string] (& $read $current 'Name')
                class        = [string] (& $read $current 'Class')
                deviceId     = [string] (& $read $current 'DeviceId')
                hardwareId   = $hardware
                compatibleId = $compatible
                manufacturer = [string] (& $read $current 'Manufacturer')
                service      = [string] (& $read $current 'Service')
            })
    }

    # A [string], never the [datetime] itself - see the description.
    $generated = $Timestamp.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $document = [ordered] @{
        schemaVersion = 1
        generated     = $generated
        deviceCount   = [int] $entry.Count
        device        = [object[]] @($entry)
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write device inventory')) {
        # DEPTH 6: the document is object -> device array -> device object -> id
        # array, and 5.1's default of 2 would render the id lists as type names.
        $FileSystem.WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 6))
    }
}
