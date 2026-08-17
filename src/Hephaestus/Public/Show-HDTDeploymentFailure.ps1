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
            'Shutdown' or 'CommandPrompt') and Shown.

        .EXAMPLE
            $failure = Get-HDTDeploymentFailure -Record $record -LogPath $log.LogPath
            $answer = Show-HDTDeploymentFailure -Failure $failure -XamlPath 'X:\HDT\UI\HDTFailure.xaml'
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

    # SHOWN IS PART OF THE ANSWER. A caller that cannot tell "they pressed shut
    # down" from "there was no window" cannot log the difference, and those two
    # runs look identical afterwards.
    $answer = ''
    $shown = $false

    try {
        $result = Show-HDTWizard -XamlPath $XamlPath -Title $Title -Field $field `
            -WizardHost $WizardHost -FileSystem $FileSystem

        $answer = [string] $result.Action
        $shown = $true
    } catch {
        # See the header: this runs on a machine that has already failed.
        Write-Verbose ("the failure window could not be shown: {0}" -f [string] $_.Exception.Message)
    }

    $action = 'Shutdown'
    if ($answer -eq 'Next') { $action = 'Restart' }
    if ($answer -eq 'CommandPrompt') { $action = 'CommandPrompt' }

    return [pscustomobject] @{
        Action = $action
        Shown  = $shown
    }
}
