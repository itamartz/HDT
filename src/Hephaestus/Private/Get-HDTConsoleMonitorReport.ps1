function Get-HDTConsoleMonitorReport {
    <#
        .SYNOPSIS
            Whether a run the monitoring view is showing has a report to open,
            and what it takes to render it.

        .DESCRIPTION
            THE LAST CLAUSE OF DESIGN 12'S MONITORING VIEW: "tails Logs\_active\,
            showing in-flight deployments, current step, and elapsed time; opens
            the full report on completion". ConvertTo-HDTReport has rendered that
            report since M2 and nothing in the console called it, so this is the
            half that was missing - the decision, made away from the window so it
            can be tested.

            THE HEARTBEAT DOES NOT SAY WHICH MACHINE IT IS. Write-HDTStatus
            writes runId, phase, status, step and updated; Copy-HDTLog files the
            finished log under '<ComputerName>-<RunId>'. So the run's log is
            found by looking for the folder that ENDS in the run id, and the
            machine's name is what is left when that suffix comes off. It is the
            only place on the share the name is written down next to the run.

            A SUFFIX, NOT A SUBSTRING. 'run-0007' and 'run-00071' are different
            deployments and a Contains match would open the wrong machine's
            report - quietly, because both files render.

            NOT FOUND IS TWO ANSWERS, NOT ONE. A run still going has no log on
            the share YET, and will have one; a run that died before copy-back
            has none and never will. Telling a technician "no report" in both
            cases hides the difference that matters - and the dead run is the one
            they wanted the report for.

            THE REPORT IS WRITTEN BESIDE THE LOG IT CAME FROM. Not a temp folder,
            which nobody can attach to a ticket, and not the share root, which
            fills up with one file per deployment. A run folder copied somewhere
            else carries its own report, and a second click overwrites rather
            than accumulates.

            IT RENDERS NOTHING AND OPENS NOTHING. This is a query: it reads the
            share and returns paths, so the window's handler is one call to
            ConvertTo-HDTReport and one to Start-Process, with no branch of its
            own to test.

        .PARAMETER Path
            The deployment share's root.

        .PARAMETER RunId
            The run, as the heartbeat file names it.

        .PARAMETER Health
            What Get-HDTConsoleMonitor made of that run. Only 'Live' changes the
            answer: it is the one state where an absent log is expected rather
            than lost.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Status        'Ok', 'Pending' or 'Missing'
              Message       what to say when there is no report
              RunId         the run asked about
              ComputerName  recovered from the log folder's name
              JsonlPath     the stream to render, empty unless Ok
              ReportPath    where the report goes, empty unless Ok
              Title         the report's heading
              Command       the ConvertTo-HDTReport line, as it would be typed

        .EXAMPLE
            Get-HDTConsoleMonitorReport -Path 'C:\HDTLab\Share' -RunId 'run-0007' -Health 'Finished'

        .EXAMPLE
            $report = Get-HDTConsoleMonitorReport -Path $share -RunId $row.RunId -Health $row.Health
            if ($report.Status -eq 'Ok') {
                Start-Process (ConvertTo-HDTReport -JsonlPath $report.JsonlPath -Path $report.ReportPath -Title $report.Title)
            }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true, Position = 2)]
        # ALL SIX, AND IT USED TO BE FOUR. New-HDTConsoleMonitorRow answers
        # Live, Finished, Failed, Rebooting, Stalled or Unreadable; this
        # accepted only four of them, so opening the report on a run that had
        # FAILED - or one part-way through a reboot - threw a parameter
        # validation error out of a click handler and closed the console.
        #
        # Failed and Rebooting arrived with a866d60, which fixed a failed
        # deployment being drawn as a green finished one. The producing side
        # grew two values and this consuming side did not, and nothing checked
        # the two against each other: a ValidateSet is a contract with whoever
        # calls it, and half a contract is worse than none because it fails at
        # the call rather than at the build.
        #
        # THE CONSOLE LOG IS WHAT FOUND IT, on the day the log was added -
        # 'Get-HDTConsoleMonitorReport threw: ... does not belong to the set'.
        # Before that, this was a window that vanished.
        [ValidateSet('Live', 'Stalled', 'Finished', 'Unreadable', 'Failed', 'Rebooting')]
        [string] $Health,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $logRoot = Get-HDTWorkspacePath -Root $Path -Kind Logs

    $found = ''

    # A share that has never deployed anything has no Logs folder, and the
    # console opens on new shares more often than on any other kind.
    if ($FileSystem.TestPath($logRoot)) {
        $suffix = '-{0}' -f $RunId

        # Sorted so a share that somehow holds two folders for one run id
        # answers the same way twice rather than by directory order.
        $candidate = @(@($FileSystem.GetDirectory($logRoot)) | Sort-Object)

        foreach ($directory in $candidate) {
            $leaf = [System.IO.Path]::GetFileName([string] $directory)

            if (-not $leaf.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            # A FOLDER IS NOT A REPORT. A copy-back interrupted halfway leaves
            # the directory and no stream, and ConvertTo-HDTReport would refuse
            # it - after the window had already promised a report.
            $stream = Join-Path -Path ([string] $directory) -ChildPath 'HDT.jsonl'

            if ($FileSystem.TestPath($stream)) {
                $found = [string] $directory
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($found)) {

        # STILL RUNNING IS NOT MISSING. The copy back happens when the sequence
        # ends, so this says when rather than what went wrong.
        if ($Health -eq 'Live') {
            return [pscustomobject] @{
                Status       = 'Pending'
                Message      = ("'{0}' is still deploying. Its log is copied back to the share when the sequence finishes, and the report is rendered from it then." -f $RunId)
                RunId        = $RunId
                ComputerName = ''
                JsonlPath    = ''
                ReportPath   = ''
                Title        = ''
                Command      = ''
            }
        }

        return [pscustomobject] @{
            Status       = 'Missing'
            Message      = ("no log for '{0}' under '{1}'. Copy-HDTLog files a finished run in '<ComputerName>-{0}'; a deployment that ended before it got there never left one." -f $RunId, $logRoot)
            RunId        = $RunId
            ComputerName = ''
            JsonlPath    = ''
            ReportPath   = ''
            Title        = ''
            Command      = ''
        }
    }

    $name = [System.IO.Path]::GetFileName($found)
    $computerName = $name.Substring(0, $name.Length - ('-{0}' -f $RunId).Length)

    $jsonlPath = Join-Path -Path $found -ChildPath 'HDT.jsonl'
    $reportPath = Join-Path -Path $found -ChildPath 'report.html'

    # NAMED FOR THE MACHINE, because a technician looking at four open reports
    # is choosing between machines, not between HDT and HDT.
    $title = '{0} deployment report' -f $computerName

    return [pscustomobject] @{
        Status       = 'Ok'
        Message      = ''
        RunId        = $RunId
        ComputerName = $computerName
        JsonlPath    = $jsonlPath
        ReportPath   = $reportPath
        Title        = $title

        # M8's other half - every action displays the cmdlet it invokes.
        Command      = ("ConvertTo-HDTReport -JsonlPath '{0}' -Path '{1}' -Title '{2}'" -f $jsonlPath, $reportPath, $title)
    }
}
