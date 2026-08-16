function Get-HDTApplyUnattendStepDescription {
    <#
        .SYNOPSIS
            Describes an ApplyUnattend step by the template it will stage.

        .DESCRIPTION
            The optional third of the step contract's triple. The template name is what
            a technician needs when a machine came up with the wrong name or
            stopped at OOBE: it says which file to go and read.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTApplyUnattendStepDescription -Step $step
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $template = [string] (Get-HDTStepProperty -Step $Step -Name 'template' -Default 'the unattend the sequence names')

    return ('Unattend: {0}, staged at Windows\Panther\unattend.xml' -f $template)
}
