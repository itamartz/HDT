function Get-HDTBootToWinPEStepDescription {
    <#
        .SYNOPSIS
            Describes a BootToWinPE step by which half of the transport it does.

        .DESCRIPTION
            The optional third of the step contract's triple.

            THE THREE ACTIONS DO VERY DIFFERENT THINGS TO A MACHINE, and one
            line saying "BootToWinPE" for all of them would be the log entry that
            wastes an hour: staging copies half a gigabyte and changes nothing
            about how the machine boots, arming changes what the next boot is,
            and removing undoes both. So each says which it is, in the terms a
            technician reading a log at three in the morning needs - what the
            machine will do next, not which command was run.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFERENCE\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'BootToWinPE' })[0]

            Get-HDTBootToWinPEStepDescription -Step $step

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

    $action = ([string] (Get-HDTStepProperty -Step $Step -Name 'action' -Default 'stage')).Trim().ToLowerInvariant()

    if ($action -eq 'arm') {
        return 'BootToWinPE: make the next restart boot the WinPE staged on this disk'
    }

    if ($action -eq 'remove') {
        return 'BootToWinPE: remove the staged WinPE and the boot entry that reached it'
    }

    return 'BootToWinPE: stage a WinPE on this disk so the machine can boot back into it'
}
