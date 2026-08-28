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
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Restart' })[0]

            Get-HDTRestartStepDescription -Step $step

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

    $delaySecond = 0
    if ($null -ne $property -and $property.Contains('delaySeconds')) {
        $delaySecond = [int] $property['delaySeconds']
    }

    return ('Restart: in {0} second(s)' -f $delaySecond)
}
