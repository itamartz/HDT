function Get-HDTApplyDriversStepDescription {
    <#
        .SYNOPSIS
            One line describing an ApplyDrivers step, for the console tree and
            the log.

        .DESCRIPTION
            THE GROUP IS SHOWN UNEXPANDED, WHICH IS THE POINT. A tree row saying
            'ApplyDrivers: Win11\%HDTMake%\%HDTModel%' tells an administrator
            what the step will do on EVERY machine; one saying
            'Win11\Dell inc\Dell Pro 3 16 P316265' would describe the authoring
            laptop and mislead about all the rest. The resolved path belongs in
            the run log, where a machine is actually being deployed - and
            Invoke-HDTApplyDriversStep writes it there.

            A STEP WITH NO GROUP IS THE PnP FALLBACK, and it says so rather than
            showing an empty path. That configuration is legitimate - it is the
            'I do not know this fleet' setting - and a row reading
            'ApplyDrivers: ' looks like a step somebody forgot to finish.

        .PARAMETER Step
            The step to describe.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-M4\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyDrivers' })[0]

            Get-HDTApplyDriversStepDescription -Step $step

            The row the console tree draws for that step.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-M4\sequence.yaml'

            @($sequence.Step | Where-Object { $_.Type -eq 'ApplyDrivers' }) |
                ForEach-Object { Get-HDTApplyDriversStepDescription -Step $_ }

            Every driver step in a sequence, described as the tree describes them -
            which is how you see at a glance that one of them names no group and is
            therefore matching by hardware id.
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
    $group = ''
    $mode = ''

    if ($null -ne $property -and $property.Contains('group')) { $group = [string] $property['group'] }
    if ($null -ne $property -and $property.Contains('mode')) { $mode = [string] $property['mode'] }

    if ([string]::IsNullOrWhiteSpace($group)) {
        return ('ApplyDrivers: PnP match ({0})' -f $Step.Name)
    }

    if ($mode -eq 'matching') {
        return ('ApplyDrivers: {0}, matching only' -f $group)
    }

    return ('ApplyDrivers: {0}' -f $group)
}
