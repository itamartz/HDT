function Resolve-HDTConsoleCloseAnswer {
    <#
        .SYNOPSIS
            What a button on the closing dialog means: write, discard, or stay.

        .DESCRIPTION
            THE OTHER HALF OF Get-HDTConsoleClosePrompt. That one decides what
            is asked; this one decides what the answer means, so the adapter
            holds no opinion about which button writes to a deployment share -
            it shows a dialog and acts on two booleans.

            A DISMISSED DIALOG IS A CANCEL, NEVER A DISCARD. A message box shut
            with its own X, or with Escape, returns None: nobody answered.
            Reading that as "close and lose the work" would turn a slip of the
            hand into a lost afternoon, while reading it as "stay" costs one
            more press. Anything this command does not recognise is treated the
            same way, for the same reason.

            IT NAMES WHAT IT DECIDED. Action is the word for a log line and for
            the test that reads it - two booleans are enough to act on and not
            enough to read.

        .PARAMETER Answer
            The dialog's result: Yes, No, Cancel, or None for a dialog that was
            dismissed without one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Save, Cancel and
            Action.

        .EXAMPLE
            $decision = Resolve-HDTConsoleCloseAnswer -Answer 'No'
            $decision.Action
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Answer
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Answer -eq 'Yes') {
        return [pscustomobject] @{ Save = $true; Cancel = $false; Action = 'SaveAndClose' }
    }

    if ($Answer -eq 'No') {
        return [pscustomobject] @{ Save = $false; Cancel = $false; Action = 'Discard' }
    }

    # Cancel, None, and anything unrecognised. The reading that loses no work.
    return [pscustomobject] @{ Save = $false; Cancel = $true; Action = 'Stay' }
}
