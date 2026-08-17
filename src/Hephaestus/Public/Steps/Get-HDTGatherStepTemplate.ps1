function Get-HDTGatherStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new Gather step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            IT DECLARES NOTHING, because the step takes nothing. What to gather
            is not a choice - it is every fact Get-HDTMachineFact reads - and a
            step with a list of facts to skip would be a way to produce a
            machine whose variables are half fresh and half stale.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTGatherStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Gather'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: Gather'
    )
}
