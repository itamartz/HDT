function Get-HDTFinishAction {
    <#
        .SYNOPSIS
            Decides what the machine does when the deployment is over.

        .DESCRIPTION
            Turns what HDTFinishAction resolved to - restart, shut down, log off
            or nothing - into the power operation the machine performs when the
            deployment is over.

            A DEPLOYMENT USED TO END ON exit 0 AND STAY WHERE IT WAS. A machine
            that had just finished sat at a desktop, logged in as the local
            Administrator, until somebody walked over to it - which is the
            opposite of what a technician imaging a bench of twenty machines
            wants.

            THE DECISION IS HERE AND THE ACTION IS NOT. Everything about which
            power operation a value means is settled in this function, against
            no machine at all; the payload does nothing but call IPowerService
            with the answer. That split is what lets the odd spellings, the
            unrecognised value and the WinPE case be asserted in Pester without
            a test ever being in a position to reboot the machine running it -
            the same arrangement Get-HDTPowerCommand and New-HDTPowerService
            already run on.

            A VALUE NOBODY MEANT DOES NOTHING, AND IS NOT A FAILURE. 'SHUTDONW'
            resolving to the nearest match would take down a machine somebody
            was about to work on, and every wrong guess here is silent and
            physical. Refusing would be worse in the other direction: the
            deployment succeeded, and turning a built machine into a failed one
            over a misspelt finish action helps nobody. So it resolves to None
            and says it did not recognise the value, and the caller warns.

        .PARAMETER Value
            What HDTFinishAction resolved to. REBOOT, RESTART, SHUTDOWN, LOGOFF
            or NONE, in any case and with any surrounding space. Empty or null
            means None, which is how every deployment behaved before this
            variable existed.

        .PARAMETER Environment
            WinPE or FullOS. There is no detection: the two payloads that end a
            deployment already know which world they are in.

        .PARAMETER DelaySecond
            How long to wait before the machine goes. Refused if negative.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Restart',
            'Stop', 'Logoff' or 'None'), DelaySecond, IsRecognised and Reason.

        .EXAMPLE
            Get-HDTFinishAction -Value 'REBOOT' -Environment FullOS

            Action Restart.

        .EXAMPLE
            Get-HDTFinishAction -Value 'LOGOFF' -Environment WinPE

            Action None - WinPE has no logon session to end.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Environment,

        [Parameter()]
        [int] $DelaySecond = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($DelaySecond -lt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("A finish delay cannot be negative, and {0} was asked for. Use 0 to go immediately." -f $DelaySecond) `
                    -TargetObject $DelaySecond))
    }

    $answer = {
        param([string] $Action, [bool] $IsRecognised, [string] $Reason)

        return [pscustomobject] @{
            Action       = $Action
            DelaySecond  = $DelaySecond
            IsRecognised = $IsRecognised
            Reason       = $Reason
        }
    }

    $wanted = ([string] $Value).Trim()

    if ([string]::IsNullOrWhiteSpace($wanted)) {
        return (& $answer 'None' $true 'No finish action was set, so the machine is left as the deployment left it.')
    }

    # RESTART ALONGSIDE MDT'S REBOOT, because it is the word this toolkit uses
    # for the same thing everywhere else - a Restart step, IPowerService.Restart
    # - and somebody will write it. One spelling being right and its synonym
    # doing nothing is the kind of difference that costs an afternoon.
    switch ($wanted.ToUpperInvariant()) {
        'REBOOT' { return (& $answer 'Restart' $true 'HDTFinishAction is REBOOT, so the machine restarts when the deployment ends.') }
        'RESTART' { return (& $answer 'Restart' $true 'HDTFinishAction is RESTART, MDT''s REBOOT under the name this engine uses elsewhere.') }
        'SHUTDOWN' { return (& $answer 'Stop' $true 'HDTFinishAction is SHUTDOWN, so the machine powers off when the deployment ends.') }
        'NONE' { return (& $answer 'None' $true 'HDTFinishAction is NONE, so the machine is left as the deployment left it.') }
        'LOGOFF' {
            if ($Environment -eq 'WinPE') {
                return (& $answer 'None' $true 'HDTFinishAction is LOGOFF, and WinPE has no logon session to end. The value is honoured on the full-OS leg; here it does nothing.')
            }

            return (& $answer 'Logoff' $true 'HDTFinishAction is LOGOFF, so the session ends and the machine returns to the logon screen.')
        }
    }

    return (& $answer 'None' $false ("HDTFinishAction is '{0}', which is not a finish action this engine knows. It is REBOOT, SHUTDOWN, LOGOFF or NONE, and nothing was done rather than the nearest guess acted on." -f $wanted))
}
