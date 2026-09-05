function Test-HDTStepPhaseForbidden {
    <#
        .SYNOPSIS
            Is this step type impossible in the phase the sequence puts it in?

        .DESCRIPTION
            True when the type is one Get-HDTFullOsOnlyStepType names AND the
            EFFECTIVE runIn is exactly WinPE. The flattener asks this once per
            step and refuses the document, so an authoring mistake is found on
            the machine that wrote the sequence rather than on the machine being
            deployed at two in the morning.

            THE EFFECTIVE runIn, NOT THE DECLARED ONE. A step with no runIn of
            its own inherits its nearest ancestor group's, so
            `- group: Preinstall / runIn: WinPE` puts every step under it in
            WinPE without any of them saying so. That is the case DESIGN 10.1 is
            actually about, and it is the reason the question is asked in
            Import-HDTSequenceDocument, where the inheritance has already been
            resolved, and not in Assert-HDTSequenceDocument, which sees the raw
            document and would see no runIn at all.

            ONLY AN EXPLICIT WinPE IS FORBIDDEN. Any, empty and $null are all
            allowed, and this is the question the next reader will have:

              Any    means "wherever it lands", and it is the DEFAULT for every
                     step ever written before runIn existed. The engine already
                     skips a step whose phase does not match the leg it is on
                     (Test-HDTStepRunInPhase), so an Any step simply does not run
                     during the WinPE leg and runs during the full-OS one.
                     Refusing it would refuse every sequence that never thought
                     about phases at all.

              ''
              $null  are the same statement made by omission, and are treated
                     the same way. The flattener defaults an undeclared runIn to
                     'Any' before it gets here, but the function is also called
                     directly by tests and by anything else that has a raw
                     value, so it answers for both rather than assuming.

            An explicit `runIn: WinPE` is different in kind: it is a claim the
            author made deliberately, and it is wrong. That is worth refusing;
            an unstated default is not.

            THE COMPARISON IS CASE-INSENSITIVE ON BOTH SIDES. YAML is written by
            hand and `winpe`, `WinPE` and `WINPE` are the same phase; the type
            is matched the same way, because a sequence naming `windowsupdate`
            resolves to the same step type through Get-HDTStepType.

        .PARAMETER Type
            The step's type, as written in the document.

        .PARAMETER RunIn
            The step's EFFECTIVE runIn - its own, or its nearest ancestor
            group's. Empty and $null are allowed and mean "not stated".

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'WinPE'

            True. There is no Windows Update Agent in WinPE to talk to.

        .EXAMPLE
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'Any'

            False. The engine skips it during the WinPE leg and runs it during
            the full-OS one, which is what the author asked for.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Type,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RunIn
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Type)) { return $false }
    if ([string]::IsNullOrWhiteSpace($RunIn)) { return $false }

    if ($RunIn.Trim() -ine 'WinPE') { return $false }

    $forbidden = [string[]] @(Get-HDTFullOsOnlyStepType)

    foreach ($candidate in $forbidden) {
        if ($Type.Trim() -ieq $candidate) { return $true }
    }

    return $false
}
