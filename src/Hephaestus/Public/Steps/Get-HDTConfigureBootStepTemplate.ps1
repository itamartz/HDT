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
