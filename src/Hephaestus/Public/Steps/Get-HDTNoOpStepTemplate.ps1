function Get-HDTNoOpStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new NoOp step.

        .DESCRIPTION
            The optional fourth of the step contract. A step type that exports a
            template can be CREATED; one that exports only Invoke can be run but
            not created, and Get-HDTStepType reports that as CanAdd.

            THE LINES ARE A FRAGMENT, NOT A DOCUMENT. What comes back is one list
            item as it would appear under a sequence's steps:, unindented. The
            caller - Add-HDTStep - owns the indentation, because only it knows
            how deep in the group tree the step is landing.

            NoOp IS THE PLACEHOLDER STEP, so its template is the smallest legal
            one there is: a name and a type. It carries no message: the step logs
            its own name when it has none, so a message here would only be the
            name written twice for an author to keep in step. This is what a new
            group arrives holding, because this engine has no such thing as an
            empty group.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTNoOpStepTemplate

        .EXAMPLE
            Get-HDTNoOpStepTemplate -Name 'Placeholder'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Do Nothing'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: NoOp'
    )
}
