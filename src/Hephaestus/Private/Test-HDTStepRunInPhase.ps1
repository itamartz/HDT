function Test-HDTStepRunInPhase {
    <#
        .SYNOPSIS
            Decides whether a step's runIn allows it to run in this leg's phase.

        .DESCRIPTION
            DESIGN 4.2's runIn, in one place. A step declares WinPE, FullOS or
            Any; a leg is running in WinPE or in FullOS; a step runs when it
            declares Any or names the phase it is in.

            A MISSING runIn IS Any. Import-HDTSequenceDocument already defaults
            it and propagates a group's runIn down to a step that declares none,
            so a $null here means a caller that built a step by hand - and the
            safe reading of "unspecified" is "wherever it lands", which is what
            the flattener's own default says.

            The comparison is case-insensitive, like every other comparison in
            HDT: a sequence that writes `runIn: winpe` means WinPE.

        .PARAMETER RunIn
            WinPE, FullOS or Any. $null, empty and whitespace are all Any.

        .PARAMETER Phase
            WinPE or FullOS - the phase this leg is executing in.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTStepRunInPhase -RunIn $step.RunIn -Phase $Context.Phase
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RunIn,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($RunIn)) {
        return $true
    }

    if ($RunIn -eq 'Any') {
        return $true
    }

    return ($RunIn -eq $Phase)
}
