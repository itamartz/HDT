function Get-HDTFailureClass {
    <#
        .SYNOPSIS
            Classifies a failure as Transient, Configuration or Environment
            (DESIGN 12.1).

        .DESCRIPTION
            "Engine code wraps each step in a single try/catch that classifies
            failures as Transient (retry per the step's retry policy),
            Configuration (bad authoring - fail fast, point at the file and
            line), or Environment (hardware/network - fail with diagnostics
            attached)."

            The classification decides whether the step is retried, so it is not
            decoration. The signals, in the order they are read:

              a timeout                                            Environment
              FullyQualifiedErrorId starting HDTConfigurationError  Configuration
              one of the DESIGN 9.1 refusal ids                     Configuration
              System.IO.*, Win32Exception, TimeoutException         Environment
              anything else, including a Failed result with an
              exit code and no exception at all                     Transient

            THE REFUSAL IDS ARE A NAMED LIST, NOT A WILDCARD. DESIGN 9.1's
            refusal to guess which disk to wipe, and 9.2's refusal to guess
            which image index to apply, are bad authoring rather than bad luck -
            a refusal that got retried three times would spend a deployment's
            time proving the same point twice more. They carry their own ids
            rather than HDTConfigurationError so a log reader can tell a wipe
            refusal from a malformed YAML file. Matching 'HDT*Error' instead
            would silently swallow every id a later phase invents, including
            ones that really are transient.

            A CONFIGURATION FAILURE IS NEVER RETRIED by the caller. Retrying bad
            authoring spends a deployment's time three times over and buries the
            message that would have fixed it under two more copies of itself.

            A TIMEOUT OUTRANKS EVERY OTHER SIGNAL. A step that was still running
            when its bound expired did not tell us why, and "it took too long on
            this machine" is an environment fact whatever the step was doing.

            IT UNWRAPS TO THE INNERMOST EXCEPTION FIRST. Every real adapter is a
            ScriptMethod on a pscustomobject, and a ScriptMethod wraps whatever
            it threw in MethodInvocationException over RuntimeException
            (tests/helpers/README.md section 5). A classifier that read only the
            outer type would call every adapter failure Transient and retry a
            missing install.wim three times.

        .PARAMETER ErrorRecord
            The caught ErrorRecord, or a bare Exception, or nothing. Nothing is
            Transient: a step that returned a Failed result with an exit code
            reported a failure without an exception, and an exit code is the
            classic retryable case.

        .PARAMETER TimedOut
            The step overran its timeoutMinutes. Environment, whatever else the
            record says.

        .OUTPUTS
            System.String - Transient, Configuration or Environment.

        .EXAMPLE
            try { ... } catch { $class = Get-HDTFailureClass -ErrorRecord $_ }

        .EXAMPLE
            Get-HDTFailureClass -TimedOut
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $ErrorRecord,

        [Parameter()]
        [switch] $TimedOut
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($TimedOut) {
        return 'Environment'
    }

    if ($null -eq $ErrorRecord) {
        return 'Transient'
    }

    # DESIGN 9.1 and 9.2's refusals. Named, never a wildcard.
    $configurationErrorId = @(
        'HDTConfigurationError',
        'HDTAmbiguousTargetError',
        'HDTUnsafeTargetError',
        'HDTNoTargetDiskError',
        'HDTAmbiguousImageError'
    )

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        # The id is "<ErrorId>,<FunctionName>", so the comparison is against the
        # part before the first comma rather than the whole string.
        $errorId = ([string] $ErrorRecord.FullyQualifiedErrorId).Split(',')[0]

        if ($configurationErrorId -contains $errorId) {
            return 'Configuration'
        }

        $exception = $ErrorRecord.Exception
    }

    # Down to the original. Two layers for a real adapter, none for a fake.
    while (($exception -is [System.Exception]) -and ($null -ne $exception.InnerException)) {
        $exception = $exception.InnerException
    }

    if ($exception -is [System.IO.IOException] -or
        $exception -is [System.ComponentModel.Win32Exception] -or
        $exception -is [System.TimeoutException] -or
        $exception -is [System.UnauthorizedAccessException]) {

        return 'Environment'
    }

    return 'Transient'
}
