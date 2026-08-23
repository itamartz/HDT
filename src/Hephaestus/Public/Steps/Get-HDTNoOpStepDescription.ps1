function Get-HDTNoOpStepDescription {
    <#
        .SYNOPSIS
            Describes a NoOp step for the log and the progress display.

        .DESCRIPTION
            The optional third of the step contract's triple. A NoOp's message is what
            the sequence author wrote it to say, so it makes a better one-line
            description than the step's name; without one, the dispatcher's own
            '<Type>: <name>' shape is kept so the two never disagree.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'NoOp' })[0]

            Get-HDTNoOpStepDescription -Step $step

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

    $property = $Step.Property

    if ($null -ne $property -and $property.Contains('message') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['message'])) {

        return ('NoOp: {0}' -f $property['message'])
    }

    return ('NoOp: {0}' -f $Step.Name)
}
