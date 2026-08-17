function Add-HDTStepPartition {
    <#
        .SYNOPSIS
            Adds a partition to a DiskPartition step's table.

        .DESCRIPTION
            MDT'S "New" ON THE Format and Partition Disk DIALOG. The console may
            not do anything the cmdlets cannot, so the grid's yellow star is
            this command and the window is its face.

            IT APPENDS, BECAUSE ORDER IS THE ON-DISK ORDER, and takes -First for
            the case that matters: an ESP added after Windows is a disk that
            does not boot, and a command that could only append would need a
            move straight afterwards every time.

            IT REFUSES A SIZE THE ENGINE CANNOT READ, at the moment it is typed
            rather than at the disk. ConvertTo-HDTDiskLayout makes the same
            refusal when the step runs; making it here means the mistake is
            found by the person who made it instead of by whoever is standing at
            the machine.

            IT SPLICES LINES. A parse and re-emit would hand back a correct
            document and none of the comments an administrator wrote beside
            their partitions.

        .PARAMETER Line
            The sequence document's lines. Returned spliced.

        .PARAMETER Name
            The step to add to.

        .PARAMETER Partition
            The new partition's name.

        .PARAMETER Type
            EFI, Primary or Recovery.

        .PARAMETER Size
            260MB, 1GB, 60%, remainder, or a number of bytes.

        .PARAMETER FileSystem
            NTFS or FAT32. Omitted, the engine's default for the type - FAT32
            for an ESP and NTFS for everything else.

        .PARAMETER Variable
            A variable to publish the resulting drive letter into, which is
            MDT's VolumeLetterVariable.

        .PARAMETER First
            Put it at the top of the table instead of the bottom.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            $line = Add-HDTStepPartition -Line $line -Name 'Format and Partition' `
                -Partition 'Data' -Type Primary -Size 'remainder'

        .EXAMPLE
            Add-HDTStepPartition -Line $line -Name 'Format and Partition' `
                -Partition 'System' -Type EFI -Size 260MB -First
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Partition,

        [Parameter(Mandatory = $true, Position = 3)]
        [ValidateSet('EFI', 'Primary', 'Recovery')]
        [string] $Type,

        [Parameter(Mandatory = $true, Position = 4)]
        [ValidateNotNullOrEmpty()]
        [string] $Size,

        [Parameter()]
        [ValidateSet('NTFS', 'FAT32')]
        [string] $FileSystem,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Variable,

        # A BOOLEAN AND NOT A SWITCH, because unspecified and false are
        # different answers. The engine formats quick and makes the first
        # partition bootable when nothing says otherwise, so a row that means
        # "not this one" has to be able to say it out loud - and a switch can
        # only ever say yes.
        [Parameter()]
        [bool] $QuickFormat,

        [Parameter()]
        [bool] $Bootable,

        [Parameter()]
        [switch] $First
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name
    $key = Get-HDTStepKey -Line $Line -Block $target -Key 'partition'

    if ([int] $key.Index -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidOperation `
                    -Message ("step '{0}' has no partition table - it names a layout instead. A step may name a layout or write its own partitions, and swapping one for the other is a decision to make deliberately rather than as a side effect of adding a row." -f $Name)))
    }

    # THE SAME REFUSAL THE BUILD MAKES, MADE EARLIER. Anything this accepts,
    # ConvertTo-HDTDiskLayout has to accept later.
    [void] (ConvertTo-HDTDiskLayout -Style GPT -Partition @(
            @{ name = $Partition; type = $Type; size = $Size }))

    if (-not $PSCmdlet.ShouldProcess($Name, ("Add partition '{0}'" -f $Partition))) {
        return [string[]] @($Line)
    }

    $existing = @(Get-HDTStepPartitionItem -Line $Line -Block $target)

    # THE COLUMN THE EXISTING ROWS SIT AT, so an insert lines up with them. With
    # no rows to copy, two spaces in from the key is what every other list in
    # these documents uses.
    $indent = [int] $key.Indent + 2
    if (@($existing).Count -gt 0) { $indent = [int] $existing[0].Indent }

    $pad = ' ' * $indent
    $inner = ' ' * ($indent + 2)

    $written = New-Object -TypeName System.Collections.ArrayList
    [void] $written.Add(('{0}- name: {1}' -f $pad, (Get-HDTConsoleScalarText -Value $Partition)))
    [void] $written.Add(('{0}type: {1}' -f $inner, $Type))
    [void] $written.Add(('{0}size: {1}' -f $inner, (Get-HDTConsoleScalarText -Value $Size)))

    if (-not [string]::IsNullOrWhiteSpace($FileSystem)) {
        [void] $written.Add(('{0}filesystem: {1}' -f $inner, $FileSystem))
    }

    if (-not [string]::IsNullOrWhiteSpace($Variable)) {
        [void] $written.Add(('{0}variable: {1}' -f $inner, (Get-HDTConsoleScalarText -Value $Variable)))
    }

    # NAMED OR ABSENT, never "the default written out". A document that repeats
    # the engine's own defaults on every row is a document that will disagree
    # with the engine the day one of them changes.
    if ($PSBoundParameters.ContainsKey('QuickFormat')) {
        [void] $written.Add(('{0}quickFormat: {1}' -f $inner, $QuickFormat.ToString().ToLowerInvariant()))
    }

    if ($PSBoundParameters.ContainsKey('Bootable')) {
        [void] $written.Add(('{0}bootable: {1}' -f $inner, $Bootable.ToString().ToLowerInvariant()))
    }

    # WHERE IT GOES: after the key for the first row, after the last row's last
    # line otherwise, and directly after the key when -First.
    $at = [int] $key.Index + 1

    if (-not $First -and @($existing).Count -gt 0) {
        $at = [int] $existing[@($existing).Count - 1].End + 1
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($index = 0; $index -lt @($Line).Count; $index++) {
        if ($index -eq $at) {
            foreach ($row in $written) { [void] $result.Add($row) }
        }

        [void] $result.Add([string] $Line[$index])
    }

    if ($at -ge @($Line).Count) {
        foreach ($row in $written) { [void] $result.Add($row) }
    }

    # AND THE TABLE THAT CAME OUT, not just the row that went in. Two bootable
    # partitions, two claiming the remainder, percentages past a hundred - none
    # of those can be seen from one row.
    Assert-HDTStepPartitionTable -Line ([string[]] @($result)) -Name $Name

    return [string[]] @($result)
}
