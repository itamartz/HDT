function Get-HDTSetVariableStepDescription {
    <#
        .SYNOPSIS
            Describes a SetVariable step by the names it will assign.

        .DESCRIPTION
            The optional third of DESIGN 4.2's triple. "Set HDTStage,
            HDTComputerName" tells a technician reading the progress display
            which variables are about to change; the step's own name usually does
            not.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTSetVariableStepDescription -Step $step
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
