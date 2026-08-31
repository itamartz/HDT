function Test-HDTResumeStepForbidden {
    <#
        .SYNOPSIS
            Says whether a step may not run because this leg is a resumed one.

        .DESCRIPTION
            The predicate behind the -Resumed guard, split out from the loop so
            it can be asserted against the whole forbidden SET rather than
            against whichever type prompted the test (CLAUDE.md 8).

            PROPERTY-EXISTENCE CHECKED, NOT ASSUMED. Under
            Set-StrictMode -Version Latest, reading a property a step object
            does not carry is a terminating error - and this walks whatever the
            flattener or a hand-written test dictionary produced. A guard that
            threw on a malformed step would be a guard that stopped guarding
            exactly where the state document was least trustworthy, which is the
            only case it exists for.

        .PARAMETER Step
            One flattened step. A dictionary and an object both answer.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTResumeStepForbidden -Step $step

            True for a DiskPartition step, which a resumed WinPE leg must never
            reach.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Step) { return $false }

    $type = ''

    if ($Step -is [System.Collections.IDictionary]) {
        if ($Step.Contains('Type')) { $type = [string] $Step['Type'] }
    } elseif ($null -ne $Step.PSObject.Properties['Type']) {
        $type = [string] $Step.Type
    }

    if ([string]::IsNullOrWhiteSpace($type)) { return $false }

    return ((Get-HDTResumeForbiddenStepType) -contains $type)
}
