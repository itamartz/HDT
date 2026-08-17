function Move-HDTStepPartition {
    <#
        .SYNOPSIS
            Moves a partition one place up or down a step's table.

        .DESCRIPTION
            THE UP AND DOWN ARROWS ON MDT'S Format and Partition Disk DIALOG,
            and they are not decoration: the order of the table is the order on
            the disk. An ESP below Windows is a disk that does not boot.

            IT MOVES ONE PLACE, NOT TO A POSITION, which is what an arrow beside
            a list means and what composes - pressing it twice moves a row two
            places.

            AT THE END IT DOES NOTHING, AND THAT IS NOT AN ERROR. The arrow is
            pressed by somebody walking a row up several places; refusing at the
            top would put a message on screen for a press that had nowhere to
            go.

            THE WHOLE ENTRY MOVES, comments included, for the same reason Remove
            takes them with it: a note above a partition is about that
            partition.

        .PARAMETER Line
            The sequence document's lines. Returned spliced.

        .PARAMETER Name
            The step whose table is being reordered.

        .PARAMETER Partition
            The partition to move.

        .PARAMETER Direction
            Up or Down, one place.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            Move-HDTStepPartition -Line $line -Name 'Format and Partition' -Partition 'System' -Direction Up
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
        [ValidateSet('Up', 'Down')]
        [string] $Direction
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name
    $item = @(Get-HDTStepPartitionItem -Line $Line -Block $target)

    $at = -1
    for ($index = 0; $index -lt @($item).Count; $index++) {
        if ($item[$index].Name -eq $Partition) { $at = $index; break }
    }

    if ($at -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Partition -Category ObjectNotFound `
                    -Message ("step '{0}' has no partition called '{1}', so there is nothing to move." -f $Name, $Partition)))
    }

    $other = $at - 1
    if ($Direction -eq 'Down') { $other = $at + 1 }

    if ($other -lt 0 -or $other -ge @($item).Count) { return [string[]] @($Line) }

    if (-not $PSCmdlet.ShouldProcess($Name, ("Move partition '{0}' {1}" -f $Partition, $Direction.ToLowerInvariant()))) {
        return [string[]] @($Line)
    }

    # In document order, whichever way the move was asked for: the splice walks
    # the file forwards and has to meet the earlier one first.
    $first = $item[$at]
    $second = $item[$other]

    if ([int] $first.Start -gt [int] $second.Start) {
        $first = $item[$other]
        $second = $item[$at]
    }

    $result = New-Object -TypeName System.Collections.ArrayList
    $index = 0

    while ($index -lt @($Line).Count) {

        if ($index -ne [int] $first.Start) {
            [void] $result.Add([string] $Line[$index])
            $index++
            continue
        }

        for ($take = [int] $second.Start; $take -le [int] $second.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = [int] $first.End + 1; $take -lt [int] $second.Start; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        for ($take = [int] $first.Start; $take -le [int] $first.End; $take++) {
            [void] $result.Add([string] $Line[$take])
        }

        $index = [int] $second.End + 1
    }

    return [string[]] @($result)
}
