function Get-HDTStepPropertyChoice {
    <#
        .SYNOPSIS
            The values a step property will accept, for the keys that only
            accept a few.

        .DESCRIPTION
            ONE LIST, READ BY BOTH ENDS. Invoke-HDTEnableBitLockerStep refuses a
            scope it does not know, and the console offers a drop-down of the
            ones it does. Those were the same four values written out twice, in
            files that are changed for different reasons - which is a refusal at
            the machine, four hours into a deployment, saying a word the console
            had just offered.

            SO THE STEP READS ITS OWN REFUSAL FROM HERE TOO. The console cannot
            offer a value the engine will reject, because there is nothing left
            to disagree with.

            A KEY THAT IS NOT IN THIS TABLE IS FREE TEXT, which is most of them:
            a drive letter, a command line, a template path. An empty result is
            the answer, not a failure - Get-HDTConsoleStepNode draws a box.

            WHAT IS NOT HERE. runIn is a step property but belongs to the
            Options tab, which has its own control for it; and firmware's three
            answers are documented by Invoke-HDTConfigureBootStep rather than
            enforced - it uppercases what it is given and passes it on - so the
            list is an offer rather than the step's own refusal. It earns its
            place anyway: 'auto' is the default and the one worth picking
            deliberately, and nothing on a text box says it exists.

        .PARAMETER Type
            The step's type, as the document spells it.

        .PARAMETER Key
            The property name, as the document spells it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the values, in the order they should be offered,
            or an empty array for a key this table says nothing about.

        .EXAMPLE
            Get-HDTStepPropertyChoice -Type 'EnableBitLocker' -Key 'scope'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Type,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Key
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE ORDER IS THE ORDER TO OFFER THEM IN, and it is not alphabetical: the
    # default comes first, because a list whose top entry is the answer most
    # sequences want is a list most people can close again immediately.
    $table = @{
        'EnableBitLocker' = @{
            'scope'     = @('usedSpaceOnly', 'full')
            'method'    = @('Aes128', 'Aes256', 'XtsAes128', 'XtsAes256')
            'protector' = @('tpm', 'tpmPin', 'tpmStartupKey')
            'escrow'    = @('ad', 'entra', 'none')
        }

        'ConfigureBoot' = @{
            'firmware' = @('auto', 'UEFI', 'BIOS')
        }

        # MDT's two radio buttons on the Inject Drivers step, in MDT's order:
        # install everything in the selection, or only what matches. 'all' leads
        # because a group an administrator built for one model is already the
        # answer for that model - matching it again is work with nothing to
        # gain.
        'ApplyDrivers' = @{
            'mode' = @('all', 'matching')
        }

        # dism's THREE COMPRESSION TYPES, max first because it is the default
        # and the right answer for a reference image: written once, then stored,
        # copied and read for years. THIS LIST IS ALSO THE STEP'S OWN REFUSAL -
        # Invoke-HDTCaptureImageStep reads it rather than spelling the set again,
        # so the console cannot offer a value dism would reject four hours into
        # a capture.
        'CaptureImage' = @{
            'compress' = @('max', 'fast', 'none')
        }

        # THE THREE HALVES OF THE FullOS -> WinPE TRANSPORT, in the order a
        # reference build performs them. THIS LIST IS ALSO THE STEP'S OWN
        # REFUSAL - Invoke-HDTBootToWinPEStep reads it rather than spelling the
        # set again, so the console cannot offer an action the step would reject
        # and neither can drift from the other.
        'BootToWinPE' = @{
            'action' = @('stage', 'arm', 'remove')
        }
    }

    if (-not $table.ContainsKey($Type)) { return [string[]] @() }
    if (-not $table[$Type].ContainsKey($Key)) { return [string[]] @() }

    return [string[]] @($table[$Type][$Key])
}
