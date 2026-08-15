function Update-HDTProgressDisplay {
    <#
        .SYNOPSIS
            Tells the progress display what the log now says. Never fails a
            deployment.

        .DESCRIPTION
            DESIGN 11.1'S SUBSCRIPTION, and deliberately the dullest possible
            one: the engine has just written a record to the JSONL, so this
            reads the JSONL back, derives progress from it with
            Get-HDTDeploymentProgress and hands that to whatever host is
            attached.

            NO SECOND CHANNEL. There is no progress API a step can call and no
            in-memory tally kept beside the log, because "there is exactly one
            source of truth for what the deployment is doing, so the screen and
            the log can never disagree" (DESIGN 11.1). A tally would be a second
            truth, and the first thing it would do is drift on a resume.

            IT MUST NEVER FAIL A DEPLOYMENT, AND THAT IS THE WHOLE OF ITS ERROR
            HANDLING. This runs inside the step loop, on a machine part-way
            through partitioning a disk. A log line the machine was cut off in
            the middle of writing, a file that went with the RAM disk at the
            relocation, a UI runspace that has died - none of those is a reason
            to stop building a computer, and every one of them is a failure
            nobody would ever guess at from the outside. So everything is
            caught, and the deployment carries on.

            A HALF-WRITTEN LINE IS SKIPPED, NOT FATAL. A JSONL whose last line
            is a fragment is exactly what a machine that died mid-step leaves
            behind - and the window showing that run must not be the second
            thing that dies.

            NO PROGRESS SERVICE IS THE NORMAL CASE and costs nothing: it returns
            before reading anything. A run nobody asked for a screen on does not
            read its own log once per step to draw one.

        .PARAMETER Context
            The execution context. Only Context.Service.Progress and
            Context.Log are read, and both may be absent.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None.

        .EXAMPLE
            Update-HDTProgressDisplay -Context $Context

            What the step loop calls after each step's outcome is written.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates a status display; it changes no system state and runs inside a step loop where a confirmation prompt would hang a deployment.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # EVERY EXIT BEFORE THE READ IS FREE. See the header: a run with no display
    # must not pay for one.
    try {
        if ($null -eq $Context) { return }
        if ($null -eq $Context.PSObject.Properties['Service'] -or $null -eq $Context.Service) { return }
        if ($null -eq $Context.Service.PSObject.Properties['Progress']) { return }

        $display = $Context.Service.Progress
        if ($null -eq $display) { return }

        if ($null -eq $Context.PSObject.Properties['Log'] -or $null -eq $Context.Log) { return }

        $log = $Context.Log
        if ($null -eq $log.PSObject.Properties['JsonlPath'] -or $null -eq $log.PSObject.Properties['FileSystem']) { return }

        $path = [string] $log.JsonlPath
        if ([string]::IsNullOrWhiteSpace($path)) { return }

        $fileSystem = $log.FileSystem
        if ($null -eq $fileSystem -or -not $fileSystem.TestPath($path)) { return }

        $text = [string] $fileSystem.ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($text)) { return }

        $record = @()
        foreach ($line in ($text -split "`n")) {

            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

            # PER LINE, BECAUSE ONE BAD LINE MUST NOT COST THE OTHERS. JSON Lines
            # is one object per physical line precisely so a reader can do this.
            try {
                $record += ConvertFrom-Json -InputObject $trimmed
            } catch {
                continue
            }
        }

        if (@($record).Count -eq 0) { return }

        $display.Update((Get-HDTDeploymentProgress -Record $record))
    } catch {
        # THE LAST LINE OF THE CONTRACT. A progress bar does not get to stop a
        # deployment, whatever happened to it.
        Write-Verbose ("the progress display could not be updated: {0}" -f [string] $_.Exception.Message)
    }
}
