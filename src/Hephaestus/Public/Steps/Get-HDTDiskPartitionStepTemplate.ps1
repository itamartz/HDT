function Get-HDTDiskPartitionStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new DiskPartition step, with the disk left unset.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE TEMPLATE REFUSES TO NAME A DISK, AND THAT IS THE WHOLE POINT OF
            IT. This is the step that wipes a machine. HDT's rule is that it must
            not guess which disk to wipe, and a template that wrote diskNumber: 0
            would be that guess, made once, in a file every future step of this
            type is copied from - on a machine whose disk 0 is not always the
            target. So the key ships as a comment: the step is visibly incomplete
            until an author supplies it, and the step itself refuses at run time
            if they did not.

            wipe: true IS SAFE TO WRITE because it cannot act on its own. Without
            a diskNumber there is nothing to wipe, so the pair is inert until the
            author has made the destructive decision explicitly.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTDiskPartitionStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Format and Partition Disk'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: DiskPartition'
        '  # diskNumber: the disk to wipe. HDT will not guess it - set it before'
        '  # this sequence is run, or the step refuses.'
        '  layout: UEFI'
        '  wipe: true'
    )
}
