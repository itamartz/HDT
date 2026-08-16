function Get-HDTPowerShellStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new PowerShell step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE SCRIPT PATH IS RELATIVE TO Scripts\, which is where the engine
            dot-sources user scripts from, so the placeholder shows that form
            rather than a rooted path an author would then have to unlearn.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTPowerShellStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Run PowerShell Script'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: PowerShell'
        "  script: ''"
    )
}
