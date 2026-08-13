function Invoke-HDTStepAttempt {
    <#
        .SYNOPSIS
            Runs one step, catches whatever it did, and reports the outcome in
            one shape.

        .DESCRIPTION
            Between the loop and Invoke-HDTStep sits everything that is true of
            EVERY step and of no step type in particular: how long it took, how
            many attempts it took, whether it overran its timeout, and which of
            DESIGN 12.1's three classes its failure belongs to.

            AN EXCEPTION IS CAUGHT HERE, not by Invoke-HDTStep. The dispatcher
            deliberately does not catch, because classifying, retrying and
            honouring continueOnError all belong to the caller that owns the
            state document. This is that caller's other half: a step that threw
            becomes a Failed result carrying the message and the class, so the
            loop branches on Status and nothing else.

            The duration is measured through the injected clock, never
            Get-Date or a Stopwatch, so a test can make a step take an hour
            without waiting one (PROJECT constraint 4).

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Attempt is set before each
            attempt, so a step can tell a retry from a first try.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry, discovered once per run by the
            loop.

        .OUTPUTS
            System.Management.Automation.PSCustomObject: Status, ExitCode,
            Message, Data, Attempt, DurationMs, TimedOut, FailureClass.

        .EXAMPLE
            $outcome = Invoke-HDTStepAttempt -Step $step -Context $context -StepType $registry
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $clock = $Context.Service.Clock
    $attempt = 1

    $Context.Attempt = $attempt

    Write-HDTLog -Context $Context.Log -Event 'step.start' `
        -Message ("step {0} '{1}' ({2}) starting, attempt {3}" -f $Step.Index, $Step.Name, $Step.Type, $attempt) `
        -Data ([ordered] @{ index = [int] $Step.Index; name = [string] $Step.Name; type = [string] $Step.Type; attempt = $attempt })

    $failureClass = $null
    $startedUtc = $clock.GetUtcNow()

    try {
        $result = Invoke-HDTStep -Step $Step -Context $Context -StepType $StepType
    } catch {
        $failureClass = Get-HDTFailureClass -ErrorRecord $_
        $result = New-HDTStepResult -Status Failed -Message ([string] $_.Exception.Message)
    }

    $endedUtc = $clock.GetUtcNow()
    $durationMs = [long] ($endedUtc - $startedUtc).TotalMilliseconds

    if ([string] $result.Status -eq 'Failed' -and $null -eq $failureClass) {
        $failureClass = Get-HDTFailureClass
    }

    return [pscustomobject] ([ordered] @{
            Status       = [string] $result.Status
            ExitCode     = [int] $result.ExitCode
            Message      = [string] $result.Message
            Data         = $result.Data
            Attempt      = $attempt
            DurationMs   = $durationMs
            TimedOut     = $false
            FailureClass = $failureClass
        })
}
