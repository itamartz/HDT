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
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUnattend' })[0]

            Get-HDTApplyUnattendStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead, which is what MDT's progress line shows.
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
