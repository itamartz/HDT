function Get-HDTRestartStepDescription {
    <#
        .SYNOPSIS
            Describes a Restart step by the delay it will ask for.

        .DESCRIPTION
            The optional third of the step contract's triple. "Restart in 30 second(s)"
            is what a technician watching the progress display needs, because the
            delay is the difference between a machine that appears to have hung
            and one that is about to reboot.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTRestartStepDescription -Step $step
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

    $delaySecond = 0
    if ($null -ne $property -and $property.Contains('delaySeconds')) {
        $delaySecond = [int] $property['delaySeconds']
    }

    return ('Restart: in {0} second(s)' -f $delaySecond)
}
