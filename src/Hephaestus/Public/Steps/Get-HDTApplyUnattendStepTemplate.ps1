function Get-HDTApplyUnattendStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new ApplyUnattend step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            expand: true IS THE DEFAULT WORTH MAKING VISIBLE. An unattend template
            that does not have its %Var% tokens expanded is a file full of literal
            percent signs applied to a machine, and the failure shows up much
            later as a computer named %HDTComputerName%. Writing the key out means
            an author who does want the raw file turns it off deliberately.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTApplyUnattendStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Apply Windows Settings'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: ApplyUnattend'
        "  template: ''"
        '  expand: true'
    )
}
