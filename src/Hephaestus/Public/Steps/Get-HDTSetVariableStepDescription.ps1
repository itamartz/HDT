function Get-HDTSetVariableStepDescription {
    <#
        .SYNOPSIS
            Describes a SetVariable step by the names it will assign.

        .DESCRIPTION
            The optional third of the step contract's triple. "Set HDTStage,
            HDTComputerName" tells a technician reading the progress display
            which variables are about to change; the step's own name usually does
            not.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'SetVariable' })[0]

            Get-HDTSetVariableStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.
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
    $name = New-Object -TypeName System.Collections.ArrayList

    if ($null -ne $property -and $property.Contains('variables') -and
        ($property['variables'] -is [System.Collections.IDictionary])) {

        foreach ($key in @($property['variables'].Keys)) {
            [void] $name.Add([string] $key)
        }
    }

    if ($null -ne $property -and $property.Contains('variable')) {
        [void] $name.Add([string] $property['variable'])
    }

    if (@($name).Count -eq 0) {
        return ('SetVariable: {0}' -f $Step.Name)
    }

    return ('SetVariable: {0}' -f (@($name) -join ', '))
}
