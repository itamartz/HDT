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
            decoration:

              FullyQualifiedErrorId starting HDTConfigurationError  Configuration
              anything else                                         Transient

            A CONFIGURATION FAILURE IS NEVER RETRIED. Retrying bad authoring
            spends a deployment's time three times over and buries the message
            that would have fixed it under two more copies of itself.

        .PARAMETER ErrorRecord
            The caught ErrorRecord, or an Exception, or nothing. Nothing is
            Transient: a step that returned a Failed result with an exit code
            reported a failure without an exception, and an exit code is the
            classic retryable case.

        .OUTPUTS
            System.String - Transient, Configuration or Environment.

        .EXAMPLE
            try { ... } catch { $class = Get-HDTFailureClass -ErrorRecord $_ }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $ErrorRecord
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $ErrorRecord) {
        return 'Transient'
    }

    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ([string] $ErrorRecord.FullyQualifiedErrorId -like 'HDTConfigurationError*') {
            return 'Configuration'
        }
    }

    return 'Transient'
}
