function Get-HDTStepDescription {
    <#
        .SYNOPSIS
            Renders the one-line description of a step for the log and the
            progress display.

        .DESCRIPTION
            The third of DESIGN 4.2's triple, and the only optional one that has
            a useful default. A step type may declare

              Get-HDT<Type>StepDescription -Step

            to say something more informative than its name - "Apply
            Win11-24H2-Ent index 3 to the primary volume" rather than "Apply OS".
            A type that declares none gets '<Type>: <name>', which is what MDT's
            progress line shows and is never empty.

            An unknown type gets the same default, because a description is
            wanted precisely when reporting a step that could not be run.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry.

        .OUTPUTS
            System.String, never empty.

        .EXAMPLE
            Get-HDTStepDescription -Step $step -StepType $registry
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $StepType
    if ($null -eq $registry) {
        $registry = @(Get-HDTStepType)
    }

    $entry = @($registry | Where-Object { $_.Type -eq [string] $Step.Type })

    if ($entry.Count -gt 0 -and $null -ne $entry[0].DescriptionCommand) {
        $described = [string] (& $entry[0].DescriptionCommand -Step $Step)

        if (-not [string]::IsNullOrWhiteSpace($described)) {
            return $described
        }
    }

    return ('{0}: {1}' -f $Step.Type, $Step.Name)
}
