function Compare-HDTDriverInventory {
    <#
        .SYNOPSIS
            What the staged drivers and this machine's devices have to say about
            each other.

        .DESCRIPTION
            THE STEP STAGES A FOLDER AND SAYS NOTHING ABOUT WHETHER IT WAS THE
            RIGHT FOLDER. A rule builds a path out of make and model, the folder
            is copied whole, and until this nothing ever compared what is in it
            with what the machine actually has. A pack for the wrong model stages
            just as successfully as the right one.

            THE FRAMING MATTERS MORE THAN THE MATCHING, and getting it wrong is
            worse than saying nothing. "118 devices, 112 not covered" is a true
            sentence and a useless one: most devices are served by Windows in-box
            drivers, so that number is both normal and alarming, and an
            administrator who reads it twice learns to ignore the line. Two
            questions earn their place:

              IS THIS THE RIGHT PACK AT ALL? How many staged .inf files claim an
              id this machine reports. A pack for a different model matches
              almost nothing, and that shows up immediately.

              IS ANYTHING THAT MATTERS UNSERVED? A device in the classes that
              strand a machine, with no staged .inf claiming it. Everything else
              is noise.

            WHAT THIS IS NOT, AND THE CALLER MUST SAY SO IN THE LOG. It does not
            implement INF ranking - Windows picks between two drivers that both
            claim an id by rank, signature, date and version, and none of that is
            considered here. It does not read a catalog or check a signature. It
            knows nothing about the in-box drivers in the image being applied,
            which are what actually serve most of these devices. A device
            reported here as unmatched is a device THE STAGED PACK does not
            claim, which is not the same as a device that will not work - and a
            confident false negative sends an administrator hunting a driver they
            do not need.

            THE CRITICAL CLASSES ARE THE BOOT-CRITICAL SET PLUS DISPLAY.
            Get-HDTBootCriticalClass is about a BOOT IMAGE - Net, SCSIAdapter,
            HDC and System, because WinPE needs a disk and a network and nothing
            else, and a display driver is weight in an image that lives in RAM
            for six minutes. A DEPLOYED machine is judged differently: one that
            comes up at 800x600 on a basic display adapter is one somebody has to
            attend to. So Display is added HERE rather than there, where adding
            it would bloat every boot image.

            A DEVICE WHOSE CLASS THE MACHINE DID NOT REPORT IS NOT CALLED
            CRITICAL. SPIKES S19 booted HDT's own boot image and found PNPClass
            populated on 32 of 44 rows - one VMBUS entry carries neither a name
            nor a class. Guessing that an unclassified device is critical would
            put a false alarm in front of a technician, which is the failure this
            whole report exists to avoid.

            THE RANKING IS Get-HDTDriverMatch'S, NOT A SECOND COPY OF IT. Which
            id matched, at what rank, off HardwareID or CompatibleID - that logic
            already exists and is already tested, and a second implementation
            here would be a second answer to the same question. This adds only
            the direction that command does not answer: from the DEVICE back to
            the store, so a device with nothing staged for it can be named.

        .PARAMETER Device
            Get-HDTPresentDevice's answer - the machine's devices with their
            HardwareID and CompatibleID lists.

        .PARAMETER Driver
            Parsed .inf rows carrying InfName, Class and HardwareId - what
            Get-HDTDriver answers WITHOUT -NoHardwareId. A header-only row claims
            no ids and is simply never relevant.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with DeviceCount,
            DriverCount, RelevantCount, RelevantDriver, CriticalClass,
            CriticalDeviceCount and UnmatchedCriticalDevice.

        .EXAMPLE
            $device = Get-HDTPresentDevice
            $driver = Get-HDTDriver -Root 'W:\' -Path 'Win11\Dell Inc.\Latitude 5490'
            Compare-HDTDriverInventory -Device $device -Driver $driver

        .EXAMPLE
            $report = Compare-HDTDriverInventory -Device $device -Driver $driver
            $report.UnmatchedCriticalDevice | Select-Object Name, Class, HardwareId

            The devices in the classes that strand a machine which the staged
            pack does not claim - and the exact ids to search a vendor's page
            for.

        .LINK
            Get-HDTDriverMatch

        .LINK
            Get-HDTPresentDevice
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Device,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [object[]] $Driver
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A row assembled by hand need not carry every property, and StrictMode makes
    # reading an absent one an error rather than a null.
    $read = {
        param([object] $Row, [string] $Name)

        if ($null -eq $Row) { return $null }
        if ($null -eq $Row.PSObject.Properties[$Name]) { return $null }

        return $Row.PSObject.Properties[$Name].Value
    }

    # -- which drivers are relevant ---------------------------------------
    #
    # Get-HDTDriverMatch answers exactly this and already knows how to rank:
    # every CompatibleID behind every HardwareID, best rank wins, and it records
    # which kind matched and which device earned it.

    $match = @(Get-HDTDriverMatch -Device $Device -Driver $Driver)

    $relevant = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in $match) {
        [void] $relevant.Add([pscustomobject] @{
                InfName    = [string] (& $read $one.Driver 'InfName')
                Class      = [string] (& $read $one.Driver 'Class')
                MatchedId  = [string] $one.MatchedId
                Source     = [string] $one.Source
                Rank       = [int] $one.Rank
                DeviceName = [string] $one.DeviceName
            })
    }

    # -- which devices nothing staged claims ------------------------------
    #
    # THE OTHER DIRECTION, which Get-HDTDriverMatch does not answer: it returns
    # the drivers that matched, so a device nothing matched is simply absent from
    # its result and cannot be named from it.

    $claimed = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($current in $Driver) {
        if ($null -eq $current) { continue }

        foreach ($id in @(& $read $current 'HardwareId')) {
            if ($null -eq $id) { continue }

            $key = ([string] $id).Trim()
            if ([string]::IsNullOrEmpty($key)) { continue }

            [void] $claimed.Add($key)
        }
    }

    # THE CLASSES WHOSE ABSENCE ACTUALLY STRANDS A MACHINE, which is NOT the
    # boot-critical set and the difference was measured rather than reasoned.
    #
    # Get-HDTBootCriticalClass is Net, SCSIAdapter, HDC and System, and it is
    # about a BOOT IMAGE - WinPE needs a disk and a network, and System is in
    # there for the bus enumerators a storage controller might sit behind. Run
    # that same list against a DEPLOYED Windows and System is 88 of 118 devices
    # on the lab host: ACPI nodes, host bridges, PCI-to-PCI bridges, thermal
    # zones. Windows serves essentially all of them in-box, so warning about
    # them produces a line that is both enormous and meaningless - and an
    # administrator who reads "116 devices uncovered" twice learns to ignore the
    # line, which costs the two entries that mattered.
    #
    # Display replaces it. A machine that comes up at 800x600 on a basic display
    # adapter is one somebody has to attend to; a machine missing a thermal zone
    # driver is not.
    $criticalClass = [string[]] @('Net', 'SCSIAdapter', 'HDC', 'Display')

    # AND THE CLASS BUCKET IS ONLY HALF THE FILTER. Of 25 Net devices on the lab
    # host, TWO are network cards: the rest are WAN miniports on ROOT, software
    # devices on SWD, Bluetooth PAN on BTH and a Wi-Fi Direct virtual adapter.
    # Every one of them is a Windows software construct that no vendor driver
    # pack has ever shipped a driver for, so reporting them as "uncovered" is
    # reporting that a driver pack is not something it was never trying to be.
    #
    # A DRIVER PACK SHIPS DRIVERS FOR THINGS ON A BUS. PCI covers the NIC, the
    # storage controller and the GPU; USB covers the dock network adapter, which
    # on a laptop fleet is a real and common way to have no network. Filtering to
    # those two takes the lab host from 118 "critical" devices to 5 - two GPUs,
    # an NVMe controller, a wired NIC and a Wi-Fi card - which is a list somebody
    # will actually read.
    $criticalBus = [string[]] @('PCI', 'USB')

    $critical = 0
    $unmatched = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $Device) {
        if ($null -eq $current) { continue }

        $class = [string] (& $read $current 'Class')

        # NOT CLASSED IS NOT CRITICAL - see the description. Absent, not guessed.
        if ([string]::IsNullOrWhiteSpace($class)) { continue }
        if ($criticalClass -notcontains $class) { continue }

        # ON A REAL BUS, or it is a software device nothing was ever going to
        # cover. The enumerator is the segment before the first backslash of the
        # device id: 'PCI\VEN_8086&DEV_15D7...' -> 'PCI'.
        $deviceId = [string] (& $read $current 'DeviceId')
        # [char] 0x5C IS A BACKSLASH, written as its code point on purpose: a
        # literal one here is the character every layer between an editor and
        # this file wants to escape, and it silently became IndexOf('') once
        # already - which returns 0, empties every enumerator and quietly
        # reports that no device on the machine is critical.
        $separator = $deviceId.IndexOf([char] 0x5C)
        $enumerator = $deviceId
        if ($separator -ge 0) { $enumerator = $deviceId.Substring(0, $separator) }

        if ($criticalBus -notcontains $enumerator.ToUpperInvariant()) { continue }

        $critical++

        $hardware = @()
        $value = & $read $current 'HardwareID'
        if ($null -ne $value) { $hardware = @($value) }

        $compatible = @()
        $value = & $read $current 'CompatibleID'
        if ($null -ne $value) { $compatible = @($value) }

        $covered = $false

        foreach ($id in (@($hardware) + @($compatible))) {
            if ($null -eq $id) { continue }

            if ($claimed.Contains(([string] $id).Trim())) {
                $covered = $true
                break
            }
        }

        if ($covered) { continue }

        [void] $unmatched.Add([pscustomobject] @{
                Name       = [string] (& $read $current 'Name')
                Class      = $class
                DeviceId   = [string] (& $read $current 'DeviceId')
                # THE MOST SPECIFIC ID, FIRST IN THE LIST. It is what a vendor's
                # download page is searched for, and MDT logs the same one -
                # ZTIDrivers writes "Skipping Device <first PnP id> No 3rd party
                # drivers found."
                HardwareId = [string[]] @($hardware)
            })
    }

    return [pscustomobject] @{
        DeviceCount             = [int] @($Device | Where-Object { $null -ne $_ }).Count
        DriverCount             = [int] @($Driver | Where-Object { $null -ne $_ }).Count
        RelevantCount           = [int] $relevant.Count
        RelevantDriver          = [pscustomobject[]] @($relevant)
        CriticalClass           = $criticalClass
        CriticalBus             = $criticalBus
        CriticalDeviceCount     = [int] $critical
        UnmatchedCriticalDevice = [pscustomobject[]] @($unmatched)
    }
}
