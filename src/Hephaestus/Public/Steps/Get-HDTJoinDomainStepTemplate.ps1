function Get-HDTJoinDomainStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new JoinDomain step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            EVERY KEY IS A WIZARD VARIABLE, WRITTEN OUT RATHER THAN LEFT
            IMPLICIT, and that is the point of this template rather than a
            stylistic choice. The Computer Details page has collected these five
            names since the wizard shipped and nothing consumed them; an
            administrator adding this step in the console needs to see, in the
            step itself, that the page they already fill in is what feeds it.
            A template naming only the domain would leave the OU and the join
            account looking like things they had to invent.

            THERE IS NO PASSWORD KEY, AND THERE MUST NOT BE. sequence.yaml is
            printed into a text box in the console, quoted back in refusals and
            stored on a share every machine being deployed can read. The password
            comes from HDTDomainAdminPassword in the variable bag, which is
            redacted out of every log, checkpoint and report by
            Test-HDTSecretVariable.

            runIn: FullOS BECAUSE A DOMAIN JOIN NEEDS A RUNNING WINDOWS. This is
            an online join through Add-Computer, not an offline one written into
            an answer file - see Invoke-HDTJoinDomainStep for why - so it belongs
            in the State Restore group after the machine has booted, which is
            where DESIGN 4.1's example sequence and MDT's own Client.xml both put
            it.

            retry: BECAUSE A CONTROLLER IS NOT ALWAYS THERE YET. The commonest
            failure of a first join attempt is a machine whose network came up
            seconds ago and whose DNS has not settled. MDT counts its own
            attempts and reboots between them; HDT has retry: on every step, so
            this declares one rather than growing a second retry mechanism inside
            a step. Two retries thirty seconds apart is three attempts over a
            minute, which is the shape of the problem.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTJoinDomainStepTemplate

            The YAML lines for a new JoinDomain step, named after its type.

        .EXAMPLE
            $line = Get-HDTJoinDomainStepTemplate -Name 'Join the corp domain'
            $line -join [System.Environment]::NewLine

            The same lines under a name of your own. They are lines, not a
            document: Add-HDTStep splices them into a sequence.yaml so the
            comments and the order of everything already in it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Join Domain'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: JoinDomain'
        "  domain: '%HDTJoinDomain%'"
        "  ou: '%HDTMachineObjectOU%'"
        "  workgroup: '%HDTJoinWorkgroup%'"
        "  userName: '%HDTDomainAdmin%'"
        "  userDomain: '%HDTDomainAdminDomain%'"
        '  runIn: FullOS'
        '  retry:'
        '    count: 2'
        '    delaySeconds: 30'
    )
}
