function Get-HDTTattooStepDescription {
    <#
        .SYNOPSIS
            Describes a Tattoo step by the key it will stamp.

        .DESCRIPTION
            The optional third of the step contract's triple. The step's own name
            is almost always just "Tattoo", so the useful thing to put in front of
            a technician watching the progress display is WHERE it is writing -
            which is the one thing about this step a sequence can change.

            IT NAMES THE DEFAULT RATHER THAN NOTHING when the step declares no
            path. 'Tattoo: Tattoo' would be the progress line for the ordinary
            case, which is the case this step is in almost every time.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Tattoo' })[0]

            Get-HDTTattooStepDescription -Step $step

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
    $path = 'HKLM:\SOFTWARE\Hephaestus\Deployment'

    if ($null -ne $property -and $property.Contains('path') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['path'])) {

        # UNEXPANDED, DELIBERATELY. This runs before the step does and has no
        # variable scope to expand against; a description showing the token the
        # author wrote is honest, and one showing a half-expanded path would not
        # be.
        $path = [string] $property['path']
    }

    return ('Tattoo: {0}' -f $path)
}
