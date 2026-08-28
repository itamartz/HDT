function Remove-HDTStepPartition {
    <#
        .SYNOPSIS
            Removes a partition from a DiskPartition step's table.

        .DESCRIPTION
            Drops one volume from the layout a DiskPartition step declares,
            leaving the rest of the table in the order it was already in.

            IT TAKES THE COMMENTS WITH IT. A note written above a partition is
            about that partition; leaving it behind would attach it to whichever
            row moved up into its place.

            IT REFUSES TO REMOVE THE LAST ONE. A DiskPartition step with an
            empty table is not a layout, and ConvertTo-HDTDiskLayout refuses one
            at build time - so refusing here means the document never reaches a
            state the engine cannot run.

        .PARAMETER Line
            The sequence document's lines. Returned spliced.

        .PARAMETER Name
            The step to remove from.

        .PARAMETER Partition
            The partition's name.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document's lines, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'))
            $line = Remove-HDTStepPartition -Line $line -Name 'Format and Partition Disk (UEFI)' -Partition 'Data'
            Save-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml' -Line $line

            Drops one volume from a partition step's layout.

        .EXAMPLE
            @($line | Where-Object { $_ -match '^\s*- name:' })

            What the disk will be laid out as now. The step keeps its own name, its
            condition and everything else it declared.

    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
        [string] $Partition
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

    if (@($item).Count -le 1) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Partition -Category InvalidOperation `
                    -Message ("'{0}' is the last partition in step '{1}', and a step with an empty table is not a layout - the build refuses one. Remove the step, or give it a layout instead." -f
                        $Partition, $Name)))
    }

    if (-not $PSCmdlet.ShouldProcess($Name, ("Remove partition '{0}'" -f $Partition))) {
        return [string[]] @($Line)
    }

    $gone = $found[0]
    $result = New-Object -TypeName System.Collections.ArrayList

    for ($index = 0; $index -lt @($Line).Count; $index++) {
        if ($index -ge [int] $gone.Start -and $index -le [int] $gone.End) { continue }

        [void] $result.Add([string] $Line[$index])
    }

    return [string[]] @($result)
}
