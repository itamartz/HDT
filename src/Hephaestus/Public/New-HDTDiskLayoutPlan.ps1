function New-HDTDiskLayoutPlan {
    <#
        .SYNOPSIS
            Turns a named disk layout and a disk size into the exact partitions
            to create.

        .DESCRIPTION
            The arithmetic, which is the whole point of the function. A layout
            says "Windows takes the remainder"; only a plan says how many bytes
            that is on this disk, and it has to be right before anything
            destructive runs against it.

              uefi-standard
                windows = DiskSizeByte - 260MB(ESP) - 16MB(MSR) - 1GB(recovery)
                                       - 1MB(alignment)
                the recovery row carries UseMaximumSize, so the slack lands there

              bios-standard
                windows = UseMaximumSize after a 500MB system partition

            THE 16 MB IS SUBTRACTED AND NEVER PLANNED.
            Initialize-Disk -PartitionStyle GPT creates the Microsoft Reserved
            partition itself. A plan that also created one produces a duplicate;
            a plan that forgot to subtract it sizes Windows 16 MB too large and
            the last partition does not fit. Both failures are silent until a
            real disk is in front of you, which is why the allowance is data on
            the layout rather than a number in this function.

            A DISK TOO SMALL IS A POINTED REFUSAL, NOT A PLAN WITH A NEGATIVE
            PARTITION IN IT. The message names the disk size and the shortfall,
            because "the disk is too small" without a number is a message that
            sends a technician to measure the disk by hand.

            It performs no I/O, takes no service and returns new rows: the layout
            it was handed is not modified, so the same layout object plans twice.

        .PARAMETER Layout
            A layout as Get-HDTDiskLayout returns it.

        .PARAMETER DiskSizeByte
            The size of the disk being planned, from IDiskService's disk row.

        .PARAMETER MinimumWindowsSizeByte
            The smallest Windows partition worth creating. Defaults to 20 GB.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - ordered rows carrying
            Order, Role, SizeByte, UseMaximumSize, FileSystem, Label,
            DriveLetter, GptType, CreateGptType and IsActive.

        .EXAMPLE
            New-HDTDiskLayoutPlan -Layout (Get-HDTDiskLayout -Name uefi-standard) -DiskSizeByte 68719476736

            The plan a 64 GiB lab VM gets: ESP 260 MB, Windows, recovery last.

        .EXAMPLE
            New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte $disk.SizeBytes -MinimumWindowsSizeByte 40GB

            A tighter floor, for a build that will not fit in 20 GB.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory plan; it creates no partition and changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Layout,

        [Parameter(Mandatory = $true, Position = 1)]
        [long] $DiskSizeByte,

        [Parameter()]
        [long] $MinimumWindowsSizeByte = 21474836480
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $row = @($Layout.Partition)

    # Everything that is not Windows takes its declared size, whatever it is
    # eventually created with. The recovery row declares 1 GB AND carries
    # UseMaximumSize: the declared size is what Windows must leave behind, and
    # the flag is what makes the slack land in recovery rather than unallocated.
    $claimed = [long] 0
    foreach ($current in $row) {
        if ($current.Role -eq 'Windows') { continue }
        $claimed += [long] $current.SizeByte
    }

    $overhead = $claimed + [long] $Layout.ReservedSizeByte + [long] $Layout.AlignmentSizeByte
    $windowsSizeByte = [long] $DiskSizeByte - $overhead

    if ($windowsSizeByte -lt $MinimumWindowsSizeByte) {
        $shortfall = $MinimumWindowsSizeByte - $windowsSizeByte

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Layout.Name `
                    -Message ("disk layout '{0}' does not fit on a disk of {1} bytes: after {2} bytes of system, reserved and recovery space, Windows would get {3} bytes, which is {4} bytes short of the {5} byte minimum." -f
                        $Layout.Name, $DiskSizeByte, $overhead, $windowsSizeByte, $shortfall, $MinimumWindowsSizeByte)))
    }

    $plan = New-Object -TypeName System.Collections.ArrayList
    $order = 0

    foreach ($current in $row) {
        $order++

        $sizeByte = [long] $current.SizeByte
        if ($current.Role -eq 'Windows') { $sizeByte = $windowsSizeByte }

        [void] $plan.Add([pscustomobject] @{
                Order          = $order
                Role           = [string] $current.Role
                SizeByte       = $sizeByte
                UseMaximumSize = [bool] $current.UseMaximumSize
                FileSystem     = [string] $current.FileSystem
                Label          = [string] $current.Label
                DriveLetter    = [string] $current.DriveLetter
                GptType        = [string] $current.GptType
                CreateGptType  = [string] $current.CreateGptType
                IsActive       = [bool] $current.IsActive
            })
    }

    return [pscustomobject[]] @($plan)
}
