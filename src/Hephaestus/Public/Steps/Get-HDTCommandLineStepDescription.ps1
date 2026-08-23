function Get-HDTCommandLineStepDescription {
    <#
        .SYNOPSIS
            Describes a CommandLine step by the executable it will run.

        .DESCRIPTION
            The optional third of the step contract's triple. It names the FILE and not
            the arguments: this string goes to the progress display and to the
            master log at Info, and arguments routinely carry credentials.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CommandLine' })[0]

            Get-HDTCommandLineStepDescription -Step $step

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

    if ($null -ne $property -and $property.Contains('file') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['file'])) {

        return ('CommandLine: {0}' -f $property['file'])
    }

    if ($null -ne $property -and $property.Contains('command') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['command'])) {

        # The first token of a shell line is the executable; the rest is exactly
        # what must not reach an Info-level log.
        $first = @([string] $property['command'] -split '\s+')[0]

        return ('CommandLine: {0}' -f $first)
    }

    return ('CommandLine: {0}' -f $Step.Name)
}
