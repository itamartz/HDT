function Show-HDTDeploymentFailure {
    <#
        .SYNOPSIS
            Shows the technician why the deployment failed, and reports what
            they want the machine to do about it.

        .DESCRIPTION
            THE SCREEN A FAILED MACHINE NEVER HAD. The reason went into the
            JSONL, a FATAL line went into a console the payload had hidden, and
            five seconds later wpeutil powered the machine off. Everything
            needed to fix it was on a share, in a folder named after a computer
            that never finished being built, and the person standing in front of
            the machine had a black screen. MDT shows a summary dialog naming
            the step; this is HDT's.

            IT ADDS NO WPF. The window is Show-HDTWizard's - a XAML path, fields
            applied by name, a button reported - so the failure page is markup
            and this command is the one decision in it: what each button means.

              Restart      the technician will try again from the top
              Shut down    they are finished with this machine
              Finish       the deployment WORKED and they have read the screen;
                           what the machine does next is HDTFinishAction's
                           answer, not this one's
              Open CMD     they are going to go and look, and the machine must
                           stay on while they do

            ANYTHING ELSE IS A SHUT DOWN, including a window that answered
            nothing. A failed machine left running in a room nobody visits is
            not a kindness - and the technician's PRESS is what keeps it on,
            never a silence.

            A WINDOW THAT WILL NOT OPEN IS NOT A SECOND FAILURE. A boot image
            built without WinPE-NetFx has no PresentationFramework at all, and
            this command is called on a machine that has ALREADY failed. So the
            exception is caught, Shown comes back false, and the caller ends the
            machine as it would have without a screen.

        .PARAMETER Failure
            What Get-HDTDeploymentFailure returned.

        .PARAMETER XamlPath
            The failure window. X:\HDT\UI\HDTFailure.xaml inside a boot image.

        .PARAMETER Title
            The window title.

        .PARAMETER WizardHost
            An IWizardHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem, for reading the markup.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Restart',
            'Shutdown', 'Finish' or 'CommandPrompt') and Shown.

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $record = Get-HDTRunLogRecord -Context $log
            $failure = Get-HDTDeploymentFailure -Record $record -LogPath $log.LogPath
            $answer = Show-HDTDeploymentFailure -Failure $failure -XamlPath 'X:\HDT\UI\HDTFailure.xaml'

            The screen a technician actually meets when a deployment stops. It reports
            what they chose and opens nothing itself.

        .EXAMPLE
            if ($answer.Action -eq 'CommandPrompt') { $null = Start-HDTCommandPrompt }

            Acting on the answer is the caller's job. The window closing is not a
            decision, which is why 'Close' and 'CommandPrompt' are different
            answers.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Shows a window and reports the button pressed; it changes no state. A confirmation prompt in front of a technician reading a failure would be a second thing to dismiss.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Failure,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',

        [Parameter()]
        [AllowNull()]
        [object] $WizardHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $field = @()
    if ($null -ne $Failure.PSObject.Properties['Field']) { $field = @($Failure.Field) }

    # WHICH HEADLINE, AND WHETHER THERE IS A REASON TO SHOW. The record decides;
    # this hands the flags to the host, which is the only thing that touches
    # visibility. A record from an older caller carries no Pane and gets the
    # window it always got.
    $pane = @()
    if ($null -ne $Failure.PSObject.Properties['Pane']) { $pane = @($Failure.Pane) }

    # SHOWN IS PART OF THE ANSWER. A caller that cannot tell "they pressed shut
    # down" from "there was no window" cannot log the difference, and those two
    # runs look identical afterwards.
    $answer = ''
    $shown = $false

    try {
        $result = Show-HDTWizard -XamlPath $XamlPath -Title $Title -Field $field -Pane $pane `
            -WizardHost $WizardHost -FileSystem $FileSystem

        $answer = [string] $result.Action
        $shown = $true
    } catch {
        # See the header: this runs on a machine that has already failed.
        Write-Verbose ("the failure window could not be shown: {0}" -f [string] $_.Exception.Message)
    }

    # THE DEFAULT DEPENDS ON WHAT HAPPENED, and it is the one place in this
    # command where the two outcomes part company.
    #
    # A FAILED machine that answered nothing shuts down: left running in a room
    # nobody visits it is not a kindness, and the technician's PRESS is what
    # keeps it on.
    #
    # A FINISHED machine that answered nothing is FINISHED. It has just been
    # deployed correctly; powering it off because a window timed out would undo
    # the deployment's own HDTFinishAction, which is MDT's property and the
    # thing that actually owns this decision.
    $succeeded = $false
    if ($null -ne $Failure.PSObject.Properties['IsFailure']) { $succeeded = (-not $Failure.IsFailure) }

    # AND Cancel IS NOT LISTED BELOW, WHICH IS THE POINT OF THE DEFAULT. On a
    # failure it already means Shutdown. On a SUCCESS the Shut down button is
    # collapsed, so a Cancel cannot have come from a button at all - it is
    # Show-HDTWizard reporting silence, and silence on a finished machine means
    # finished.
    $action = 'Shutdown'
    if ($succeeded) { $action = 'Finish' }

    if ($answer -eq 'Next') { $action = 'Restart' }
    if ($answer -eq 'CommandPrompt') { $action = 'CommandPrompt' }

    # NOT GATED ON $succeeded. The button is COLLAPSED on a failure rather than
    # absent, and a collapsed control cannot be pressed - but a machine whose
    # Pane did not apply must still do what it was told, rather than silently
    # shutting down.
    if ($answer -eq 'Finish') { $action = 'Finish' }

    return [pscustomobject] @{
        Action = $action
        Shown  = $shown
    }
}
