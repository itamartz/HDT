function Get-HDTMachineEnding {
    <#
        .SYNOPSIS
            Decides whether a finished run ends the machine, and says why.

        .DESCRIPTION
            Answers one question at the end of a deployment: does this run power
            the machine off or reboot it, or does it leave the machine where it
            is? It reads nothing and changes nothing - the caller acts on the
            answer - so the decision can be checked without a machine.

            A FAILED RUN IS LEFT WHERE IT FAILED. That used to be a shutdown,
            and the reasoning was sound as far as it went: a failed run has
            usually not applied an image, and a REBOOT would boot the media and
            start the same deployment again with nobody watching. But the answer
            to "do not loop" is "stop", not "power off". A machine sitting in
            WinPE loops nothing, keeps X:, the console and the error on screen,
            and can be walked up to; one that powered itself off took the only
            copy of the reason with it - and this payload's log lives on a share
            it may never have reached.

            ONLY A PERSON ENDS A FAILED MACHINE. Restart or Shutdown on the
            failure screen is somebody deciding, and the machine obeys them.

            A COMMAND PROMPT MEANS THE MACHINE IS THEIRS. Open CMD exists to
            debug a machine that is behaving badly, and a run that opened the
            prompt and powered the machine off five seconds later gave the
            technician nothing at all - which is what a real VM run did.

        .PARAMETER Status
            How the run ended: Failed, Succeeded or RebootPending.

        .PARAMETER FailureScreenAction
            What the technician chose on the failure screen, when one was shown.
            Restart and Shutdown are decisions; anything else is not.

        .PARAMETER LeftAtCommandPrompt
            The technician was left at a prompt on this machine.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with EndMachine and
            Reason.

        .EXAMPLE
            Get-HDTMachineEnding -Status 'Failed'

            EndMachine : False
            Reason     : left in WinPE so the failure can be read

        .EXAMPLE
            $ending = Get-HDTMachineEnding -Status 'Succeeded'
            if ($ending.EndMachine) { & "$env:SystemRoot\System32\wpeutil.exe" 'reboot' }

            What the payload does with it: the verb is chosen elsewhere, and
            this decides only whether it is used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Status,

        [Parameter()]
        [AllowEmptyString()]
        [string] $FailureScreenAction = '',

        [Parameter()]
        [switch] $LeftAtCommandPrompt
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($LeftAtCommandPrompt) {
        return [pscustomobject] @{
            EndMachine = $false
            Reason     = 'nothing - the technician was left at a command prompt'
        }
    }

    if ($Status -ne 'Failed') {
        return [pscustomobject] @{
            EndMachine = $true
            Reason     = 'the run finished, so the machine is ended as the sequence asked'
        }
    }

    # A DECISION SOMEBODY MADE, and the machine obeys it.
    if ($FailureScreenAction -in @('Restart', 'Shutdown')) {
        return [pscustomobject] @{
            EndMachine = $true
            Reason     = ('the technician chose {0} on the failure screen' -f $FailureScreenAction)
        }
    }

    return [pscustomobject] @{
        EndMachine = $false
        Reason     = 'left in WinPE so the failure can be read'
    }
}
