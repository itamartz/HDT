function Get-HDTConfigureBootStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new ConfigureBoot step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            firmware: UEFI IS A DEFAULT, NOT AN ASSUMPTION ABOUT THE FLEET. It
            matches the layout the DiskPartition template writes, so the two
            steps an author adds together agree; a BIOS target changes one key in
            each. The alternative - leaving it empty - produces a step that reads
            as configured and is not.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTConfigureBootStepTemplate

            The YAML lines for a new ConfigureBoot step, named after its type.

        .EXAMPLE
            $line = Get-HDTConfigureBootStepTemplate -Name 'Prepare the disk'
            $line -join [System.Environment]::NewLine

            The same lines under a name of your own. They are lines, not a
            document: Add-HDTStep splices them into a sequence.yaml so the
            comments and the order of everything already in it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Configure Boot'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: ConfigureBoot'
        '  firmware: UEFI'
    )
}
