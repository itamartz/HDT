function Get-HDTNoOpStepDescription {
    <#
        .SYNOPSIS
            Describes a NoOp step for the log and the progress display.

        .DESCRIPTION
            The optional third of DESIGN 4.2's triple. A NoOp's message is what
            the sequence author wrote it to say, so it makes a better one-line
            description than the step's name; without one, the dispatcher's own
            '<Type>: <name>' shape is kept so the two never disagree.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTNoOpStepDescription -Step $step
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
