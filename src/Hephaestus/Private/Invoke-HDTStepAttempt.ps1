function Invoke-HDTStepAttempt {
    <#
        .SYNOPSIS
            Runs one step to its retry limit and reports the outcome in one
            shape.

        .DESCRIPTION
            Between the loop and Invoke-HDTStep sits everything that is true of
            EVERY step and of no step type in particular: how many attempts it
            took, how long it took, whether it overran its timeout, and which of
            DESIGN 12.1's three classes its failure belongs to.

            ATTEMPTS run from 1 to 1 + the step's retry count. The delay before
            attempt N is

              fixed        DelaySecond
              exponential  DelaySecond * 2^(N-2)

            so an exponential policy with delaySeconds: 1 waits 1s, 2s, 4s. The
            wait is taken through the injected IClock, never Start-Sleep, which
            is what lets a twenty-minute backoff policy be proven in
            milliseconds (PROJECT constraint 4).

            A CONFIGURATION FAILURE IS NEVER RETRIED. Retrying bad authoring
            spends a deployment's time three times over and buries the message
            that would have fixed it under two more copies of itself.

            AN EXCEPTION IS CAUGHT HERE, not by Invoke-HDTStep. The dispatcher
            deliberately does not catch, because classifying, retrying and
            honouring continueOnError all belong to the caller that owns the
            state document. This is that caller's other half: a step that threw
            becomes a Failed result carrying the message and the class, so the
            loop branches on Status and nothing else.

            TIMEOUTS ARE MEASURED, NOT ENFORCED. `timeoutMinutes` is passed to
            the step - only CommandLine can enforce it, through IProcessService -
            and this measures the elapsed time afterwards against the same bound.
            A step that overran becomes a Failed result with TimedOut set even if
            it returned success, because a step that took an hour when it was
            given a minute did not do what the sequence asked.

            HDT DOES NOT PREEMPT A SYNCHRONOUS STEP. One that hangs in-process
            hangs the sequence, exactly as MDT's does. Running steps in a child
            runspace to make timeouts pre-emptive is a post-v1 idea, and
            ForEach-Object -Parallel is not available to an engine that must run
            under Windows PowerShell 5.1.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Its Retry and
            TimeoutMinutes are the policy this function applies.

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

    $retryCount = 0
    $delaySecond = 0
    $backoff = 'fixed'
    if ($null -ne $Step.Retry) {
        $retryCount = [int] $Step.Retry.Count
        $delaySecond = [int] $Step.Retry.DelaySecond
        $backoff = [string] $Step.Retry.Backoff
    }

    $maximumAttempt = 1 + $retryCount
    $timeoutMillisecond = 0
    if ([int] $Step.TimeoutMinutes -gt 0) {
        $timeoutMillisecond = [long] $Step.TimeoutMinutes * 60000
    }

    $attempt = 0

    while ($true) {
        $attempt++

        if ($attempt -gt 1 -and $delaySecond -gt 0) {
            $wait = $delaySecond
            if ($backoff -eq 'exponential') {
                $wait = $delaySecond * [math]::Pow(2, $attempt - 2)
            }

            $clock.Sleep([int] ($wait * 1000))
        }

        $Context.Attempt = $attempt

        Write-HDTLog -Context $Context.Log -Event 'step.start' `
            -Message ("step {0} '{1}' ({2}) starting, attempt {3} of {4}" -f
                $Step.Index, $Step.Name, $Step.Type, $attempt, $maximumAttempt) `
            -Data ([ordered] @{
                index   = [int] $Step.Index
                name    = [string] $Step.Name
                type    = [string] $Step.Type
                attempt = $attempt
            })

        $thrown = $null
        $startedUtc = $clock.GetUtcNow()

        try {
            $result = Invoke-HDTStep -Step $Step -Context $Context -StepType $StepType
        } catch {
            $thrown = $_
            $result = New-HDTStepResult -Status Failed -Message ([string] $_.Exception.Message)
        }

        $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds

        $timedOut = ($timeoutMillisecond -gt 0 -and $durationMillisecond -gt $timeoutMillisecond)

        if ($timedOut) {
            # Reported as a failure even when the step said it succeeded: a step
            # that took an hour when it was given a minute did not do what the
            # sequence asked.
            $result = New-HDTStepResult -Status Failed -ExitCode ([int] $result.ExitCode) -Data $result.Data `
                -Message ("step {0} '{1}' timed out: it overran its bound of {2} minute(s), taking {3} ms. HDT does not preempt a synchronous step, so it was allowed to finish and its result is reported as a failure." -f
                    $Step.Index, $Step.Name, $Step.TimeoutMinutes, $durationMillisecond)
        }

        $failureClass = $null
        if ([string] $result.Status -eq 'Failed') {
            $failureClass = Get-HDTFailureClass -ErrorRecord $thrown -TimedOut:$timedOut
        }

        $outcome = [pscustomobject] ([ordered] @{
                Status       = [string] $result.Status
                ExitCode     = [int] $result.ExitCode
                Message      = [string] $result.Message
                Data         = $result.Data
                Attempt      = $attempt
                DurationMs   = $durationMillisecond
                TimedOut     = $timedOut
                FailureClass = $failureClass
            })

        if ([string] $result.Status -ne 'Failed') {
            return $outcome
        }

        if ($failureClass -eq 'Configuration') {
            return $outcome
        }

        if ($attempt -ge $maximumAttempt) {
            return $outcome
        }

        Write-HDTLog -Context $Context.Log -Severity Warning `
            -Message ("step {0} '{1}' failed on attempt {2} of {3} ({4}), and will be retried" -f
                $Step.Index, $Step.Name, $attempt, $maximumAttempt, $failureClass) `
            -Data ([ordered] @{ index = [int] $Step.Index; attempt = $attempt; failureClass = $failureClass })
    }
}
