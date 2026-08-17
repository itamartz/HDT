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

            IT COMES IN TWO, AS MDT'S OWN SEQUENCE DOES. The Standard Client task
            sequence carries "Format and Partition Disk (BIOS)" and "(UEFI)",
            each conditioned on the firmware, because the two disks are laid out
            differently and one sequence has to deploy to both kinds of machine.
            Writing one step and leaving the author to add the condition is how
            a sequence comes to lay a GPT disk out on a BIOS machine - which
            fails after the image is applied rather than in the first minute.

            THE CONDITION IS THE ENGINE'S OWN VARIABLE. HDTIsUEFI is gathered
            before any step runs and is what Get-HDTConsoleConditionOption
            offers, so the two steps read the same fact the engine selects a
            layout by.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under,
            with the firmware in brackets as MDT names them.

        .PARAMETER Firmware
            UEFI or BIOS. Decides the layout and the condition, and nothing
            else.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTDiskPartitionStepTemplate

        .EXAMPLE
            Get-HDTDiskPartitionStepTemplate -Firmware BIOS
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 1)]
        [ValidateSet('UEFI', 'BIOS')]
        [string] $Firmware = 'UEFI'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE LAYOUT NAMES ARE THE ENGINE'S, spelled the way Get-HDTDiskLayout
    # answers to. An earlier version wrote 'layout: UEFI', which parses, sits in
    # the Add menu looking finished, and refuses on the machine with "'UEFI' is
    # not a disk layout this engine knows" - a round trip through the reader
    # cannot catch it, because a layout is resolved when the step runs.
    # THE CONDITION IS WRITTEN THE WAY AN ADMINISTRATOR WOULD TYPE IT. The
    # engine reads $Name as a second spelling of %Name%, and $true/$false as the
    # words it compares - so this is the form a template should teach.
    #
    # QUOTED, because a YAML scalar may not start with % and the two spellings
    # should look the same in the file whichever one is used.
    $layout = 'uefi-standard'
    $condition = '$HDTIsUEFI -eq $true'

    if ($Firmware -eq 'BIOS') {
        $layout = 'bios-standard'
        $condition = '$HDTIsUEFI -eq $false'
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'Format and Partition Disk ({0})' -f $Firmware
    }

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: DiskPartition'
        '  # disk: the disk to wipe. HDT will not guess it - set it before'
        '  # this sequence is run, or the step refuses.'
        ('  layout: {0}' -f $layout)
        '  wipe: true'
        ("  condition: '{0}'" -f $condition)
    )
}
