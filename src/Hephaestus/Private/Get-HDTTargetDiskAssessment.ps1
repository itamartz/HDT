function Get-HDTTargetDiskAssessment {
    <#
        .SYNOPSIS
            Every disk on the machine with the reason, if any, it cannot be the
            deployment target.

        .DESCRIPTION
            THE SEVEN EXCLUSION RULES OF DESIGN 9.1, EVALUATED ONCE AND SHARED.
            Select-HDTTargetDisk decides with this, and the Validate step LOGS
            with it - which is the reason it exists as its own function.

            The pre-flight has to print the table a refusal would have printed,
            on the run that did NOT refuse: "disk 0 is the deployment target" is
            a choice, and on a laptop with an NVMe, an SD reader and the stick it
            booted from that choice excluded two disks. Recomputing those reasons
            in the step would have been a second source of truth for the most
            destructive decision HDT makes, and the two would eventually
            disagree about which disk may be wiped.

            IT TOUCHES NO HARDWARE. It is handed the three flat listings
            IDiskService returns and joins them, so every rule is provable under
            Pester with no disk attached.

            ABSOLUTE VERSUS NOT is the whole grammar of the result. An absolute
            reason cannot be overridden by naming the disk (rules 1-5); a
            non-absolute one can, with a warning (rules 6-7). Nothing here
            decides anything - it records, and the caller applies the grammar.

        .PARAMETER Disk
            Every disk on the machine, as IDiskService.GetDisk() returns them.

        .PARAMETER Partition
            Every partition on every disk, as IDiskService.GetPartition()
            returns them. It is the spine of rule 5: a partition names its own
            disk, so it is the only listing that can attribute anything to one.
            Omitted, no disk carries anything.

        .PARAMETER Volume
            Every lettered volume, as IDiskService.GetVolume() returns them.
            Used with -Partition to learn whether a disk carries a file system.
            It reports only volumes with an access path, so a partition without
            one is judged from -Partition alone - see rule 5.

        .PARAMETER MinimumSizeByte
            The smallest disk that can hold Windows. Defaults to 60 GB.

        .PARAMETER ProtectDriveLetter
            Drive letters the deployment is reading from or writing to. Matched
            case-insensitively, with or without a colon.

        .PARAMETER AllowExistingData
            The sequence declared that the target's contents are expendable, so
            rule 5 records nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Number, Row,
            Letter, Data, Opaque and Reason. Data is the formatted volumes the
            disk carries that HDT can read; Opaque is the partitions it cannot,
            having no access path. Reason is a list of Absolute/Text pairs and
            is empty for a disk that qualifies.

        .EXAMPLE
            Get-HDTTargetDiskAssessment -Disk $disk -Partition $partition -Volume $volume |
                Where-Object { @($_.Reason).Count -eq 0 }

            The candidates. Exactly one is a target; more than one is a refusal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Disk,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Partition,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Volume,

        [Parameter()]
        [long] $MinimumSizeByte = 64424509440,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $ProtectDriveLetter,

        [Parameter()]
        [switch] $AllowExistingData
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $partitionRow = @()
    if ($null -ne $Partition) { $partitionRow = @($Partition) }

    $volumeRow = @()
    if ($null -ne $Volume) { $volumeRow = @($Volume) }

    # 'z:' and 'Z' are the same letter. Everything is compared as one uppercase
    # character so a test is not a test of which form the author happened to type.
    $protected = @()
    if ($null -ne $ProtectDriveLetter) {
        foreach ($entry in $ProtectDriveLetter) {
            $text = ([string] $entry).Trim().TrimEnd(':')
            if ($text.Length -gt 0) { $protected += $text.Substring(0, 1).ToUpperInvariant() }
        }
    }

    $assessment = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Disk)) {
        $number = [int] $current.Number

        # WHAT THIS DISK CARRIES, IN TWO CLASSES - AND THE SECOND ONE IS THE
        # WHOLE REASON THIS JOIN IS WALKED FROM THE PARTITIONS AND NOT FROM THE
        # VOLUMES.
        #
        # IDiskService REPORTS VOLUMES BY ACCESS PATH. GetVolume() lists the
        # volumes that have a drive letter, because a letter is the only handle
        # the rest of HDT can address a volume by. So a volume mounted to a
        # folder path, or to no path at all - a data disk lifted out of another
        # machine is the ordinary case - is not in that listing at all, and a
        # rule that matched volumes to a disk BY LETTER found an empty set on a
        # disk that was full. That is how rule 5 came to pass a disk carrying
        # somebody's data straight through to Clear-Disk with no wipe: true
        # anywhere in the sequence.
        #
        # DESIGN 9.1 states rule 5 as "a disk carrying a formatted volume",
        # UNQUALIFIED, and these two lists are what make it mean that:
        #
        #   $data    a partition whose volume HDT could read, and did: it has a
        #            file system, so this is existing data and it is named by
        #            the letter and the file system, as it always was.
        #
        #   $opaque  a partition with no drive letter. There is no listing entry
        #            to read, so HDT cannot say what is on it - and it therefore
        #            cannot say the disk is empty. An unreadable target is an
        #            ambiguous one, and PROJECT constraint 6 is to refuse an
        #            ambiguous target rather than assume it is expendable.
        #
        # A LETTERED PARTITION WHOSE VOLUME HAS NO FILE SYSTEM IS NEITHER OF
        # THEM. That one HDT did read, and what it read was an unformatted
        # volume: not existing data. Counting it would make rule 5 stricter than
        # DESIGN states it, in the one direction nobody would notice - a refusal
        # on an empty disk reads exactly like the guard working.
        #
        # A LETTERED PARTITION WITH NO VOLUME ROW AT ALL is left out of both as
        # well. On real hardware a lettered partition always has a Get-Volume
        # row - an unformatted one reports an empty FileSystem rather than
        # vanishing - so that shape is a fake that lies rather than a disk that
        # hides something, and the answer to it is to fix the fake.
        $letter = @()
        $data = @()
        $opaque = @()

        foreach ($row in $partitionRow) {
            if ([int] $row.DiskNumber -ne $number) { continue }

            $text = ([string] $row.DriveLetter).Trim().TrimEnd(':')

            if ($text.Length -eq 0) {
                # Named by what it HAS, because it has no letter to be named by.
                # An administrator reading this a week later has to be able to
                # find the partition the refusal is about, and the number, the
                # size and the type are what diskpart will show them.
                $opaque += ('partition {0} ({1} bytes, {2}, no drive letter)' -f
                    [int] $row.PartitionNumber, [long] $row.SizeBytes, ([string] $row.Type).Trim())
                continue
            }

            $normalised = $text.Substring(0, 1).ToUpperInvariant()
            $letter += $normalised

            foreach ($item in $volumeRow) {
                $volumeText = ([string] $item.DriveLetter).Trim().TrimEnd(':')
                if ($volumeText.Length -eq 0) { continue }
                if ($volumeText.Substring(0, 1).ToUpperInvariant() -ne $normalised) { continue }
                if ([string]::IsNullOrWhiteSpace([string] $item.FileSystem)) { continue }

                $data += ('{0} ({1})' -f $normalised, [string] $item.FileSystem)
            }
        }

        $reason = New-Object -TypeName System.Collections.ArrayList

        # 1 - the disk this machine is running from. Never overridable.
        if ($current.IsSystem -or $current.IsBoot) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} is the disk this machine booted from' -f $number)
                })
        }

        # 2 - the disk the deployment is reading from. Never overridable.
        $held = @($letter | Where-Object { $protected -contains $_ })
        if ($held.Count -gt 0) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} holds drive letter {1}, which this deployment is reading from or writing to' -f $number, ($held -join ', '))
                })
        }

        # 3 - a disk that cannot be written.
        if ($current.IsReadOnly) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} is read-only' -f $number)
                })
        }

        # 4 - IDiskService has no way to bring a disk online, and pretending
        #     otherwise fails later and less clearly.
        if ($current.IsOffline) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} is offline, and HDT cannot bring a disk online' -f $number)
                })
        }

        # 5 - existing data. Declared away by the sequence, not by the number.
        #
        # STILL OVERRIDABLE BY wipe: true, for both halves. The unreadable half
        # is a refusal to guess, not a new absolute - a sequence that has said
        # the target's contents are expendable has answered the question this
        # rule is asking, whether or not HDT could read what it was replacing.
        #
        # AND STILL NOT A RAW DISK. A disk with no partition table carries no
        # partitions, so neither list can fill; the guard stays as a second
        # statement of the same thing, in the place a reader looks for it.
        $carried = @()
        if ($data.Count -gt 0) { $carried += ('volume {0}' -f ($data -join ', ')) }
        if ($opaque.Count -gt 0) {
            $partitionWord = 'partitions'
            if ($opaque.Count -eq 1) { $partitionWord = 'a partition' }

            $carried += ('{0} HDT cannot read, because a volume with no access path is not one it can list: {1}' -f
                $partitionWord, ($opaque -join ', '))
        }

        if ((([string] $current.PartitionStyle) -ne 'RAW') -and ($carried.Count -gt 0) -and -not $AllowExistingData) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} carries existing data on {1}, and the step did not declare that it may be replaced' -f $number, ($carried -join ', and '))
                })
        }

        # 6 - the stick the technician booted from, "in range" (DESIGN 9.1).
        if ((([string] $current.BusType).Trim()) -eq 'USB') {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $false
                    Text     = ('disk {0} is a USB disk' -f $number)
                })
        }

        # 7 - too small to hold Windows.
        if ([long] $current.SizeBytes -lt $MinimumSizeByte) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $false
                    Text     = ('disk {0} is {1} bytes, under the minimum of {2} bytes' -f $number, [long] $current.SizeBytes, $MinimumSizeByte)
                })
        }

        [void] $assessment.Add([pscustomobject] @{
                Number = $number
                Row    = $current
                Letter = [string[]] @($letter)
                Data   = [string[]] @($data)
                # THE UNREADABLE PARTITIONS ARE CARRIED OUT, not just folded
                # into the refusal text, because Validate prints this table on
                # the run that did NOT refuse. "no volumes" against a disk with
                # four unlettered partitions on it is the pre-flight saying the
                # disk is empty, which is the sentence this whole rule exists to
                # stop HDT from saying.
                Opaque = [string[]] @($opaque)
                Reason = [object[]] @($reason)
            })
    }

    return [pscustomobject[]] @($assessment)
}
