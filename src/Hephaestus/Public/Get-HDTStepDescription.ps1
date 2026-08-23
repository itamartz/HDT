function Get-HDTStepDescription {
    <#
        .SYNOPSIS
            Renders the one-line description of a step for the log and the
            progress display.

        .DESCRIPTION
            The third of the step contract's triple, and the only optional one that has
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
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step)[0]
            Get-HDTStepDescription -Step $step

            The one line the log and the progress display carry for this step. Never
            empty: a step type that declares no description gets '<Type>: <name>',
            which is what MDT's progress line shows.

        .EXAMPLE
            $registry = @(Get-HDTStepType)
            Get-HDTStepDescription -Step $step -StepType $registry

            The same answer with the registry built once and handed in, which is what
            the engine does rather than rebuilding it for every step.

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
