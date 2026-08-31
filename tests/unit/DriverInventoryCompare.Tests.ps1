# Which of the staged drivers are relevant to THIS machine, and which of the
# devices that would strand it have nothing staged.
#
# THE FRAMING IS THE WHOLE POINT, AND IT IS EASY TO GET WRONG IN A WAY THAT IS
# WORSE THAN SAYING NOTHING. "118 devices, 112 not covered" is a true sentence
# and a useless one: most devices are served by Windows in-box drivers, so that
# number is both normal and alarming, and an administrator who reads it twice
# learns to ignore the line. Two questions are worth answering:
#
#   IS THIS THE RIGHT PACK AT ALL? How many staged .inf files claim an id this
#   machine actually reports. A pack for a different model matches almost
#   nothing, and that is visible immediately.
#
#   IS ANYTHING THAT MATTERS UNSERVED? A device in the classes that strand a
#   machine - network, storage, chipset, display - with no staged .inf claiming
#   it. Everything else is noise.
#
# AND IT MUST NOT BE READ AS A VERDICT. This does not rank drivers, does not
# read a signature, a date or a version, and knows nothing about the in-box
# drivers in the image being applied. A device with no staged .inf is usually
# served perfectly well by Windows. A confident false negative here sends an
# administrator hunting a driver they do not need, which is exactly the failure
# this is supposed to prevent.
#
# THE INPUTS ARE REAL ON BOTH SIDES. The devices come from
# tests\fixtures\cim\Win32_PnPEntity.json, captured off real hardware. The .inf
# files are real files: spaceport.inf off C:\Windows\INF - UTF-16LE, class
# SCSIAdapter, and it claims Root\Spaceport, which the captured machine reports
# as a HardwareID - and latitude-5490-northpeak.inf out of the Dell pack on the
# lab share, class System, whose ids that machine does not have. An .inf written
# to suit the matcher would prove nothing about a vendor's download page.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Through a variable, never @(ConvertFrom-Json ...) - helpers README F12.
    $script:capturedText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity.json'))
    $script:captured = ConvertFrom-Json -InputObject $script:capturedText

    $script:infRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\drivers'

    # ReadAllText, not Get-Content: spaceport.inf is UTF-16LE, which is as
    # common as ANSI among real .inf files, and a reader that assumes one gets
    # one character in two from the other.
    $script:spaceportText = [System.IO.File]::ReadAllText((Join-Path -Path $script:infRoot -ChildPath 'spaceport.inf'))
    $script:northpeakText = [System.IO.File]::ReadAllText((Join-Path -Path $script:infRoot -ChildPath 'latitude-5490-northpeak.inf'))

    # THE LATITUDE 5420 CAPTURE, AND EVERY ROW IN IT IS THERE FOR A REASON THE
    # LIVE LOG SURFACED. Two Intel VMD instances that share a name AND a first
    # hardware id and differ only in their instance path; the I219-LM, which two
    # differently named .inf files on the share both claim; the RAID controller;
    # and an ACPI device Windows reports with NO NAME AT ALL, which the log
    # rendered as ''. Five real rows out of the 108 that machine reported.
    $script:latitudeText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity-latitude-5420.json'))
    $script:latitude = ConvertFrom-Json -InputObject $script:latitudeText

    # ReadAllText again, and iastorvd-excerpt.inf is UTF-16LE like its original.
    $script:iastorvdText = [System.IO.File]::ReadAllText((Join-Path -Path $script:infRoot -ChildPath 'iastorvd-excerpt.inf'))
    $script:e1dText = [System.IO.File]::ReadAllText((Join-Path -Path $script:infRoot -ChildPath 'e1d-excerpt.inf'))
    $script:e1d68Text = [System.IO.File]::ReadAllText((Join-Path -Path $script:infRoot -ChildPath 'e1d68x64-excerpt.inf'))

    $script:compare = {
        param([object[]] $Device, [object[]] $Driver)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($D, $R)
            Compare-HDTDriverInventory -Device $D -Driver $R
        } $Device $Driver
    }

    $script:parse = {
        param([string] $Text, [string] $Name)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($T, $N)
            ConvertFrom-HDTDriverInf -Text $T -InfName $N
        } $Text $Name
    }
}

