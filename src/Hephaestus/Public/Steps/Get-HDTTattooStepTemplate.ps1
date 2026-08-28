function Get-HDTTattooStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new Tattoo step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            TWO LINES, AND NOTHING TO FILL IN. Everything the step stamps is
            already resolved by the time it runs, so a template that wrote a
            path: or a values: stub would be offering an author the one thing
            they almost never want to change and hiding the fact that the step
            works as-is. Both are documented on the step; neither belongs in the
            thing the Add menu writes.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under -
            'Tattoo', which is what the step is called everywhere else it
            appears, so it is the name an administrator will look for.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTTattooStepTemplate

            The YAML lines for a new Tattoo step, named after its type.

        .EXAMPLE
            $line = Get-HDTTattooStepTemplate -Name 'Prepare the disk'
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
        [string] $Name = 'Tattoo'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: Tattoo'
    )
}
