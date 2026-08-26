function Get-HDTConsolePartitionSizeText {
    <#
        .SYNOPSIS
            A built-in layout's partition size, written the way an author would
            have written it.

        .DESCRIPTION
            THE GRID SHOWS A NAMED LAYOUT'S VOLUMES BESIDE AUTHORED ONES, and
            the two have to read the same. An authored row says 260MB;
            uefi-standard says 272629760 bytes, which is the same disk described
            in a way nobody can compare at a glance.

            A SIZE OF ZERO IS THE REMAINDER, which is how the built-ins say "what
            is left after everybody else" - the planner reads it that way and so
            does this.

            IT ROUNDS TO THE LARGEST UNIT THAT DIVIDES EXACTLY, so 272629760
            becomes 260MB rather than 0.25GB. A size that does not divide evenly
            keeps its bytes rather than being shown as an approximation the disk
            will not match.

        .PARAMETER Partition
            One partition from Get-HDTDiskLayout.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsolePartitionSizeText -Partition (Get-HDTDiskLayout -Name uefi-standard).Partition[0]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Partition
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $byte = 0
    if ($null -ne $Partition.PSObject.Properties['SizeByte']) { $byte = [long] $Partition.SizeByte }

    if ($byte -le 0) { return 'remainder' }

    foreach ($unit in @(
            @{ Name = 'TB'; Size = 1TB }
            @{ Name = 'GB'; Size = 1GB }
            @{ Name = 'MB'; Size = 1MB }
            @{ Name = 'KB'; Size = 1KB }
        )) {

        if ($byte % [long] $unit.Size -eq 0) {
            return ('{0}{1}' -f ($byte / [long] $unit.Size), $unit.Name)
        }
    }

    return [string] $byte
}
