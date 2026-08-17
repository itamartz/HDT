# An authored partition table, turned into the layout the planner already eats.
#
# TWO NAMED LAYOUTS WAS THE WHOLE VOCABULARY. DESIGN 9.1 offers uefi-standard
# and bios-standard, and a DiskPartition step can say which one - so a share
# that wants an extra data volume beside Windows, which is the commonest thing
# an MDT admin does with Format and Partition Disk, cannot say it at all.
#
# THIS IS THE ARITHMETIC-FREE HALF. It maps what an administrator wrote -
# a name, a type, "260MB" or "60%", a filesystem - onto the row shape
# Get-HDTDiskLayout produces, GUIDs and all, so New-HDTDiskLayoutPlan keeps
# working unchanged and every byte-count decision stays in one place.
#
# THE GUIDs ARE NOT THE AUTHOR'S PROBLEM. Nobody should type
# c12a7328-f81f-11d2-ba4b-00a0c93ec93b into a task sequence to get an EFI
# partition; they should type EFI.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # What MDT's "extra partition" scenario looks like, authored.
    $script:authored = @(
        [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
        [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = '60%'; filesystem = 'NTFS'; variable = 'HDTOSVolume' }
        [pscustomobject] @{ name = 'Data'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS' }
        [pscustomobject] @{ name = 'Recovery'; type = 'Recovery'; size = '1GB'; filesystem = 'NTFS' }
    )
}

Describe 'ConvertTo-HDTDiskLayout' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'ConvertTo-HDTDiskLayout' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'the layout it produces' {

        BeforeAll {
            $script:layout = ConvertTo-HDTDiskLayout -Partition $script:authored -Style GPT
        }

        It 'carries the same shape Get-HDTDiskLayout does' {
            # THE PLANNER MUST NOT KNOW THE DIFFERENCE. New-HDTDiskLayoutPlan is
            # where the arithmetic lives and it is already tested against the
            # named layouts; an authored one that arrived in a different shape
            # would need a second planner, and then two of them to keep right.
            foreach ($name in 'Name', 'PartitionStyle', 'ReservedSizeByte', 'AlignmentSizeByte', 'Partition') {
                $script:layout.PSObject.Properties[$name] | Should -Not -BeNullOrEmpty -Because "the planner reads $name"
            }
        }

        It 'keeps the authored order' {
            # ORDER IS THE ON-DISK ORDER. An ESP that landed after Windows is a
            # disk that does not boot.
            @($script:layout.Partition | ForEach-Object { $_.Label }) |
                Should -Be @('System', 'Windows', 'Data', 'Recovery')
        }

        It 'carries the same reserved and alignment allowances as a named GPT layout' {
            # The 16 MB MSR allowance is subtracted and never planned - DESIGN
            # 9.1, and the bug PSD shipped. An authored layout gets it for free
            # rather than asking an author to know about it.
            $named = Get-HDTDiskLayout -Name uefi-standard

            $script:layout.ReservedSizeByte | Should -Be $named.ReservedSizeByte
            $script:layout.AlignmentSizeByte | Should -Be $named.AlignmentSizeByte
        }
    }

    Context 'sizes' {

        BeforeAll {
            $script:layout = ConvertTo-HDTDiskLayout -Partition $script:authored -Style GPT
            $script:row = @($script:layout.Partition)
        }

        It 'reads <Size> as <Expected> bytes' -ForEach @(
            @{ Size = '260MB'; Expected = 272629760 }
            @{ Size = '1GB'; Expected = 1073741824 }
            @{ Size = '512MB'; Expected = 536870912 }
            @{ Size = '100KB'; Expected = 102400 }
        ) {
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'X'; type = 'Primary'; size = $Size; filesystem = 'NTFS' })

            @($one.Partition)[0].SizeByte | Should -Be $Expected
        }

        It 'reads a bare number as bytes' {
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'X'; type = 'Primary'; size = 1048576; filesystem = 'NTFS' })

            @($one.Partition)[0].SizeByte | Should -Be 1048576
        }

        It 'carries a percentage as a percentage, not as bytes' {
            # BECAUSE THE DISK IS NOT HERE YET. 60% of what depends on the
            # machine, and turning it into a number now would bake this build
            # host's idea of a disk into the layout. The planner resolves it.
            $windows = @($script:row | Where-Object { $_.Label -eq 'Windows' })[0]

            $windows.PercentOfRemainder | Should -Be 60
            $windows.SizeByte | Should -Be 0
        }

        It 'marks the remainder row and nothing else' {
            $data = @($script:row | Where-Object { $_.Label -eq 'Data' })[0]
            $system = @($script:row | Where-Object { $_.Label -eq 'System' })[0]

            $data.UseMaximumSize | Should -BeTrue
            $system.UseMaximumSize | Should -BeFalse
        }

        It 'refuses two rows claiming the remainder' {
            # ONE OF THEM WOULD GET NOTHING, and which one is an accident of
            # order. A disk laid out by accident is the thing this whole
            # subsystem exists to prevent.
            { ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                    [pscustomobject] @{ name = 'A'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS' }
                    [pscustomobject] @{ name = 'B'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS' }) } |
                Should -Throw -ExpectedMessage '*remainder*'
        }

        It 'refuses a size it cannot read' {
            { ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                    [pscustomobject] @{ name = 'A'; type = 'Primary'; size = 'big'; filesystem = 'NTFS' }) } |
                Should -Throw -ExpectedMessage '*big*'
        }

        It 'refuses percentages that cannot fit' {
            { ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                    [pscustomobject] @{ name = 'A'; type = 'Primary'; size = '70%'; filesystem = 'NTFS' }
                    [pscustomobject] @{ name = 'B'; type = 'Primary'; size = '70%'; filesystem = 'NTFS' }) } |
                Should -Throw -ExpectedMessage '*140*'
        }
    }

    Context 'types' {

        It 'gives an EFI partition the ESP GUID and a FAT32 default' {
            # NOBODY SHOULD TYPE A GUID INTO A TASK SEQUENCE to get an EFI
            # partition. They type EFI.
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB' })

            $row = @($one.Partition)[0]

            $row.GptType | Should -BeExactly '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            $row.FileSystem | Should -BeExactly 'FAT32'
        }

        It 'creates an EFI partition as basic data first, because you cannot format an ESP directly' {
            # DESIGN 9.1: a layout carries BOTH CreateGptType and GptType - the
            # partition is made as basic data so it can be given a letter and
            # formatted, then retyped. An authored ESP needs the same trick or
            # it cannot be formatted at all.
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB' })

            @($one.Partition)[0].CreateGptType | Should -BeExactly '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        }

        It 'gives a Recovery partition its own GUID' {
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'R'; type = 'Recovery'; size = '1GB' })

            @($one.Partition)[0].GptType | Should -BeExactly '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        }

        It 'gives a Primary partition no GUID at all under GPT' {
            # Basic data is what New-Partition makes by default; naming the type
            # explicitly would be a second way to say the same thing.
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'W'; type = 'Primary'; size = '10GB' })

            @($one.Partition)[0].GptType | Should -BeExactly ''
        }

        It 'marks the first partition active under MBR, and none under GPT' {
            # MBR BOOTS FROM AN ACTIVE PARTITION and GPT does not have the
            # concept. bios-standard marks its System partition active; an
            # authored MBR layout has to do the same or the disk does not boot.
            $mbr = ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'Primary'; size = '500MB' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder' })

            @($mbr.Partition)[0].IsActive | Should -BeTrue
            @($mbr.Partition)[1].IsActive | Should -BeFalse
        }

        It 'refuses an EFI partition on an MBR disk' {
            { ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                    [pscustomobject] @{ name = 'S'; type = 'EFI'; size = '260MB' }) } |
                Should -Throw -ExpectedMessage '*MBR*'
        }

        It 'refuses a type it does not know' {
            { ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                    [pscustomobject] @{ name = 'S'; type = 'Exotic'; size = '1GB' }) } |
                Should -Throw -ExpectedMessage '*Exotic*'
        }
    }

    Context 'the fields MDT has and this did not' {

        # MDT's Format and Partition Disk writes one set of variables per
        # partition - PSD's ZTIGather.xml still carries the list:
        #
        #   TYPE  FILESYSTEM  BOOTABLE  QUICKFORMAT  VOLUMENAME
        #   SIZE  SIZEUNITS   VOLUMELETTERVARIABLE
        #
        # Everything there maps onto a row here except two, and both are things
        # an administrator sets on the MDT dialog.

        It 'quick-formats by default, as MDT does' {
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'W'; type = 'Primary'; size = '10GB' })

            @($one.Partition)[0].QuickFormat | Should -BeTrue
        }

        It 'takes a full format when it is asked for' {
            # A FULL FORMAT IS HOURS ON A LARGE DISK, and it is the only way to
            # know a suspect disk can hold what is written to it. MDT offers the
            # choice; refusing to carry it would mean HDT could not express a
            # sequence somebody already runs.
            $one = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'W'; type = 'Primary'; size = '10GB'; quickFormat = $false })

            @($one.Partition)[0].QuickFormat | Should -BeFalse
        }

        It 'marks the first partition bootable by default, which is MDT default too' {
            $mbr = ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                [pscustomobject] @{ name = 'S'; type = 'Primary'; size = '500MB' }
                [pscustomobject] @{ name = 'W'; type = 'Primary'; size = 'remainder' })

            @($mbr.Partition)[0].IsActive | Should -BeTrue
            @($mbr.Partition)[1].IsActive | Should -BeFalse
        }

        It 'lets a later partition be the bootable one when it is declared' {
            $mbr = ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                [pscustomobject] @{ name = 'Data'; type = 'Primary'; size = '10GB'; bootable = $false }
                [pscustomobject] @{ name = 'System'; type = 'Primary'; size = 'remainder'; bootable = $true })

            @($mbr.Partition)[0].IsActive | Should -BeFalse
            @($mbr.Partition)[1].IsActive | Should -BeTrue
        }

        It 'refuses two bootable partitions' {
            # THE FIRMWARE PICKS ONE, and which one is then not the author's
            # decision. An MBR disk with two active partitions is a disk that
            # boots something nobody chose.
            { ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                    [pscustomobject] @{ name = 'A'; type = 'Primary'; size = '1GB'; bootable = $true }
                    [pscustomobject] @{ name = 'B'; type = 'Primary'; size = '1GB'; bootable = $true }) } |
                Should -Throw -ExpectedMessage '*bootable*'
        }

        It 'refuses <_>, which MDT allows and this engine does not create' -ForEach @('Logical', 'Extended') {
            # SAID OUT LOUD RATHER THAN IGNORED. MDT's dialog offers Primary,
            # Logical and Extended; HDT creates basic partitions on GPT or MBR
            # and has never made an extended container. Accepting the word and
            # quietly making a primary would produce a disk that does not match
            # the document.
            $wanted = $_

            { ConvertTo-HDTDiskLayout -Style MBR -Partition @(
                    [pscustomobject] @{ name = 'A'; type = $wanted; size = '1GB' }) } |
                Should -Throw -ExpectedMessage ('*{0}*' -f $wanted)
        }
    }

    Context 'what an empty table means' {

        It 'refuses one, because a disk with no partitions is not a layout' {
            { ConvertTo-HDTDiskLayout -Style GPT -Partition @() } | Should -Throw
        }
    }
}
