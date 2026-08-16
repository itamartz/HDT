function Get-HDTPowerShellStepDescription {
    <#
        .SYNOPSIS
            Describes a PowerShell step by the script it will run.

        .DESCRIPTION
            The optional third of the step contract's triple. The script path is the
            thing a technician wants to see next to a step called 'Custom'.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTPowerShellStepDescription -Step $step
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

    if ($null -ne $property -and $property.Contains('script') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['script'])) {

        return ('PowerShell: {0}' -f $property['script'])
    }

    return ('PowerShell: {0}' -f $Step.Name)
}
