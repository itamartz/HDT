function Select-HDTTargetDisk {
    <#
        .SYNOPSIS
            Chooses the one disk a deployment may wipe, or refuses to choose.

        .DESCRIPTION
            The engine refuses to guess when the disk is unexpected
            (multiple disks, existing data volumes, USB source disk in range).
            DiskPartition requires either an unambiguous target or an explicit
            diskNumber. Wiping the wrong disk is the single most destructive
            failure mode in this class of tool."

            This is that refusal, as pure logic over the three flat listings
            IDiskService returns. It touches no hardware, opens no handle and
            takes no service: it is handed rows and returns one of them, so
            every rule below is provable under Pester with no disk attached.

            SEVEN EXCLUSION RULES, IN TWO CLASSES. Every rule is evaluated for
            every disk and its reason is recorded, so a refusal can print the
            whole table rather than a verdict a technician cannot act on.

              #  Rule                          Excludes                        -DiskNumber
              1  IsSystem or IsBoot            the disk this machine runs from  NEVER
              2  holds a protected letter      the disk carrying the workspace  NEVER
              3  IsReadOnly                    a disk that cannot be written    NEVER
              4  IsOffline                     a disk HDT cannot online         NEVER
              5  existing data                 a disk with a file system on it  no
              6  BusType USB                   the stick the technician booted  yes, warned
              7  under the minimum size        too small to hold Windows        yes, warned

            RULE 1 IS ABSOLUTE ON PURPOSE. The alternative - trusting the
            diskNumber an author typed - means one wrong number in a YAML file
            destroys the machine running the sequence, which on a developer's
            workstation is the developer's workstation. This host's own captured
            row is a fixture in the suite for exactly that reason.

            RULE 2 IS RULE 1 FOR THE SHARE. DiskPartition passes the drive
            letters of the workspace root and the log path, so HDT cannot wipe
            the disk it is reading its own instructions from.

            RULE 5 IS OVERRIDDEN BY THE SEQUENCE, NOT BY THE NUMBER. A disk with
            data on it is used when the step declares it, which reaches here as
            -AllowExistingData. Naming the disk explicitly is not the same
            statement as declaring that its contents are expendable.

            NO RULE FILTERS ON BUS TYPE EXPECTING A VIRTUAL VALUE. SPIKES S6: a
            Generation 2 VM's own system disk reports BusType = SAS, not SCSI
            and not Virtual. USB is the only bus type that excludes anything.

            The three refusals carry their own error ids -
            HDTAmbiguousTargetError, HDTUnsafeTargetError and
            HDTNoTargetDiskError - and Get-HDTFailureClass classifies all three
            as Configuration, so a refusal to wipe ends the run instead of being
            retried three times.

        .PARAMETER Disk
            Every disk on the machine, as IDiskService.GetDisk() returns them.
            An empty collection is a refusal, not a crash.

        .PARAMETER Partition
            Every partition on every disk, as IDiskService.GetPartition()
            returns them. Used to learn which drive letters a disk carries;
            omitted, no disk carries any.

        .PARAMETER Volume
            Every lettered volume, as IDiskService.GetVolume() returns them.
            Used with -Partition to learn whether a disk carries a file system.

        .PARAMETER DiskNumber
            The disk the sequence named. Overrides rules 6 and 7 with a warning
            and never overrides rules 1 to 5.

        .PARAMETER MinimumSizeByte
            The smallest disk that can hold Windows. Defaults to 60 GB.

        .PARAMETER ProtectDriveLetter
            Drive letters the deployment is reading from or writing to. A disk
            carrying one of them is never the target. Matched
            case-insensitively, with or without a colon.

        .PARAMETER AllowExistingData
            The sequence declared that the target's contents are expendable.
            Without it, a disk carrying a formatted volume is excluded.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the single disk row.

        .EXAMPLE
            Select-HDTTargetDisk -Disk $disk -Partition $partition -Volume $volume

            The unattended case: exactly one disk qualifies, or the run stops.

        .EXAMPLE
            Select-HDTTargetDisk -Disk $disk -DiskNumber 1 -AllowExistingData

            The authored case: the sequence names the disk and declares that
            wiping it is intended.

        .EXAMPLE
            Select-HDTTargetDisk -Disk $disk -ProtectDriveLetter 'X', 'Z'

            WinPE's scratch space and the mapped deployment share, kept out of
            range of the thing that formats disks.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
        [int] $DiskNumber,

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

    # -- one pass, a reason per disk ------------------------------------------

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
                Reason = [object[]] @($reason)
            })
    }

    $presentNumber = [int[]] @($assessment | ForEach-Object { $_.Number })

    # -- the sequence named a disk --------------------------------------------

    if ($PSBoundParameters.ContainsKey('DiskNumber')) {

        $named = @($assessment | Where-Object { $_.Number -eq $DiskNumber })

        if ($named.Count -eq 0) {
            $present = 'none'
            if ($presentNumber.Count -gt 0) { $present = ($presentNumber -join ', ') }

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTConfigurationError' `
                        -TargetObject $DiskNumber -Category InvalidArgument `
                        -Message ('diskNumber {0} does not exist on this machine. The disk numbers present are {1}.' -f $DiskNumber, $present)))
        }

        if ($named.Count -gt 1) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTAmbiguousTargetError' `
                        -TargetObject $DiskNumber -Category InvalidResult `
                        -Message ('{0} disks report the number {1}, so naming it does not identify one. HDT will not guess which to wipe.' -f $named.Count, $DiskNumber)))
        }

        $absolute = @($named[0].Reason | Where-Object { $_.Absolute })
        if ($absolute.Count -gt 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTUnsafeTargetError' `
                        -TargetObject $DiskNumber -Category InvalidOperation `
                        -Message ('diskNumber {0} cannot be the deployment target: {1}. This rule is not overridable by naming the disk.' -f $DiskNumber, $absolute[0].Text)))
        }

        foreach ($warned in @($named[0].Reason)) {
            Write-Warning ('{0}, and was used anyway because the sequence named it.' -f $warned.Text)
        }

        return $named[0].Row
    }

    # -- nobody named a disk --------------------------------------------------

    if ($assessment.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTNoTargetDiskError' `
                    -TargetObject ([int[]] @()) -Category ObjectNotFound `
                    -Message 'this machine reports no disk at all, so there is nothing to deploy to. Check that the boot image carries a storage driver for this controller.'))
    }

    $candidate = @($assessment | Where-Object { @($_.Reason).Count -eq 0 })

    if ($candidate.Count -eq 1) {
        return $candidate[0].Row
    }

    if ($candidate.Count -eq 0) {
        $line = foreach ($entry in $assessment) {
            '  - {0}' -f (@($entry.Reason | ForEach-Object { $_.Text }) -join '; ')
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTNoTargetDiskError' `
                    -TargetObject $presentNumber -Category ObjectNotFound `
                    -Message ("no disk on this machine can be used as the deployment target:{0}{1}" -f [System.Environment]::NewLine, (@($line) -join [System.Environment]::NewLine))))
    }

    # This is the sentence that stops a toolkit from wiping a technician's
    # second drive.
    $candidateNumber = [int[]] @($candidate | ForEach-Object { $_.Number })
    $named = (@($candidateNumber | ForEach-Object { 'disk {0}' -f $_ }) -join ', ')

    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTAmbiguousTargetError' `
                -TargetObject $candidateNumber -Category InvalidResult `
                -Message ('{0} disks qualify as the deployment target ({1}), and HDT will not guess which one to wipe. Set diskNumber: on the step to name the one to use.' -f $candidate.Count, $named)))
}
