function Get-HDTApplyImageStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new ApplyImage step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            os: IS THE ONE KEY WRITTEN OUT, and it is written empty. It names an
            entry in the OS catalog - OperatingSystems\<id>\os.yaml - which is a
            thing that exists on THIS share and cannot be guessed from here.
            Everything else the step reads (image, index, edition, target) has a
            default that the catalog entry supplies, so writing them into the
            template would override the catalog with placeholders and turn a
            correct default into a thing to be deleted.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTApplyImageStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Apply Operating System'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: ApplyImage'
        "  os: ''"
    )
}
