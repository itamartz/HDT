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
        [string] $Status = 'Running',

        # WHERE THE CONSOLE LOOKS. <share>\Logs\_active\<RunId>.json, which
        # Get-HDTConsoleMonitor tails. Empty means write locally and nothing
        # else - a full-OS leg with no share, or a caller that has no console
        # to feed.
        [Parameter()]
        [AllowEmptyString()]
        [string] $ActivePath = ''
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

    $json = ConvertTo-Json -InputObject $document -Depth 4

    if ($PSCmdlet.ShouldProcess($Path, 'Write run status')) {
        $Context.FileSystem.WriteAllText($Path, $json)
    }

    # -- and a copy where somebody watching can see it ------------------------
    #
    # MDT'S SLShareDynamicLogging, WHICH IS THE HALF HDT WAS MISSING. HDTSLShare
    # says where the logs go when a run ENDS; this is what puts something on the
    # share while the machine is still working, so an administrator can watch
    # rather than wait.
    #
    # THE CONSOLE WAS ALREADY BUILT FOR IT. Get-HDTConsoleMonitor tails
    # <share>\Logs\_active\ and rebuilds that branch every fifteen seconds, and
    # the help above this function has always said the status was mirrored
    # there. Nothing wrote it: the Monitoring branch could not show a live
    # deployment, and on the first one anybody watched it stayed empty from
    # start to finish.
    #
    # ONE DOCUMENT, TWO PATHS. Not a second shape for a second reader - the
    # console parses exactly what the machine wrote locally.
    #
    # AND THE SHARE IS NEVER ALLOWED TO END A DEPLOYMENT. The local write is the
    # one that matters; this is a courtesy to somebody watching, and a machine
    # that stopped deploying because nobody was would be absurd. A share that
    # has gone is also the case this is most useful in.
    if (-not [string]::IsNullOrWhiteSpace($ActivePath)) {
        try {
            if ($PSCmdlet.ShouldProcess($ActivePath, 'Mirror run status for the console')) {
                $Context.FileSystem.WriteAllText($ActivePath, $json)
            }
        } catch {
            Write-Verbose ("the run status could not be mirrored to '{0}': {1}" -f
                $ActivePath, $_.Exception.Message)
        }
    }
}
