function Update-HDTRunStateStep {
    <#
        .SYNOPSIS
            Records the outcome of one step in the run state document.

        .DESCRIPTION
            DESIGN 4.3: "every step is idempotent or checkpointed. On resume the
            engine skips completed steps by index and re-runs the interrupted one
            only if the step declares resumable: true."

            stepIndex is the 1-based index of the NEXT step to run, so this
            advances it past a step that Completed or was Skipped and LEAVES IT
            ALONE for one that is Running, Failed or still Pending. A failed run
            therefore resumes AT the failure rather than after it - otherwise the
            technician who fixes the cause never gets the step retried, and the
            deployment continues on top of work that never happened.

            The document is mutated in memory and returned; nothing is written
            and no clock is read. Save-HDTRunState stamps updatedUtc and
            checkpoints it.

            Timestamps are stored as formatted strings, never as [datetime]
            objects, because a raw date serialises as "\/Date(...)\/" under
            Windows PowerShell 5.1.

        .PARAMETER State
            A New-HDTRunState or Import-HDTRunState result.

        .PARAMETER Index
            The 1-based step index to update.

        .PARAMETER Status
            Pending, Running, Completed, Failed or Skipped.

        .PARAMETER Attempt
            How many times the step has been started. 03-04's retry policy
            increments it.

        .PARAMETER ExitCode
            The step's exit code. Zero is a result, not an absence, so it is
            recorded when supplied.

        .PARAMETER Message
            A one-line explanation, typically the failure.

        .PARAMETER StartedUtc
            When the step started. Converted to UTC and formatted.

        .PARAMETER EndedUtc
            When the step ended. Converted to UTC and formatted.

        .PARAMETER DurationMs
            How long the step took.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the same state object,
            so a caller can pipe straight into Save-HDTRunState.

        .EXAMPLE
            Update-HDTRunStateStep -State $state -Index 3 -Status Failed `
                -ExitCode 2 -Message 'DISM returned 0x80070002' | Out-Null
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory document; Save-HDTRunState is what writes and it declares ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $State,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Index,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Pending', 'Running', 'Completed', 'Failed', 'Skipped')]
        [string] $Status,

        [Parameter()]
        [int] $Attempt,

        [Parameter()]
        [int] $ExitCode,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [datetime] $StartedUtc,

        [Parameter()]
        [datetime] $EndedUtc,

        [Parameter()]
        [long] $DurationMs
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    $target = @(@($State.step) | Where-Object { [int] $_.index -eq $Index })

    if ($target.Count -ne 1) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("step index {0} is not in this sequence, which has {1} step(s). A step result can only be recorded against a step the sequence declares." -f $Index, @($State.step).Count)))
    }

    $step = $target[0]
    $step.status = $Status

    if ($PSBoundParameters.ContainsKey('Attempt')) {
        $step.attempt = $Attempt
    }

    if ($PSBoundParameters.ContainsKey('ExitCode')) {
        $step.exitCode = $ExitCode
    }

    if ($PSBoundParameters.ContainsKey('Message')) {
        $step.message = $Message
    }

    if ($PSBoundParameters.ContainsKey('StartedUtc')) {
        $step.startedUtc = $StartedUtc.ToUniversalTime().ToString('o', $invariant)
    }

    if ($PSBoundParameters.ContainsKey('EndedUtc')) {
        $step.endedUtc = $EndedUtc.ToUniversalTime().ToString('o', $invariant)
    }

    if ($PSBoundParameters.ContainsKey('DurationMs')) {
        $step.durationMs = $DurationMs
    }

    # Completed and Skipped are the only outcomes that move on. Failed stays put
    # so a resume retries the step that failed.
    if (@('Completed', 'Skipped') -contains $Status) {
        $State.stepIndex = $Index + 1
    }

    return $State
}
