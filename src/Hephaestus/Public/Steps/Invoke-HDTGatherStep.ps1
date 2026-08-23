function Invoke-HDTGatherStep {
    <#
        .SYNOPSIS
            Re-reads the machine's facts into the sequence's variables.

        .DESCRIPTION
            MDT'S "Gather local only", which is the whole of its Initialization
            group - and which it runs again in Preinstall and again in State
            Restore, because the machine a sequence finishes on is not the
            machine it started on.

            WHY IT IS A STEP AND NOT ONLY ENGINE START-UP. HDT gathers once
            before the sequence begins, and DESIGN 3.2.1 already says the facts
            are "refreshed after OS apply". Making the refresh a step is what
            lets a sequence SAY WHERE it happens, in a file an administrator
            reads, instead of it being a rule inside the engine that nothing on
            screen mentions.

            IT IS NOT A RESET. Only the facts it gathers are replaced;
            HDTComputerName from rules.yaml, a variable a SetVariable step
            wrote, a drive letter a partition step published - none of them are
            touched. A gather that cleared what it did not produce would throw
            away the deployment's own decisions half way through.

            IT REFUSES WITHOUT A CIM PROVIDER rather than gathering nothing and
            reporting success. A green step that quietly gathered nothing leaves
            every later condition false and every later check unmade, which is
            the most expensive way for this to fail.

            IT TOUCHES NO HARDWARE ITSELF. Get-HDTMachineFact takes the injected
            ICimProvider, so this runs under Pester against a fake like every
            other step here.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            The execution context, carrying the service catalog and the live
            variables.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - a step result.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Gather' })[0]

            Invoke-HDTGatherStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $before = @($context.Variable.Keys).Count
            $null = Invoke-HDTGatherStep -Step $step -Context $context
            @($context.Variable.Keys).Count - $before

            How many facts the gather added to the sequence's variables.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Step',
        Justification = 'The step contract requires -Step on every step command. A Gather step declares no properties - what to gather is not a choice - so the parameter is bound and unread, which is the contract being honoured rather than an oversight.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THREE PORTS, BECAUSE THE FACTS COME FROM THREE PLACES. CIM for the
    # hardware, the registry for SecureBoot, and the environment for the
    # firmware type - all injected, none of them touched directly here.
    $cim = $null
    $registry = $null
    $environment = $null

    try {
        $cim = $Context.Service.GetRequired('Cim', 'Gather')
        $registry = $Context.Service.GetRequired('Registry', 'Gather')
        $environment = $Context.Service.GetRequired('Environment', 'Gather')
    } catch {
        $message = 'this step gathers the machine facts and a service it needs was not supplied, so there is nothing to gather them with: {0}' -f $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Gather'

        return (New-HDTStepResult -Status Failed -Message $message `
                -Data ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    try {
        $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $registry -EnvironmentProvider $environment
    } catch {
        $message = [string] $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Gather'

        return (New-HDTStepResult -Status Failed -Message $message `
                -Data ([ordered] @{ errorId = 'HDTGatherFailed' }))
    }

    $written = 0
    $changed = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in @($fact.Keys)) {
        $before = $null
        if ($Context.Variable.Contains($name)) { $before = $Context.Variable[$name] }

        $Context.Variable[$name] = $fact[$name]
        $written++

        # WHAT MOVED IS WORTH A LINE IN THE LOG. On the second gather of a
        # deployment that is the whole reason the step ran, and on the first it
        # is empty - which is also the right answer.
        if ([string] $before -ne [string] $fact[$name]) {
            [void] $changed.Add(('{0}: {1} -> {2}' -f $name, $before, $fact[$name]))
        }
    }

    foreach ($line in $changed) {
        Write-HDTLog -Context $Context.Log -Message $line -Severity Debug -Event var.resolve -Component 'Gather'
    }

    $message = '{0} machine facts gathered, {1} changed.' -f $written, @($changed).Count

    Write-HDTLog -Context $Context.Log -Message $message -Severity Info -Event step.complete -Component 'Gather'

    return (New-HDTStepResult -Status Completed -Message $message `
            -Data ([ordered] @{ gathered = $written; changed = @($changed).Count }))
}
