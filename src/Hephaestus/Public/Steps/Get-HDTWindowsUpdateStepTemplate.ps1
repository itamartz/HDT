function Get-HDTWindowsUpdateStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new WindowsUpdate step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE SERVER ARRIVES AS THE VARIABLE, NOT AS AN ADDRESS. Reading it
            from '%HDTWSUSServer%' is the form that works with a rule or a
            wizard answer without the author editing the sequence again - one
            sequence deploys from every site, and each site's rules.yaml names
            its own WSUS. An author who wants one fixed server replaces the
            token with a URL.

            AND THE VARIABLE HAS TO BE SET, OR THE STEP REFUSES. This is the
            one thing about the template worth reading twice.
            Expand-HDTVariableToken leaves a token nothing supplied LITERAL, so
            a share that never set HDTWSUSServer reaches the step with the text
            '%HDTWSUSServer%' - and Invoke-HDTWindowsUpdateStep refuses it,
            naming the variable and saying what to do, rather than writing a
            token into the WUServer policy value. That would take the machine
            off Windows Update without putting it onto anything, which is the
            worst of the three outcomes and the hardest to see.

            SO A SHARE WITH NO WSUS DELETES THE server LINE. An ABSENT server
            key leaves the agent on its default service and the machine patches
            from Microsoft - DESIGN 10.1's documented behaviour, and what the
            step's own refusal message tells you. An absent key and an unset
            variable are not the same thing, and the difference is the whole
            reason the refusal exists.

            runIn: FullOS IS WRITTEN OUT BECAUSE THE AGENT DOES NOT EXIST IN
            WinPE. Microsoft.Update.Session is not in the boot image at all, so
            a step that ran there would fail on the COM activation - and
            Import-HDTSequenceDocument now refuses this type in a WinPE group
            before a machine ever sees it (Test-HDTStepPhaseForbidden). The line
            says out loud what the importer would otherwise have to say in an
            error message.

            continueOnError: true IS DESIGN 10.1'S RECOMMENDED DEFAULT, and the
            reason is worth the line: Windows Update is the least predictable
            thing in a sequence. A server that is mid-sync, an update that was
            superseded this morning, a download that timed out - none of those
            are reasons to abandon a deployment that has already applied an
            image and joined a domain. An author who wants a failure to fail
            sets it false, and the E2E does exactly that.

            maxPasses: 3 IS WRITTEN OUT SO AN AUTHOR CAN SEE THAT THE STEP
            LOOPS. A template that omitted it would teach the single-pass
            mistake by silence: one search installs what is applicable today,
            and the servicing stack update it just installed makes a second set
            applicable that the machine will never be offered. Three passes is
            what MDT's own two-instance convention converges on.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTWindowsUpdateStepTemplate

            The YAML lines for a new WindowsUpdate step, named after the words
            the console offers it under.

        .EXAMPLE
            $line = Get-HDTWindowsUpdateStepTemplate -Name 'Windows Update (Post-Application)'
            $line -join [System.Environment]::NewLine

            The same lines under MDT's own name for the second instance. They
            are lines, not a document: Add-HDTStep splices them into a
            sequence.yaml so the comments and the order of everything already in
            it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Windows Update'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # SINGLE QUOTES ON THE TOKEN. tests/contract/StepTemplate.Contract.Tests.ps1
    # exists because the ApplyDrivers template shipped a DOUBLE-quoted scalar
    # containing a backslash, \% is not an escape sequence, and no YAML parser
    # would open the result.
    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: WindowsUpdate'
        "  server: '%HDTWSUSServer%'"
        '  categories: [SecurityUpdates, CriticalUpdates, UpdateRollups]'
        '  maxPasses: 3'
        '  continueOnError: true'
        '  runIn: FullOS'
    )
}
