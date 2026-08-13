function Invoke-HDTNoOpStep {
    <#
        .SYNOPSIS
            The step type that does nothing, on purpose.

        .DESCRIPTION
            NoOp is how the engine is tested. It logs a message and returns a
            result whose Status the sequence author chose, so 03-04's loop can
            prove retry, continueOnError, skipping and reboot resume against a
            sequence that touches nothing.

              message        the text it logs and returns
              fail           true  -> Failed, always
              failAttempt    N     -> Failed while Context.Attempt is at or below
                                      N, Completed afterwards. failAttempt: 2
                                      fails attempts 1 and 2 and succeeds on 3
              exitCode       the exit code a failure reports
              requestReboot  true  -> RebootRequested

            failAttempt is the important one: it is a FLAKY STEP WITHOUT A FLAKY
            THING. Proving a retry policy against something genuinely
            intermittent would give a test that fails one run in twenty and
            teaches everyone to re-run the suite.

            IT REACHES NOTHING BUT THE LOG. A NoOp sequence must be runnable with
            a catalog carrying only IFileSystem and IClock, which is what makes
            it usable as the engine's own scaffolding.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult.

        .EXAMPLE
            - name: Flaky thing
              type: NoOp
              failAttempt: 2
              retry:
                count: 3

            The sequence.yaml that proves a retry policy.
    #>
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

    $property = $Step.Property

    $message = [string] $Step.Name
    if ($null -ne $property -and $property.Contains('message')) {
        $message = [string] $property['message']
    }

    $exitCode = 0
    if ($null -ne $property -and $property.Contains('exitCode')) {
        $exitCode = [int] $property['exitCode']
    }

    $fail = $false
    if ($null -ne $property -and $property.Contains('fail')) {
        $fail = [bool] $property['fail']
    }

    $failAttempt = 0
    if ($null -ne $property -and $property.Contains('failAttempt')) {
        $failAttempt = [int] $property['failAttempt']
    }

    $requestReboot = $false
    if ($null -ne $property -and $property.Contains('requestReboot')) {
        $requestReboot = [bool] $property['requestReboot']
    }

    if ($fail -or ($failAttempt -gt 0 -and [int] $Context.Attempt -le $failAttempt)) {
        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail `
            -Component 'NoOp' -Data ([ordered] @{ attempt = [int] $Context.Attempt; exitCode = $exitCode })

        return (New-HDTStepResult -Status Failed -ExitCode $exitCode -Message $message)
    }

    if ($requestReboot) {
        Write-HDTLog -Context $Context.Log -Message $message -Event message -Component 'NoOp' `
            -Data ([ordered] @{ attempt = [int] $Context.Attempt; requestReboot = $true })

        return (New-HDTStepResult -Status RebootRequested -Message $message)
    }

    Write-HDTLog -Context $Context.Log -Message $message -Event message -Component 'NoOp' `
        -Data ([ordered] @{ attempt = [int] $Context.Attempt })

    return (New-HDTStepResult -Status Completed -Message $message)
}
