function Write-HDTStatus {
    <#
        .SYNOPSIS
            Writes the status.json heartbeat.

        .DESCRIPTION
            "The engine writes a small status.json heartbeat each step. The
            console tails that directory. No web service, no SQL, no MDT
            Monitoring dependency".

            It OVERWRITES rather than appends, which makes it the one log-adjacent
            writer that uses WriteAllText: a heartbeat is the current state of a
            run, not a history of it, and a console tailing a directory wants to
            read one small object rather than seek to the end of a growing file.

            The document:

              { "schemaVersion": 1, "runId", "phase", "status", "stepIndex",
                "stepCount", "stepName", "stepType", "updated" }

            THE TIMESTAMP IS A FORMATTED STRING. ConvertTo-Json renders a raw
            [datetime] as "\/Date(...)\/" under Windows PowerShell 5.1, which is
            the engine running in WinPE where this file is written.

        .PARAMETER Context
            A New-HDTLogContext result. Supplies the run id, the phase, the
            current step, the injected filesystem and the injected clock.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\status.json, and
            mirrored to <share>\Logs\_active\<RunId>.json for the console.

        .PARAMETER Status
            The run status. Defaults to Running.

        .OUTPUTS
            None.

        .EXAMPLE
            Write-HDTStatus -Context $context -Path (Join-Path $context.LogPath 'status.json')
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Status = 'Running'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $updated = $Context.Clock.GetUtcNow().ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $document = [ordered] @{
        schemaVersion = 1
        runId         = $Context.RunId
        phase         = $Context.Phase
        status        = $Status
        stepIndex     = $Context.StepIndex

        # ALWAYS PRESENT, EVEN AS ZERO. A key that is sometimes absent is a key
        # every reader has to test for, and this one is read by a console that
        # may be looking at a share written by an older engine.
        stepCount     = $Context.StepCount
        stepName      = $Context.StepName
        stepType      = $Context.StepType
        updated       = $updated
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write run status')) {
        $Context.FileSystem.WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 4))
    }
}
