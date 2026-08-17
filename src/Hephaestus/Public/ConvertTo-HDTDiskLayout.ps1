function ConvertTo-HDTDiskLayout {
    <#
        .SYNOPSIS
            Turns an authored partition table into the layout the planner reads.

        .DESCRIPTION
            TWO NAMED LAYOUTS WAS THE WHOLE VOCABULARY. DESIGN 9.1 offers
            uefi-standard and bios-standard and a DiskPartition step names one -
            so a share that wants a data volume beside Windows, which is the
            commonest thing an administrator does with MDT's Format and
            Partition Disk, could not say it at all.

            THIS IS THE HALF THAT DOES NO ARITHMETIC. It maps what somebody
            wrote - a name, a type, '260MB' or '60%', a filesystem - onto the
            row shape Get-HDTDiskLayout produces, so New-HDTDiskLayoutPlan works
            unchanged and every byte-count decision stays in the one place that
            is already tested against real disk sizes.

            A PERCENTAGE STAYS A PERCENTAGE. 60% of what depends on the machine
            this runs on; turning it into bytes here would bake the authoring
            host's idea of a disk into the document. The row carries
            PercentOfRemainder and the planner resolves it against the disk in
            front of it.

            THE GUIDs ARE NOT THE AUTHOR'S PROBLEM. Nobody should type
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b into a task sequence to get an
            EFI partition - they type EFI, and this knows what that means,
            including that an ESP is CREATED as basic data so it can be given a
            letter and formatted, and retyped afterwards (DESIGN 9.1).

            IT REFUSES RATHER THAN GUESSES. Two rows claiming the remainder,
            percentages adding past 100, an EFI partition on an MBR disk, a size
            it cannot read: each is a disk laid out by accident, and this
            subsystem exists to prevent exactly that.

        .PARAMETER Partition
            The authored rows, in on-disk order. Each carries name, type and
            size; filesystem, label and variable are optional.

        .PARAMETER Style
            GPT or MBR.

        .PARAMETER Name
            What to call the layout in messages. Defaults to 'authored'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - Name, PartitionStyle,
            ReservedSizeByte, AlignmentSizeByte and Partition, the same shape
            Get-HDTDiskLayout returns.

        .EXAMPLE
            ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                @{ name = 'System';  type = 'EFI';      size = '260MB' }
                @{ name = 'Windows'; type = 'Primary';  size = '60%' }
                @{ name = 'Data';    type = 'Primary';  size = 'remainder' })

        .EXAMPLE
            $layout = ConvertTo-HDTDiskLayout -Style GPT -Partition $step.partition
            New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte $disk.SizeByte
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Partition,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('GPT', 'MBR')]
        [string] $Style,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'authored'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE SAME GUIDs Get-HDTDiskLayout USES. They are repeated here rather than
    # shared because the named layouts are DATA in that command and these are
    # the mapping from a word an author types; a shared constant would couple
    # two lists that answer different questions.
    $basicDataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $espType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

    # THE SAME ALLOWANCES, and DESIGN 9.1's reason: Initialize-Disk creates the
    # 16 MB MSR itself, so it is subtracted and never planned. An authored
    # layout gets that for free rather than asking an author to know it.
    $reservedSizeByte = 16777216
    $alignmentSizeByte = 1048576

    if (@($Partition).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                    -Message 'a partition table with no rows in it is not a layout. Name at least one partition, or use a named layout.'))
    }

    $row = New-Object -TypeName System.Collections.ArrayList
    $remainderCount = 0
    $percentTotal = 0
    $bootableCount = 0
    $index = 0

    foreach ($current in @($Partition)) {
        $index++

        # A hashtable and a PSCustomObject both authored the same way, because
        # YAML gives one and a caller building rows by hand gives the other.
        $read = {
            param([string] $Key)

            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($Key)) { return [string] $current[$Key] }
                return ''
            }

            if ($null -eq $current.PSObject.Properties[$Key]) { return '' }
            return [string] $current.$Key
        }

        $label = & $read 'name'
        $type = & $read 'type'
        $size = & $read 'size'
        $fileSystem = & $read 'filesystem'
        $variable = & $read 'variable'
        $quickFormatText = & $read 'quickFormat'
        $bootableText = & $read 'bootable'

        $locator = 'partition {0}' -f $index
        if (-not [string]::IsNullOrWhiteSpace($label)) { $locator = "partition '{0}'" -f $label }

        # -- the type ---------------------------------------------------------

        $gptType = ''
        $createGptType = ''
        $defaultFileSystem = 'NTFS'

        switch ($type) {
            'EFI' {
                if ($Style -eq 'MBR') {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $label `
                                -Message ("{0} is an EFI partition, and this layout is MBR. An EFI System Partition only exists on a GPT disk - change the style to GPT, or make it a Primary partition." -f $locator)))
                }

                $gptType = $espType

                # CREATED AS BASIC DATA, THEN RETYPED. An ESP cannot be given a
                # drive letter and formatted while it carries the ESP type, and
                # a partition that cannot be formatted cannot be a boot volume.
                $createGptType = $basicDataType
                $defaultFileSystem = 'FAT32'
            }
            'Recovery' {
                if ($Style -eq 'GPT') { $gptType = $recoveryType }
            }
            'Primary' { }
            'Logical' { $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $type `
                        -Message ("{0} is type 'Logical'. MDT's dialog offers it, and this engine has never created an extended container to put one in - so accepting the word and quietly making a Primary would produce a disk that does not match the document." -f $locator))) }
            'Extended' { $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $type `
                        -Message ("{0} is type 'Extended'. MDT's dialog offers it; this engine creates basic partitions on GPT or MBR and makes no extended container." -f $locator))) }
            default {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $type `
                            -Message ("{0} has type '{1}', which is not one this engine creates. Use EFI, Primary or Recovery." -f $locator, $type)))
            }
        }

        if ([string]::IsNullOrWhiteSpace($fileSystem)) { $fileSystem = $defaultFileSystem }

        # -- the size ---------------------------------------------------------

        $sizeByte = [long] 0
        $useMaximum = $false
        $percent = 0

        $sizeText = ([string] $size).Trim()

        if ($sizeText -match '^(remainder|\*)$') {
            $useMaximum = $true
            $remainderCount++
        } elseif ($sizeText -match '^([0-9]+)\s*%$') {
            $percent = [int] $Matches[1]
            $percentTotal += $percent
        } elseif ($sizeText -match '^([0-9]+)\s*(KB|MB|GB|TB)$') {
            $unit = @{ KB = 1KB; MB = 1MB; GB = 1GB; TB = 1TB }[$Matches[2].ToUpperInvariant()]
            $sizeByte = [long] $Matches[1] * [long] $unit
        } elseif ($sizeText -match '^[0-9]+$') {
            $sizeByte = [long] $sizeText
        } else {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $size `
                        -Message ("{0} has size '{1}', which is not a size this engine reads. Use bytes, 260MB, 1GB, a percentage like 60%, or remainder." -f $locator, $size)))
        }

        $quickFormat = $true
        if ($quickFormatText -match '^(false|0|no)$') { $quickFormat = $false }

        # UNSET IS NOT False. A row that says nothing about booting takes the
        # positional default; a row that says bootable: false is refusing it,
        # and the two have to be told apart or an explicit bootable on the
        # second row could never win.
        $isActive = ($Style -eq 'MBR' -and $index -eq 1)

        if ($bootableText -match '^(true|1|yes)$') {
            $isActive = $true
            $bootableCount++
        } elseif ($bootableText -match '^(false|0|no)$') {
            $isActive = $false
        }

        [void] $row.Add([pscustomobject] @{
                Role              = $label
                SizeByte          = $sizeByte

                # TWO FLAGS, BECAUSE THEY ARE TWO QUESTIONS. UseMaximumSize is
                # where leftover slack LANDS when the partition is created -
                # uefi-standard puts it on Recovery. TakesRemainder is which row
                # gets the space nothing else claimed, which in the named
                # layouts is Windows and here is whichever row said 'remainder'.
                # Collapsing them would give an authored layout Recovery's flag
                # and Windows' meaning.
                UseMaximumSize    = $useMaximum
                TakesRemainder    = $useMaximum
                PercentOfRemainder = $percent
                FileSystem        = $fileSystem
                Label             = $label
                DriveLetter       = ''
                GptType           = $gptType
                CreateGptType     = $createGptType

                # MBR BOOTS FROM AN ACTIVE PARTITION and GPT has no such
                # concept. The default is the first row - which is MDT's default
                # too, "True if 1st partition" - and an explicit bootable on any
                # row overrides it, because a System partition is not always
                # written first.
                IsActive          = $isActive
                Variable          = $variable

                # MDT's QUICKFORMAT, default True. A full format is hours on a
                # large disk and the only way to know a suspect one can hold
                # what is written to it; refusing to carry the choice would mean
                # HDT could not express a sequence somebody already runs.
                QuickFormat       = $quickFormat
            })
    }

    if ($remainderCount -gt 1) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                    -Message ("{0} partitions claim the remainder of the disk. Only one can have it, and which one would otherwise be an accident of order." -f $remainderCount)))
    }

    if ($bootableCount -gt 1) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                    -Message ("{0} partitions are declared bootable. The firmware picks one, and which one is then not the author's decision." -f $bootableCount)))
    }

    if ($percentTotal -gt 100) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                    -Message ("the percentages in this layout add up to {0}%, which does not fit on a disk. Reduce them, or give the last partition 'remainder' instead." -f $percentTotal)))
    }

    return [pscustomobject] @{
        Name              = $Name
        PartitionStyle    = $Style
        ReservedSizeByte  = $reservedSizeByte
        AlignmentSizeByte = $alignmentSizeByte
        Partition         = [pscustomobject[]] @($row)
    }
}
