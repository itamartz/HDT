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
            # TakesRemainder, NOT UseMaximumSize. This assertion used to read
            # UseMaximumSize and passed while the layout it described could not
            # be built - see 'the two flags' below.
            $data = @($script:row | Where-Object { $_.Label -eq 'Data' })[0]
            $system = @($script:row | Where-Object { $_.Label -eq 'System' })[0]

            $data.TakesRemainder | Should -BeTrue
            $system.TakesRemainder | Should -BeFalse
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

# THE DRIVE LETTER, WHICH THE AUTHORED PATH NEVER ASSIGNED.
#
# Found on a Dell Latitude, not in this suite: 'Format and Partition Disk
# (UEFI)' - the step in the SHIPPED client template - failed on the first real
# machine it ever ran on with
#
#   disk 0 failed while lettering the System partition:
#   SetPartitionDriveLetter ... "The access path is not valid."
#
# because every authored row came back with DriveLetter = '', and an empty
# letter is how the disk service is told to REMOVE an access path. It duly
# tried to remove ':\'.
#
# The named layouts carry S/W/R and the VM runs used a named layout, so ten
# thousand green tests and a full end-to-end VM deployment never touched this.
# A blank letter is not a cosmetic gap either: HDTSystemVolume, HDTOSVolume and
# HDTRecoveryVolume are read straight off these rows, so every step downstream
# of the partitioner was being handed an empty target as well.
Describe 'ConvertTo-HDTDiskLayout, the drive letters' {

    Context 'what an author gets without asking' {

        BeforeAll {
            $script:lettered = ConvertTo-HDTDiskLayout -Partition $script:authored -Style GPT
        }

        It 'gives every partition a drive letter' {
            # THE REGRESSION. One blank letter here is a bare-metal deployment
            # that dies at the partitioner.
            foreach ($row in $script:lettered.Partition) {
                $row.DriveLetter | Should -Not -BeNullOrEmpty -Because "$($row.Label) has to be formatted through one"
            }
        }

        It 'gives System, Windows and Recovery the letters the named layouts use' {
            # uefi-standard is S/W/R. An authored table that used different
            # letters for the same three roles would make every worked example
            # and every log line in DESIGN wrong for half the shares.
            $byRole = @{}
            foreach ($row in $script:lettered.Partition) { $byRole[[string] $row.Label] = [string] $row.DriveLetter }

            $byRole['System']   | Should -BeExactly 'S'
            $byRole['Windows']  | Should -BeExactly 'W'
            $byRole['Recovery'] | Should -BeExactly 'R'
        }

        It 'gives a partition nobody named a letter of its own' {
            # 'Data' is the commonest thing an MDT admin adds, and it matches
            # none of the three roles.
            $data = @($script:lettered.Partition | Where-Object { $_.Label -eq 'Data' })[0]

            $data.DriveLetter | Should -Not -BeNullOrEmpty
            @('S', 'W', 'R') | Should -Not -Contain $data.DriveLetter
        }

        It 'hands out no letter twice' {
            # TWO ROWS ON ONE LETTER IS ONE VOLUME FORMATTED TWICE, and the
            # second format silently destroys the first partition's contents.
            $letter = @($script:lettered.Partition | ForEach-Object { [string] $_.DriveLetter })

            @($letter | Sort-Object -Unique).Count | Should -Be $letter.Count
        }

        It 'never hands out X, which is WinPE itself' {
            # X: is the RAM disk the engine is RUNNING FROM. Formatting it ends
            # the deployment mid-step.
            $many = @(1..12 | ForEach-Object { [pscustomobject] @{ name = "Vol$_"; type = 'Primary'; size = '1GB'; filesystem = 'NTFS' } })

            @((ConvertTo-HDTDiskLayout -Partition $many -Style GPT).Partition | ForEach-Object { $_.DriveLetter }) |
                Should -Not -Contain 'X'
        }
    }

    Context 'what an author writes down' {

        It 'honours a letter the author asked for' {
            $authored = @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'V' }
            )

            $row = @((ConvertTo-HDTDiskLayout -Partition $authored -Style GPT).Partition | Where-Object { $_.Label -eq 'Windows' })[0]

            $row.DriveLetter | Should -BeExactly 'V'
        }

        It 'takes the letter however it was written' {
            # 'v', 'V:' and 'V' are the same answer, and an administrator who
            # typed the colon has not made a mistake.
            $authored = @(
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'v:' }
            )

            (ConvertTo-HDTDiskLayout -Partition $authored -Style GPT).Partition[0].DriveLetter | Should -BeExactly 'V'
        }

        It 'does not give a default letter away to a row that asked for it' {
            # Windows asked for S. System must not also get S.
            $authored = @(
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'S' }
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
            )

            $letter = @((ConvertTo-HDTDiskLayout -Partition $authored -Style GPT).Partition | ForEach-Object { [string] $_.DriveLetter })

            @($letter | Sort-Object -Unique).Count | Should -Be 2
        }

        It 'refuses two partitions claiming the same letter' {
            # Authored, so it is a mistake in the document rather than something
            # to resolve quietly - and resolving it quietly formats one of them
            # over the other.
            $authored = @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32'; letter = 'S' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'S' }
            )

            { ConvertTo-HDTDiskLayout -Partition $authored -Style GPT } | Should -Throw -ExpectedMessage '*S*'
        }

        It 'refuses a letter that is not one' {
            $authored = @(
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'CD' }
            )

            { ConvertTo-HDTDiskLayout -Partition $authored -Style GPT } | Should -Throw
        }

        It 'refuses X, even asked for by name' {
            $authored = @(
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS'; letter = 'X' }
            )

            { ConvertTo-HDTDiskLayout -Partition $authored -Style GPT } | Should -Throw -ExpectedMessage '*X*'
        }
    }
}

