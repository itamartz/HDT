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

    if ($null -ne $property -and $property.Contains('release')) { $release = [string] $property['release'] }

    if ([string]::IsNullOrWhiteSpace($release)) {
        return ('ApplyUpdates: every imported update ({0})' -f $Step.Name)
    }

    return ('ApplyUpdates: {0}' -f $release)
}
