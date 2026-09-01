function Get-HDTJoinDomainStepDescription {
    <#
        .SYNOPSIS
            Describes a JoinDomain step by what the machine is about to join.

        .DESCRIPTION
            The optional third of the step contract's triple. This string goes to
            the progress display and to the master log at Info.

            IT NAMES THE DOMAIN, because that is the fact a technician watching a
            deployment wants confirmed: a machine joining the wrong domain looks
            exactly like a machine joining the right one until somebody goes
            looking for it in the directory.

            IT SHOWS THE TOKEN WHEN THAT IS WHAT THE STEP SAYS. This runs before
            the step does, off the authored document rather than the resolved
            variables, so '%HDTJoinDomain%' is the honest answer for a step that
            takes its domain from the wizard - and it tells an administrator
            reading the log which variable to go and look at.

            THE DOMAIN WINS OVER THE WORKGROUP HERE TOO, for the reason
            Invoke-HDTJoinDomainStep gives at length: a share seeds
            HDTJoinWorkgroup in its Fallback rule, so nearly every step carries
            both and only one of them is what the machine is getting. A
            description that named the workgroup would contradict the step
            directly above it in the same log.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\STD-CLIENT\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'JoinDomain' })[0]

            Get-HDTJoinDomainStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.
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

    $written = {
        param([string] $Name)

        if ($null -eq $property -or -not $property.Contains($Name)) { return '' }

        return ([string] $property[$Name]).Trim()
    }

    $domain = & $written 'domain'
    if ($domain.Length -gt 0) { return ('JoinDomain: {0}' -f $domain) }

    $workgroup = & $written 'workgroup'
    if ($workgroup.Length -gt 0) { return ('JoinDomain: the workgroup {0}' -f $workgroup) }

    # A STEP THAT NAMES NEITHER STILL GETS A LINE. It takes both from the
    # wizard's own variables, which is what the shipped template does, so saying
    # which ones is more use than saying nothing.
    return 'JoinDomain: whichever of HDTJoinDomain and HDTJoinWorkgroup is set'
}
