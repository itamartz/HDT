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

        .PARAMETER DeploymentType
            What the RUN is - NEWCOMPUTER or REFRESH - as its own state document
            records it. A Refresh's ApplyImage sits ahead of the resume point
            rather than behind it, so the leg that comes back exists to run it;
            Get-HDTResumePermittedStepType holds that exception, and holds the
            plain account of what keying it to a value in state.json costs.

            Absent, empty or unrecognised grants nothing, which is the right
            reading of "this document does not say what its run is".

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTResumeStepForbidden -Step $step

            True for a DiskPartition step, which a resumed WinPE leg must never
            reach.

        .EXAMPLE
            Test-HDTResumeStepForbidden -Step $step -DeploymentType REFRESH

            False for an ApplyImage step - and still True for a DiskPartition
            one, on every deployment type there is.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $Step,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DeploymentType
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

    if (-not ((Get-HDTResumeForbiddenStepType) -contains $type)) { return $false }

    # THE ONE EXCEPTION, AND IT IS SUBTRACTED FROM THE SET RATHER THAN BRANCHED
    # AROUND IT. The forbidden set and the permission table are two lists in two
    # files, and this is the only place they meet - so a test can walk the whole
    # grid rather than assert whichever pair prompted the change (CLAUDE.md 8).
    #
    # Get-HDTResumePermittedStepType carries the reasoning, including the plain
    # account of what it costs to key an exception to a value that lives in the
    # same state.json as the stepIndex this guard exists to disbelieve.
    return (-not ((Get-HDTResumePermittedStepType -DeploymentType $DeploymentType) -contains $type))
}
