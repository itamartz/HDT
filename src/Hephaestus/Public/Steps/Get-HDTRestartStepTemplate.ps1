function Get-HDTRestartStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new Restart step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE DELAY IS WRITTEN OUT RATHER THAN LEFT TO THE DEFAULT, because a
            reboot is the one step a technician standing at the machine wants a
            few seconds of warning about, and a key that is present is a key they
            can see and change. It carries no continueOnError: tolerating a
            failed reboot continues the sequence in the phase it was trying to
            leave, which Test-HDTTaskSequence warns about for good reason.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTRestartStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Restart Computer'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: Restart'
        '  delaySeconds: 10'
    )
}
