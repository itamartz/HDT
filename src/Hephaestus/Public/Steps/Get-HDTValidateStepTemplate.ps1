function Get-HDTValidateStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new Validate step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE TWO FLOORS ARE WRITTEN OUT because a Validate step with no
            checks in it passes, which is the one outcome an author adding this
            step did not want. minDiskGB and minRamMB are the pair worth asking
            first, at values a Windows 11 target has to clear anyway. (They are
            the pair MDT's LTIValidate has always asked.)

            requireUefi IS NOT WRITTEN OUT. It would be a claim about the fleet
            rather than about this sequence, and a BIOS machine failing a check
            the template added on its behalf is a confusing first run.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTValidateStepTemplate

            The YAML lines for a new Validate step, named after its type.

        .EXAMPLE
            $line = Get-HDTValidateStepTemplate -Name 'Prepare the disk'
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
        [string] $Name = 'Validate'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: Validate'
        '  minDiskGB: 64'
        '  minRamMB: 4096'
    )
}
