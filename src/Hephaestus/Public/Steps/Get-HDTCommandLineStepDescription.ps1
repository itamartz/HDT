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
            Get-HDTCommandLineStepDescription -Step $step
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
