function Get-HDTApplyUpdatesStepDescription {
    <#
        .SYNOPSIS
            One line describing an ApplyUpdates step, for the console tree and
            the log.

        .DESCRIPTION
            THE RELEASE IS SHOWN UNEXPANDED, WHICH IS THE POINT, and it is
            Get-HDTApplyDriversStepDescription's reasoning applied to the same
            problem. A tree row saying 'ApplyUpdates: %HDTOSRelease%' tells an
            administrator what the step will do on EVERY machine; one saying
            'ApplyUpdates: Win11-24H2' would describe whichever release the
            authoring laptop happened to resolve and mislead about all the rest.
            The resolved release belongs in the run log, where a machine is
            actually being deployed - and Invoke-HDTApplyUpdatesStep writes it
            there.

            A STEP WITH NO RELEASE APPLIES EVERYTHING IMPORTED, and it says so
            rather than showing an empty value. That configuration is legitimate
            - it is the "this share deploys one operating system" setting - and a
            row reading 'ApplyUpdates: ' looks like a step somebody forgot to
            finish.

        .PARAMETER Step
            The step to describe.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUpdates' })[0]

            Get-HDTApplyUpdatesStepDescription -Step $step

            The row the console tree draws for that step.

        .EXAMPLE
            @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUpdates' }) |
                ForEach-Object { Get-HDTApplyUpdatesStepDescription -Step $_ }

            Every update step in a sequence, described as the tree describes them
            - which is how you see at a glance that one of them names no release
            and is therefore applying everything on the share.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property
    $release = ''
    $named = @()

    if ($null -ne $property -and $property.Contains('release')) { $release = [string] $property['release'] }

    # NAMED IDS ARE THE STRONGER FACT AND THE LINE SAYS THEM FIRST. A step whose
    # `updates` names two of the five imported for a release reads 'Win11-24H2'
    # in the tree if the release is all this line reports - identical to the step
    # beside it that applies all five, which is the difference somebody opened
    # the tree to see.
    #
    # THE COUNT AND NOT THE IDS: a KB id is fifteen characters and four of them
    # is a line nothing else in the tree can sit beside. The Properties sheet
    # holds the list; this holds the shape of it.
    if ($null -ne $property -and $property.Contains('updates')) {
        $raw = $property['updates']

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            $named = @(@($raw) | ForEach-Object { [string] $_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            $named = @(@([string] $raw -split '[,;]') | ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    if ($named.Count -eq 1) { return ('ApplyUpdates: {0}' -f [string] $named[0]) }

    if ($named.Count -gt 1) { return ('ApplyUpdates: {0} named update(s)' -f $named.Count) }

    if ([string]::IsNullOrWhiteSpace($release)) {
        return ('ApplyUpdates: every imported update ({0})' -f $Step.Name)
    }

    return ('ApplyUpdates: {0}' -f $release)
}
