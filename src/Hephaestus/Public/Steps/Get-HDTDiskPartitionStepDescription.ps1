function Get-HDTDiskPartitionStepDescription {
    <#
        .SYNOPSIS
            Describes a DiskPartition step by the layout it will apply.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the step that
            destroys a disk, so the line a technician sees on the progress
            display names the layout and, where the sequence pinned one, the disk
            number - the two facts that decide what is about to be lost.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTDiskPartitionStepDescription -Step $step
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $layout = [string] (Get-HDTStepProperty -Step $Step -Name 'layout' -Default 'the layout the firmware selects')
    $number = Get-HDTStepProperty -Step $Step -Name 'diskNumber'

    if ($null -eq $number) {
        return ('Partition: the one unambiguous target disk, as {0}' -f $layout)
    }

    return ('Partition: disk {0}, as {1}' -f $number, $layout)
}
