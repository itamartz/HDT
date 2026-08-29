# Gather\devices.json - the machine's hardware ids, written beside
# provenance.json and facts.json in every deployment's log directory.
#
# WHY IT EXISTS AT ALL. Gather captures twenty machine facts and NOT ONE
# hardware id. Make and model tell an administrator which driver PACK to fetch;
# the hardware id is the only thing that identifies the specific dead device in
# front of them, and until this file nothing in HDT recorded one. A deployment
# that came up without a network card could be diagnosed down to "it is a
# Latitude 5490" and no further.
#
# IT IS MDT'S SHAPE. ZTIDrivers.wsf shells Microsoft.BDD.PnpEnum.exe and writes
# PnpEnum.xml into the log directory - a device inventory FILE beside the logs,
# which is exactly this. Two deliberate differences, both recorded on the
# command itself: it is written at GATHER rather than inside the driver step, so
# it exists even on a run that dies before drivers; and it comes from CIM rather
# than a compiled enumerator, because Microsoft.BDD.PnpEnum.exe is an MDT
# binary and rule 4 forbids it.
#
# THE SHAPES HERE ARE CAPTURED, NOT INVENTED. tests\fixtures\cim\Win32_PnPEntity.json
# came off real hardware, and it carries the two traps: CompatibleID is null on
# some rows, and PNPClass is empty on others (SPIKES S19 saw one such row in
# WinPE). Both are StrictMode errors waiting for a reader that assumes.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:devicePath = 'X:\HDT\Logs\Gather\devices.json'
    $script:stamp = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)

    # Through a variable, never @(ConvertFrom-Json ...) - helpers README F12.
    $script:capturedText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity.json'))
    $script:captured = ConvertFrom-Json -InputObject $script:capturedText
}

Describe 'Export-HDTDeviceInventory' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem
        $script:cim = New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($script:captured) }
        $script:device = @(Get-HDTPresentDevice -Cim $script:cim)

        $script:read = {
            return (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:devicePath)))
        }
    }

    Context 'the document' {

        It 'writes devices.json through the injected filesystem' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $script:fs.GetOperationName() | Should -Be @('WriteAllText')
            $script:fs.Operations[0].Arguments[0] | Should -BeExactly $script:devicePath
        }

        It 'writes valid JSON' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            { ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:devicePath)) } | Should -Not -Throw
        }

        It 'writes schemaVersion 1' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            (& $script:read).schemaVersion | Should -Be 1
        }

        It 'formats the timestamp as a string rather than leaving a [datetime] to ConvertTo-Json' {
            # 5.1 renders a raw [datetime] as "\/Date(1786579862481)\/" and 5.1
            # is the engine that runs in WinPE, where this file is written.
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $script:fs.ReadAllText($script:devicePath) | Should -Not -Match '\\/Date\('
            (& $script:read).generated | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
        }

        It 'records how many devices it wrote' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            (& $script:read).deviceCount | Should -Be $script:device.Count
        }

        It 'writes a row per device' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            @((& $script:read).device).Count | Should -Be $script:device.Count
        }
    }

    Context 'the hardware ids, which are the whole point' {

        It 'writes the hardware ids of a captured device' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $row = @((& $script:read).device | Where-Object { $_.name -eq 'Intel(R) Iris(R) Xe Graphics' })

            $row.Count | Should -Be 1
            @($row[0].hardwareId) | Should -Contain 'PCI\VEN_8086&DEV_46A6&SUBSYS_3AE817AA&REV_0C'
        }

        It 'keeps the hardware ids in the order Windows published them' {
            # Windows publishes HardwareID most specific first, and that order is
            # the only specificity signal there is - it is what Get-HDTDriverMatch
            # ranks on. Sorting or deduping this file would throw it away.
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $row = @((& $script:read).device | Where-Object { $_.name -eq 'Intel(R) Iris(R) Xe Graphics' })[0]

            @($row.hardwareId)[0] | Should -BeExactly 'PCI\VEN_8086&DEV_46A6&SUBSYS_3AE817AA&REV_0C'
            @($row.hardwareId)[1] | Should -BeExactly 'PCI\VEN_8086&DEV_46A6&SUBSYS_3AE817AA'
        }

        It 'keeps hardware ids and compatible ids in separate lists' {
            # Merging them would lose the distinction the ranker depends on:
            # every CompatibleID ranks behind every HardwareID.
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $row = @((& $script:read).device | Where-Object { $_.name -eq 'Intel(R) Iris(R) Xe Graphics' })[0]

            @($row.compatibleId) | Should -Contain 'PCI\CC_0300'
            @($row.hardwareId) | Should -Not -Contain 'PCI\CC_0300'
        }

        It 'writes an empty list, not null, for a device whose CompatibleID is null' {
            # The captured Bluetooth PAN row has CompatibleID null. A reader
            # under StrictMode calling .Count on that is an error at the point
            # somebody reads it rather than the point it was produced.
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $row = @((& $script:read).device |
                    Where-Object { $_.name -eq 'Bluetooth Device (Personal Area Network)' })[0]

            @($row.compatibleId).Count | Should -Be 0

            # An EMPTY ARRAY in the file, not the word null: a consumer reading
            # this should not have to tell "no compatible ids" apart from "this
            # writer did not know".
            $script:fs.ReadAllText($script:devicePath) | Should -Match '"compatibleId":\s*\[\s*\]'
        }

        It 'keeps a single-id list an array rather than collapsing it to a string' {
            # 5.1's ConvertTo-Json is where this goes wrong, and a consumer that
            # got a string for one device and an array for the next would be
            # reading a different document per machine.
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $text = $script:fs.ReadAllText($script:devicePath)

            $text | Should -Match '"hardwareId":\s*\[[^\]]*"BTH\\\\MS_BTHPAN"'
        }
    }

    Context 'the class, which SPIKES S19 saw empty in WinPE' {

        It 'writes the PNPClass rather than the Class that is null on every row' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $row = @((& $script:read).device | Where-Object { $_.name -eq 'Intel(R) Iris(R) Xe Graphics' })[0]

            $row.class | Should -BeExactly 'Display'
        }

        It 'writes a device whose class is empty rather than dropping it' {
            # S19 booted HDT's own boot image and got PNPClass on 32 of 44 rows.
            # A row with no class still carries the ids that identify it, which
            # is the reason the file exists.
            $blank = [pscustomobject] @{
                Name = ''; Class = ''; DeviceId = 'VMBUS\{ABCD}'
                HardwareID = [string[]] @('VMBUS\{ABCD}'); CompatibleID = [string[]] @()
                Manufacturer = ''; Service = ''
            }

            Export-HDTDeviceInventory -Device @($blank) -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $document = & $script:read

            $document.deviceCount | Should -Be 1
            @($document.device)[0].class | Should -BeExactly ''
            @(@($document.device)[0].hardwareId) | Should -Contain 'VMBUS\{ABCD}'
        }
    }

    Context 'refusals and edges' {

        It 'writes an empty inventory rather than throwing when the machine reported nothing' {
            # A machine that reports no devices is a finding, not a crash - and
            # a missing file is indistinguishable from a step that never ran.
            Export-HDTDeviceInventory -Device @() -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp

            $document = & $script:read

            $document.deviceCount | Should -Be 0
            @($document.device).Count | Should -Be 0
        }

        It 'names the file and writes nothing under -WhatIf' {
            Export-HDTDeviceInventory -Device $script:device -Path $script:devicePath `
                -FileSystem $script:fs -Timestamp $script:stamp -WhatIf

            $script:fs.GetOperationName() | Should -Not -Contain 'WriteAllText'
        }
    }
}
