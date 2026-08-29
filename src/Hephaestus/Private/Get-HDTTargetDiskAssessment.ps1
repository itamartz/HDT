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
            returns them. Used to learn which drive letters a disk carries;
            omitted, no disk carries any.

        .PARAMETER Volume
            Every lettered volume, as IDiskService.GetVolume() returns them.
            Used with -Partition to learn whether a disk carries a file system.

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
            Letter, Data and Reason. Reason is a list of Absolute/Text pairs and
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

        $letter = @()
        foreach ($row in $partitionRow) {
            if ([int] $row.DiskNumber -ne $number) { continue }

            $text = ([string] $row.DriveLetter).Trim().TrimEnd(':')
            if ($text.Length -gt 0) { $letter += $text.Substring(0, 1).ToUpperInvariant() }
        }

        $data = @()
        foreach ($row in $volumeRow) {
            $text = ([string] $row.DriveLetter).Trim().TrimEnd(':')
            if ($text.Length -eq 0) { continue }

            $normalised = $text.Substring(0, 1).ToUpperInvariant()
            if ($letter -notcontains $normalised) { continue }
            if ([string]::IsNullOrWhiteSpace([string] $row.FileSystem)) { continue }

            $data += ('{0} ({1})' -f $normalised, [string] $row.FileSystem)
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
        if ((([string] $current.PartitionStyle) -ne 'RAW') -and ($data.Count -gt 0) -and -not $AllowExistingData) {
            [void] $reason.Add([pscustomobject] @{
                    Absolute = $true
                    Text     = ('disk {0} carries existing data on volume {1}, and the step did not declare that it may be replaced' -f $number, ($data -join ', '))
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
                Reason = [object[]] @($reason)
            })
    }

    return [pscustomobject[]] @($assessment)
}
