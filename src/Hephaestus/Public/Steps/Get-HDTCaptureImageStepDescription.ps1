function Get-HDTCaptureImageStepDescription {
    <#
        .SYNOPSIS
            Describes a CaptureImage step by the WIM it will write.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the step a
            technician watches for a quarter of an hour at the end of a
            reference build, so the line names the FILE that is being created -
            which is the one fact that says whether the right build is being
            captured, and the name the share will offer afterwards.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REF-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CaptureImage' })[0]

            Get-HDTCaptureImageStepDescription -Step $step

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

    $image = [string] (Get-HDTStepProperty -Step $Step -Name 'image' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($image)) {
        return ('Capture: {0} into Captures\' -f $image)
    }

    return 'Capture: this machine into Captures\ on the share'
}
