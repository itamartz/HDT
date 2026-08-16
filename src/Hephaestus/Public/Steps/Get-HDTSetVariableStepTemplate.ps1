function Get-HDTSetVariableStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new SetVariable step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE SINGULAR FORM, NOT THE PLURAL. The step accepts either variable:
            with value: or a variables: map, and the template writes the singular
            pair because one name is what an author adding a step from a menu is
            almost always after. The map is the thing they graduate to, and
            editing one into the other is a smaller step than the reverse.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTSetVariableStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Set Task Sequence Variable'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: SetVariable'
        "  variable: ''"
        "  value: ''"
    )
}
