function Get-HDTCleanVolumeStepDescription {
    <#
        .SYNOPSIS
            Describes a CleanVolume step by the volume it empties.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the line a
            technician reads on the progress display while a previous
            installation is being deleted off the machine in front of them, so
            it says what is happening - the volume is being EMPTIED - and names
            the volume, because "which one" is the only question anybody has
            about a step that deletes.

            IT SAYS 'the volume this deployment targets' RATHER THAN A LETTER
            WHEN THE STEP NAMES NONE, which is the same reasoning
            Get-HDTApplyDriversStepDescription writes down: a description is
            built while a sequence is being edited, long before HDTOSVolume
            exists, and 'CleanVolume: ' reads like a step somebody forgot to
            finish.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFRESH-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CleanVolume' })[0]

            Get-HDTCleanVolumeStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
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

    $volume = [string] (Get-HDTStepProperty -Step $Step -Name 'volume' -Default '')

    if ([string]::IsNullOrWhiteSpace($volume) -or $volume.Trim() -eq 'primary') {
        return 'CleanVolume: delete everything on the volume this deployment targets, except this run''s own state'
    }

    return ('CleanVolume: delete everything on {0}, except this run''s own state' -f $volume)
}