Describe 'Compare-HDTDriverInventory' {

    BeforeEach {
        $script:cim = New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($script:captured) }
        $script:device = @(Get-HDTPresentDevice -Cim $script:cim)

        $script:spaceport = & $script:parse $script:spaceportText 'spaceport.inf'
        $script:northpeak = & $script:parse $script:northpeakText 'latitude-5490-northpeak.inf'
    }

    Context 'the fixtures are what this test thinks they are' {

        It 'reads the UTF-16LE .inf as a driver rather than as mojibake' {
            $script:spaceport.Class | Should -BeExactly 'SCSIAdapter'
            @($script:spaceport.HardwareId) | Should -Contain 'Root\Spaceport'
        }

        It 'reads the vendor pack .inf, decorated sections and all' {
            $script:northpeak.Class | Should -BeExactly 'System'
            @($script:northpeak.HardwareId) | Should -Contain 'PCI\VEN_8086&DEV_A326'
        }

        It 'has a captured device that claims the storage driver''s id' {
            @($script:device | Where-Object { @($_.HardwareID) -contains 'Root\Spaceport' }) |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'which staged drivers are relevant to this machine' {

        It 'reports a driver that claims an id this machine reports' {
            $report = & $script:compare $script:device @($script:spaceport, $script:northpeak)

            @($report.RelevantDriver | ForEach-Object { $_.InfName }) | Should -Contain 'spaceport.inf'
        }

        It 'does not report a driver for hardware this machine has not got' {
            $report = & $script:compare $script:device @($script:spaceport, $script:northpeak)

            @($report.RelevantDriver | ForEach-Object { $_.InfName }) |
                Should -Not -Contain 'latitude-5490-northpeak.inf'
        }

        It 'counts the drivers it was given and the ones that matched' {
            $report = & $script:compare $script:device @($script:spaceport, $script:northpeak)

            $report.DriverCount | Should -Be 2
            $report.RelevantCount | Should -Be 1
        }

        It 'names the device that made a driver relevant' {
            # "Which of my hardware wanted this?" is the question asked next, and
            # a report that answers only "it matched" leaves it unanswered.
            $report = & $script:compare $script:device @($script:spaceport)
            $row = @($report.RelevantDriver)[0]

            $row.DeviceName | Should -BeExactly 'Microsoft Storage Spaces Controller'
        }

        It 'says which id matched' {
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.RelevantDriver)[0].MatchedId | Should -BeExactly 'Root\Spaceport'
        }

        It 'records that the match was on a HardwareID rather than a CompatibleID' {
            # THE KIND OF MATCH IS NOT A DETAIL. A HardwareID match is the vendor
            # naming this exact device; a CompatibleID match is a generic class
            # fallback that Windows would very likely have served itself. Telling
            # an administrator which one they have is the difference between
            # "this pack is for your machine" and "this pack has something that
            # would fit".
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.RelevantDriver)[0].Source | Should -BeExactly 'HardwareID'
        }

        It 'records a compatible-id match as one' {
            # A driver claiming only the generic tail of a captured device.
            $generic = [pscustomobject] @{
                InfName = 'generic.inf'; Name = 'Generic display'; Class = 'Display'
                Provider = 'Test'; Version = '1.0'; Date = '01/01/2020'
                HardwareId = [string[]] @('PCI\CC_0300')
            }

            $report = & $script:compare $script:device @($generic)

            @($report.RelevantDriver)[0].Source | Should -BeExactly 'CompatibleID'
        }
    }

    Context 'the devices that would strand a machine' {

        It 'reports a network device with no staged driver' {
            # Only the storage .inf is staged, so every Net device is unserved by
            # the pack - which is the sentence a technician standing in front of
            # a machine with no network card needs.
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.UnmatchedCriticalDevice | ForEach-Object { $_.Class }) | Should -Contain 'Net'
        }

        It 'does not report a critical device that a staged driver claims' {
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.UnmatchedCriticalDevice | ForEach-Object { $_.Name }) |
                Should -Not -Contain 'Microsoft Storage Spaces Controller'
        }

        It 'leaves the classes that stranding does not depend on out of it' {
            # An unserved audio device is not a machine somebody has to drive back
            # out to. Reporting it would bury the ones that are.
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.UnmatchedCriticalDevice | ForEach-Object { $_.Class }) |
                Should -Not -Contain 'AudioEndpoint'
        }

        It 'ignores a virtual network adapter, which no driver pack ever covers' {
            # OF 25 Net DEVICES ON THE LAB HOST, TWO ARE NETWORK CARDS. The rest
            # are WAN miniports on ROOT, software devices on SWD, Bluetooth PAN
            # on BTH and a Wi-Fi Direct virtual adapter - Windows software
            # constructs that no vendor has ever shipped a driver for. Reporting
            # them as uncovered is reporting that a driver pack is not something
            # it was never trying to be, and it was 113 of the 118 "critical"
            # devices the first version of this found.
            $virtual = [pscustomobject] @{
                Name = 'WAN Miniport (IKEv2)'; Class = 'Net'; DeviceId = 'ROOT\MS_AGILEVPNMINIPORT\0000'
                HardwareID = [string[]] @('ms_agilevpnminiport'); CompatibleID = [string[]] @()
                Manufacturer = 'Microsoft'; Service = 'RasAgileVpn'
            }

            $report = & $script:compare @($virtual) @($script:spaceport)

            @($report.UnmatchedCriticalDevice) | Should -HaveCount 0
            [int] $report.CriticalDeviceCount | Should -Be 0
        }

        It 'still counts a real card on the PCI bus' {
            $card = [pscustomobject] @{
                Name = 'Intel(R) Ethernet Connection I219-LM'; Class = 'Net'
                DeviceId = 'PCI\VEN_8086&DEV_15D7&SUBSYS_08161028&REV_21\3&11583659&0&FE'
                HardwareID = [string[]] @('PCI\VEN_8086&DEV_15D7&SUBSYS_08161028&REV_21')
                CompatibleID = [string[]] @(); Manufacturer = 'Intel'; Service = 'e1dexpress'
            }

            $report = & $script:compare @($card) @($script:spaceport)

            [int] $report.CriticalDeviceCount | Should -Be 1
            @($report.UnmatchedCriticalDevice | ForEach-Object { $_.Name }) |
                Should -Contain 'Intel(R) Ethernet Connection I219-LM'
        }

        It 'counts a dock network adapter on USB, which is how a laptop loses its network' {
            $dock = [pscustomobject] @{
                Name = 'Dell Dock Ethernet'; Class = 'Net'; DeviceId = 'USB\VID_0BDA&PID_8153\1'
                HardwareID = [string[]] @('USB\VID_0BDA&PID_8153'); CompatibleID = [string[]] @()
                Manufacturer = 'Realtek'; Service = 'RtkUsbClient'
            }

            $report = & $script:compare @($dock) @($script:spaceport)

            [int] $report.CriticalDeviceCount | Should -Be 1
        }

        It 'leaves chipset out of the warning, because Windows serves it in-box' {
            # System IS in Get-HDTBootCriticalClass, and belongs there: a boot
            # image needs the bus enumerators a storage controller sits behind.
            # On a DEPLOYED Windows it is 88 of 118 devices on the lab host -
            # ACPI nodes, host bridges, thermal zones - essentially all served
            # in-box. Warning about them produces a line so large it teaches an
            # administrator to ignore the two entries that mattered.
            $chipset = [pscustomobject] @{
                Name = 'Intel(R) Host Bridge'; Class = 'System'
                DeviceId = 'PCI\VEN_8086&DEV_9B33\3&11583659&0&00'
                HardwareID = [string[]] @('PCI\VEN_8086&DEV_9B33'); CompatibleID = [string[]] @()
                Manufacturer = 'Intel'; Service = ''
            }

            $report = & $script:compare @($chipset) @($script:spaceport)

            @($report.CriticalClass) | Should -Not -Contain 'System'
            @($report.UnmatchedCriticalDevice) | Should -HaveCount 0
        }

        It 'counts display among the classes that matter, though the boot image does not' {
            # Get-HDTBootCriticalClass is about a BOOT IMAGE, which needs a disk
            # and a network and nothing else. A deployed machine with no display
            # driver is a machine somebody has to look at.
            $report = & $script:compare $script:device @($script:spaceport)

            @($report.CriticalClass) | Should -Contain 'Display'
            @($report.UnmatchedCriticalDevice | ForEach-Object { $_.Class }) | Should -Contain 'Display'
        }

        It 'does not call a device critical when the machine did not say what class it is' {
            # SPIKES S19: PNPClass came back populated on 32 of 44 rows in WinPE.
            # A device whose class is unknown cannot be asserted to be critical,
            # and guessing would put a false alarm in front of a technician - the
            # exact failure this report exists to avoid.
            $unclassed = [pscustomobject] @{
                Name = 'Something'; Class = ''; DeviceId = 'VMBUS\X'
                HardwareID = [string[]] @('VMBUS\X'); CompatibleID = [string[]] @()
                Manufacturer = ''; Service = ''
            }

            $report = & $script:compare @($unclassed) @($script:spaceport)

            @($report.UnmatchedCriticalDevice) | Should -HaveCount 0
        }

        It 'names the ids of an unmatched device, which is what a search needs' {
            $report = & $script:compare $script:device @($script:spaceport)
            $row = @($report.UnmatchedCriticalDevice | Where-Object { $_.Class -eq 'Net' })[0]

            $row.HardwareId | Should -Not -BeNullOrEmpty
        }
    }

    # ONE LINE PER DEVICE, WHICH IS MDT'S SHAPE AND THE ONE THING THE LOG DID
    # NOT HAVE. ZTIDrivers.wsf walks every PnP device and writes either "Found
    # Device <id> with 3rd party drivers! Count = N" or "Skipping Device <id> No
    # 3rd party drivers found." - so a device nothing claims is NAMED rather
    # than silently absent. HDT logged the INF-to-device direction and not this
    # one, which meant a device with no staged .inf could not be found in the
    # log at all: "105 device(s) reported hardware ids" and then four lines.
    #
    # THE WARNING IS A DIFFERENT DECISION AND IT STAYS NARROW. Class AND real
    # bus took 118 "critical" devices down to 5, deliberately, because a warning
    # naming 118 trains an administrator to ignore it. That narrowing was right
    # for the WARNING; applying it to the LISTING is what hid the other 100.
    Context 'every device, and what claims it' {

        BeforeEach {
            $script:dell = @(Get-HDTPresentDevice -Cim (New-HDTFakeCimProvider -Instance @{
                        Win32_PnPEntity = [object[]] @($script:latitude)
                    }))

            $script:iastorvd = & $script:parse $script:iastorvdText 'iaStorVD.inf'
            $script:e1d = & $script:parse $script:e1dText 'e1d.inf'
            $script:e1d68 = & $script:parse $script:e1d68Text 'E1D68x64.inf'
        }

        It 'reads the UTF-16LE storage excerpt as a driver claiming both VMD ids' {
            @($script:iastorvd.HardwareId) | Should -Contain 'PCI\VEN_8086&DEV_09AB'
            @($script:iastorvd.HardwareId) | Should -Contain 'PCI\VEN_8086&DEV_9A0B'
        }

        It 'answers one row per device, not one per device that matched' {
            $report = & $script:compare $script:dell @($script:iastorvd)

            @($report.DeviceClaim) | Should -HaveCount @($script:dell).Count
        }

        It 'names the .inf that claims a device, and counts it' {
            $report = & $script:compare $script:dell @($script:iastorvd)

            $row = @($report.DeviceClaim | Where-Object { $_.DeviceId -like '*DEV_9A0B*' })[0]

            $row.ClaimCount | Should -Be 1
            @($row.ClaimingInf) | Should -Contain 'iaStorVD.inf'
        }

        It 'names both .inf files when two of them claim the same id' {
            # THE REAL CASE OFF THE SHARE: e1d.inf out of the 5420 pack and
            # E1D68x64.inf out of the 5490 pack both claim the I219-LM's id.
            $report = & $script:compare $script:dell @($script:e1d, $script:e1d68)

            $row = @($report.DeviceClaim | Where-Object { $_.Class -eq 'Net' })[0]

            $row.ClaimCount | Should -Be 2
            @($row.ClaimingInf) | Should -Contain 'e1d.inf'
            @($row.ClaimingInf) | Should -Contain 'E1D68x64.inf'
        }

        It 'says zero rather than staying silent about a device nothing claims' {
            # THE WHOLE POINT. Before this, a device no staged .inf claimed was
            # simply absent from the log, because the only per-device records
            # came from the drivers that DID match.
            $report = & $script:compare $script:dell @($script:iastorvd)

            $row = @($report.DeviceClaim | Where-Object { $_.Class -eq 'Net' })[0]

            $row.ClaimCount | Should -Be 0
            @($row.ClaimingInf) | Should -HaveCount 0
        }

        It 'keeps the two VMD instances apart by their instance path' {
            # NOT A DE-DUPLICATION GAP. The Latitude 5420 really does report
            # PCI\VEN_8086&DEV_09AB twice - two functions of one VMD controller,
            # same name, same hardware ids, different instance path. A row that
            # carried only the hardware id would render them as one line printed
            # twice, which is exactly what the live log did.
            $report = & $script:compare $script:dell @($script:iastorvd)

            $vmd = @($report.DeviceClaim | Where-Object { $_.DeviceId -like '*DEV_09AB*' })

            $vmd | Should -HaveCount 2
            @($vmd | ForEach-Object { $_.DeviceId } | Sort-Object -Unique) | Should -HaveCount 2
        }

        It 'counts a claim that landed on a CompatibleID, not only on a HardwareID' {
            # A generic claim is still a claim, and MDT counts it: ZTIDrivers
            # walks every childnode of the device, hardware and compatible alike.
            $generic = [pscustomobject] @{
                InfName    = 'generic.inf'; Name = 'Generic AHCI'; Class = 'SCSIAdapter'
                Provider   = 'Test'; Version = '1.0'; Date = '01/01/2020'
                HardwareId = [string[]] @('PCI\VEN_8086&CC_088000')
            }

            $report = & $script:compare $script:dell @($generic)

            $row = @($report.DeviceClaim | Where-Object { $_.DeviceId -like '*DEV_09AB*' })[0]

            $row.ClaimCount | Should -Be 1
            @($row.ClaimingInf) | Should -Contain 'generic.inf'
        }

        It 'carries the device the machine reported with no name at all' {
            # The Latitude reports eight of these. They still publish the ids
            # that identify them, so they are rows - and the CALLER decides what
            # to print instead of an empty pair of quotes.
            $report = & $script:compare $script:dell @($script:iastorvd)

            $row = @($report.DeviceClaim | Where-Object { $_.DeviceId -like 'ACPI\INT34C5*' })[0]

            $row | Should -Not -BeNullOrEmpty
            $row.Name | Should -BeExactly ''
            @($row.HardwareId)[0] | Should -BeExactly 'ACPI\VEN_INT&DEV_34C5'
        }

        It 'does not narrow the listing the way the warning is narrowed' {
            # The unnamed ACPI device is not in a critical class on a critical
            # bus, so it is correctly absent from UnmatchedCriticalDevice - and
            # correctly PRESENT here. Two decisions, and conflating them is what
            # this whole change is about.
            $report = & $script:compare $script:dell @($script:iastorvd)

            @($report.UnmatchedCriticalDevice | Where-Object { $_.DeviceId -like 'ACPI\INT34C5*' }) |
                Should -HaveCount 0
            @($report.DeviceClaim | Where-Object { $_.DeviceId -like 'ACPI\INT34C5*' }) |
                Should -HaveCount 1
        }

        It 'answers a claim row per device rather than throwing when nothing was staged' {
            $report = & $script:compare $script:dell @()

            @($report.DeviceClaim) | Should -HaveCount @($script:dell).Count
            @($report.DeviceClaim | Where-Object { $_.ClaimCount -gt 0 }) | Should -HaveCount 0
        }
    }

    Context 'edges, where a wrong answer is worse than no answer' {

        It 'reports nothing relevant when nothing was staged, rather than throwing' {
            $report = & $script:compare $script:device @()

            $report.DriverCount | Should -Be 0
            $report.RelevantCount | Should -Be 0
        }

        It 'reports no unmatched critical device when the machine reported none' {
            $report = & $script:compare @() @($script:spaceport)

            $report.DeviceCount | Should -Be 0
            @($report.UnmatchedCriticalDevice) | Should -HaveCount 0
        }

        It 'matches ids case-insensitively, because an .inf and a bus disagree about case' {
            $shouty = [pscustomobject] @{
                InfName = 'shouty.inf'; Name = 'Shouty'; Class = 'SCSIAdapter'
                Provider = 'Test'; Version = '1.0'; Date = '01/01/2020'
                HardwareId = [string[]] @('ROOT\SPACEPORT')
            }

            $report = & $script:compare $script:device @($shouty)

            $report.RelevantCount | Should -Be 1
        }

        It 'survives a driver row that claims no ids at all' {
            # Get-HDTDriver -NoHardwareId answers rows like this on purpose, and
            # one reaching here must be ignored rather than throw under StrictMode.
            $header = [pscustomobject] @{
                InfName = 'header.inf'; Name = 'Header only'; Class = 'Net'
                Provider = 'Test'; Version = ''; Date = ''
                HardwareId = [string[]] @()
            }

            { & $script:compare $script:device @($header) } | Should -Not -Throw
        }
    }
}