# The two flags, which were one flag.
#
# THE SHIPPED CLIENT TEMPLATE STILL COULD NOT PARTITION A DISK after the drive
# letters were fixed. On the same Latitude, one step further in:
#
#   1. System   272629760 bytes    FAT32 S: as System
#   2. Windows  510745993216 bytes NTFS  W: as Windows
#   3. Recovery 1073741824 bytes   NTFS  R: as Recovery
#   disk 0 failed while creating the Recovery partition:
#   NewPartition ... "Not enough available capacity"
#
# The planner had already worked the sizes out correctly - Windows' 510 GB is
# the disk minus System, minus Recovery, minus GPT overhead. What went wrong is
# how Windows was CREATED. This function set
#
#   UseMaximumSize = $useMaximum
#   TakesRemainder = $useMaximum
#
# from one value, and its own comment three lines above says they are two
# questions. New-Partition -UseMaximumSize takes everything left on the disk,
# so Windows swallowed the space Recovery was supposed to get and Recovery was
# created into nothing.
#
# BOTH NAMED LAYOUTS PUT UseMaximumSize ON THE LAST ROW - uefi-standard on
# Recovery, bios-standard on Windows - so the trailing alignment slack lands in
# a partition instead of being left unallocated. That is the invariant, and the
# authored path is now held to it.
Describe 'ConvertTo-HDTDiskLayout, the two flags' {

    Context 'an authored table with a partition after the remainder' {

        BeforeAll {
            # The shipped client template's shape: the remainder is in the
            # MIDDLE, with Recovery after it.
            $script:middle = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS' }
                [pscustomobject] @{ name = 'Recovery'; type = 'Recovery'; size = '1GB'; filesystem = 'NTFS' }
            )
        }

        It 'does not create the remainder partition with UseMaximumSize' {
            # THE REGRESSION. -UseMaximumSize here consumes the whole disk and
            # every partition after it fails to be created at all.
            $windows = @($script:middle.Partition | Where-Object { $_.Label -eq 'Windows' })[0]

            $windows.UseMaximumSize | Should -BeFalse
            $windows.TakesRemainder | Should -BeTrue -Because 'it is still the row that takes what nothing else claimed'
        }

        It 'puts UseMaximumSize on the last row, where the slack lands' {
            $recovery = @($script:middle.Partition | Where-Object { $_.Label -eq 'Recovery' })[0]

            $recovery.UseMaximumSize | Should -BeTrue
        }

        It 'gives UseMaximumSize to exactly one row' {
            @($script:middle.Partition | Where-Object { $_.UseMaximumSize }).Count | Should -Be 1
        }
    }

    Context 'an authored table whose last row IS the remainder' {

        BeforeAll {
            $script:trailing = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = 'remainder'; filesystem = 'NTFS' }
            )
        }

        It 'carries both flags on it' {
            # Nothing follows it, so taking the maximum and taking the
            # remainder are the same instruction here.
            $windows = @($script:trailing.Partition | Where-Object { $_.Label -eq 'Windows' })[0]

            $windows.UseMaximumSize | Should -BeTrue
            $windows.TakesRemainder | Should -BeTrue
        }
    }

    Context 'an authored table with no remainder row at all' {

        It 'still lets the last row absorb the slack' {
            # Otherwise the tail of the disk is left unallocated, which is what
            # UseMaximumSize exists to prevent in both named layouts.
            $sized = ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                [pscustomobject] @{ name = 'System'; type = 'EFI'; size = '260MB'; filesystem = 'FAT32' }
                [pscustomobject] @{ name = 'Windows'; type = 'Primary'; size = '100GB'; filesystem = 'NTFS' }
            )

            @($sized.Partition | Where-Object { $_.UseMaximumSize }).Count | Should -Be 1
            $sized.Partition[-1].UseMaximumSize | Should -BeTrue
        }
    }
}
