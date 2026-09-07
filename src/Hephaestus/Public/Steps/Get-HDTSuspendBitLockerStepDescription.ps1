function Get-HDTSuspendBitLockerStepDescription {
    <#
        .SYNOPSIS
            Describes a SuspendBitLocker step by the volume it unprotects.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the line a
            technician reads while the machine in front of them has its
            protectors turned off, so it says the thing they would otherwise
            worry about: the volume is SUSPENDED, not decrypted, and it names
            which volume.

            IT SAYS 'the volume this machine runs from' RATHER THAN A LETTER
            WHEN THE STEP NAMES NONE, which is Get-HDTCleanVolumeStepDescription's
            reasoning: a description is built while a sequence is being edited,
            long before HDTOSVolume exists or any machine has reported a
            SystemDrive, and 'SuspendBitLocker: ' reads like a step somebody
            forgot to finish.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFRESH-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'SuspendBitLocker' })[0]

            Get-HDTSuspendBitLockerStepDescription -Step $step

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

    $drive = [string] (Get-HDTStepProperty -Step $Step -Name 'drive' -Default '')

    if ([string]::IsNullOrWhiteSpace($drive)) {
        return 'SuspendBitLocker: suspend BitLocker protection on the volume this machine runs from, so the next boot does not ask for a recovery key'
    }

    return ('SuspendBitLocker: suspend BitLocker protection on {0}, so the next boot does not ask for a recovery key' -f $drive.Trim())
}
