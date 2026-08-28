function Set-HDTStepPartition {
    <#
        .SYNOPSIS
            Rewrites one row of a DiskPartition step's table.

        .DESCRIPTION
            REWRITES ONE VOLUME WHERE IT STANDS, and it is the one table edit
            that cannot be built out of the others: Delete and Add again would
            move the row to the bottom of the table, which is a change to the
            disk rather than to the volume.

            IT WRITES THE WHOLE ROW, not the keys that were named. That is what
            the dialog does - every field is on screen and OK writes all of them
            - and it is the only rule that makes the result predictable: a merge
            would leave a filesystem behind that the person editing had just
            cleared, and no combination of parameters could clear it again.

            SO THE CALLER SUPPLIES THE WHOLE ROW. The console fills every box
            from the row before anybody edits one, which is why nothing is lost
            by this being a replacement.

            IT KEEPS THE ROW'S PLACE AND ITS COMMENTS. The position is the
            position on the disk, and a note written above a volume is about
            that volume.

            IT MAKES THE SAME REFUSAL THE BUILD MAKES, at the moment the value
            is typed - ConvertTo-HDTDiskLayout is asked first, so anything this
            accepts is something the engine will accept later.

        .PARAMETER Line
            The sequence document's lines. Returned spliced.

        .PARAMETER Name
            The step whose table is being edited.

        .PARAMETER Partition
            The row to rewrite, by its current name.

        .PARAMETER NewName
            What to call it now. Omitted, it keeps the name it has.

        .PARAMETER Type
            EFI, Primary or Recovery.

        .PARAMETER Size
            260MB, 1GB, 60%, remainder, or a number of bytes.

        .PARAMETER FileSystem
            NTFS or FAT32. Omitted, the row is written without one and the
            engine's default for the type applies.

        .PARAMETER Variable
            A variable to publish the drive letter into, which is MDT's
            VolumeLetterVariable. Omitted, the row is written without one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            $line = Set-HDTStepPartition -Line $line -Name 'Format and Partition' `
                -Partition 'Windows' -Type Primary -Size '70%' -FileSystem NTFS -Variable HDTOSVolume

        .EXAMPLE
            Set-HDTStepPartition -Line $line -Name 'Format and Partition' `
                -Partition 'Data' -NewName 'Scratch' -Type Primary -Size remainder
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
        [ValidateNotNullOrEmpty()]
        [string] $NewName,

        [Parameter()]
        [ValidateSet('NTFS', 'FAT32')]
        [string] $FileSystem,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Variable,

        # Booleans rather than switches, for the reason Add gives: unspecified
        # and false are different answers, and a switch can only say yes.
        [Parameter()]
        [bool] $QuickFormat,

        [Parameter()]
        [bool] $Bootable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name
    $item = @(Get-HDTStepPartitionItem -Line $Line -Block $target)

    $found = @($item | Where-Object { $_.Name -eq $Partition })

    if (@($found).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Partition -Category ObjectNotFound `
                    -Message ("step '{0}' has no partition called '{1}'. It has: {2}" -f
                        $Name, $Partition, ((@($item | ForEach-Object { $_.Name })) -join ', '))))
    }

    $written = $Partition
    if (-not [string]::IsNullOrWhiteSpace($NewName)) { $written = $NewName }

    # THE SAME REFUSAL THE BUILD MAKES, MADE EARLIER.
    [void] (ConvertTo-HDTDiskLayout -Style GPT -Partition @(
            @{ name = $written; type = $Type; size = $Size }))

    if (-not $PSCmdlet.ShouldProcess($Name, ("Edit partition '{0}'" -f $Partition))) {
        return [string[]] @($Line)
    }

    $row = $found[0]

    $indent = [int] $row.Indent
    $pad = ' ' * $indent
    $inner = ' ' * ($indent + 2)

    $replacement = New-Object -TypeName System.Collections.ArrayList
    [void] $replacement.Add(('{0}- name: {1}' -f $pad, (Get-HDTConsoleScalarText -Value $written)))
    [void] $replacement.Add(('{0}type: {1}' -f $inner, $Type))
    [void] $replacement.Add(('{0}size: {1}' -f $inner, (Get-HDTConsoleScalarText -Value $Size)))

    if (-not [string]::IsNullOrWhiteSpace($FileSystem)) {
        [void] $replacement.Add(('{0}filesystem: {1}' -f $inner, $FileSystem))
    }

    if (-not [string]::IsNullOrWhiteSpace($Variable)) {
        [void] $replacement.Add(('{0}variable: {1}' -f $inner, (Get-HDTConsoleScalarText -Value $Variable)))
    }

    if ($PSBoundParameters.ContainsKey('QuickFormat')) {
        [void] $replacement.Add(('{0}quickFormat: {1}' -f $inner, $QuickFormat.ToString().ToLowerInvariant()))
    }

    if ($PSBoundParameters.ContainsKey('Bootable')) {
        [void] $replacement.Add(('{0}bootable: {1}' -f $inner, $Bootable.ToString().ToLowerInvariant()))
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($index = 0; $index -lt @($Line).Count; $index++) {

        # THE COMMENTS ABOVE IT SURVIVE: Start is the first of them, Index is the
        # dash. Only the keys between Index and End are replaced.
        if ($index -ge [int] $row.Index -and $index -le [int] $row.End) {
            if ($index -eq [int] $row.Index) {
                foreach ($put in $replacement) { [void] $result.Add($put) }
            }

            continue
        }

        [void] $result.Add([string] $Line[$index])
    }

    # AND THE TABLE THAT CAME OUT, for the reason Add gives: the refusals that
    # matter most are about how the rows relate to each other.
    Assert-HDTStepPartitionTable -Line ([string[]] @($result)) -Name $Name

    return [string[]] @($result)
}
