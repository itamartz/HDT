function Get-HDTConsoleMonitor {
    <#
        .SYNOPSIS
            Which deployments are in flight on a share, and where each has got to.

        .DESCRIPTION
            The monitoring view:
            "tails Logs\_active\, showing in-flight deployments, current step,
            and elapsed time". The engine's heartbeat is the other half of the same
            decision - "The engine writes a small status.json heartbeat to
            <share>\Logs\_active\<RunId>.json each step. The console tails that
            directory. No web service, no SQL, no MDT Monitoring dependency."

            SO THE WHOLE FEATURE IS A DIRECTORY LISTING AND SOME ARITHMETIC, and
            both belong here rather than in the window. The console re-runs this
            on a timer and assigns what comes back; it works nothing out, which
            is what leaves the adapter exempt from TDD.

            THE CLOCK IS INJECTED. "How long since this said anything" is the
            one number on the screen that changes with nothing being written,
            and a command that read the wall clock could only be tested by
            sleeping. It is the ENGINE'S IClockService, so the console measures
            time the same way the deployment writing these files does.

            A HEARTBEAT THAT STOPPED IS THE POINT OF THE SCREEN. A deployment
            that died - power, network, a bugcheck - leaves its last heartbeat
            behind and never writes another. Nothing else in HDT will ever
            notice, because there is nothing left running to notice it. Health
            is therefore computed from the age of the file's own timestamp
            rather than taken from its status, which will still say Running.

            BUT A FINISHED RUN IS NOT A STALLED ONE, however old. Ageing a
            Succeeded heartbeat into a red row is how a screen learns to cry
            wolf, and a technician who has been trained to ignore red will
            ignore the one that mattered.

            THE THRESHOLD IS GENEROUS AND SETTABLE. The engine writes one per
            STEP and a step can legitimately take a long time - applying an
            image is minutes, and a driver pass on slow media is longer. Twenty
            minutes is the default because it is comfortably past the slowest
            ordinary step and comfortably short of a lunch break.

            MOST RECENT FIRST. A technician watching twenty machines wants the
            one that just moved at the top, not the one whose id sorts first.

            AN UNREADABLE HEARTBEAT IS STILL A RUN. A file caught mid-write, or
            truncated by a machine that lost power between the open and the
            flush, describes a deployment that exists; dropping the row would
            take the machine off the screen at the exact moment it most needs to
            be on it. Its id comes from the file name, which is the one thing
            still legible.

        .PARAMETER Path
            The deployment share's root.

        .PARAMETER StaleMinute
            How long a heartbeat may go unwritten before its run is called
            stalled. Twenty minutes by default.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .PARAMETER Clock
            An IClockService. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Status, Message   whether the directory could be read
              Run               one row per heartbeat, most recent first
              Summary           the line a person scans
              LiveCount, StalledCount, FinishedCount, UnreadableCount

        .EXAMPLE
            (Get-HDTConsoleMonitor -Path 'C:\HDTLab\Share').Run |
                Format-Table RunId, Phase, StepName, SinceText, Health

        .EXAMPLE
            Get-HDTConsoleMonitor -Path '\\192.168.2.108\HDTShare' -StaleMinute 45
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int] $StaleMinute = 20,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Clock
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Clock) { $Clock = New-HDTClock }

    $activePath = Join-Path -Path (Get-HDTWorkspacePath -Root $Path -Kind Logs) -ChildPath '_active'

    $now = $Clock.GetUtcNow().ToUniversalTime()

    $run = New-Object -TypeName System.Collections.ArrayList

    # A share that has never run a deployment has no such directory, and a
    # console that refused to open on it would be refusing on the commonest
    # share there is - a new one.
    $child = @()

    if ($FileSystem.TestPath($activePath)) {
        $child = @($FileSystem.GetChildItem($activePath))
    }

    foreach ($file in $child) {
        if ([System.IO.Path]::GetExtension([string] $file) -ne '.json') { continue }

        $runId = [System.IO.Path]::GetFileNameWithoutExtension([string] $file)

        $document = $null

        try {
            $document = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText([string] $file))
        } catch {
            $document = $null
        }

        [void] $run.Add((New-HDTConsoleMonitorRow -RunId $runId -Path ([string] $file) `
                    -Document $document -Now $now -StaleMinute $StaleMinute))
    }

    # Most recent first. A row that could not be read has no timestamp of its
    # own, and sorts to the top - which is where a machine nobody can see the
    # state of belongs.
    $ordered = @($run | Sort-Object -Property @{ Expression = 'SinceSecond'; Descending = $false })

    $live = @($ordered | Where-Object { $_.Health -eq 'Live' })
    $stalled = @($ordered | Where-Object { $_.Health -eq 'Stalled' })
    $finished = @($ordered | Where-Object { $_.Health -eq 'Finished' })
    $unreadable = @($ordered | Where-Object { $_.Health -eq 'Unreadable' })
    # A FAILED RUN AND A REBOOTING ONE USED TO BE COUNTED AS FINISHED, because
    # Health called both of them that. See New-HDTConsoleMonitorRow.
    $failed = @($ordered | Where-Object { $_.Health -eq 'Failed' })
    $rebooting = @($ordered | Where-Object { $_.Health -eq 'Rebooting' })

    return [pscustomobject] @{
        Status          = 'Ok'
        Message         = ''
        Run             = [pscustomobject[]] @($ordered)
        Summary         = (Get-HDTConsoleMonitorSummary -Live @($live).Count -Stalled @($stalled).Count `
                -Finished @($finished).Count -Unreadable @($unreadable).Count `
                -Failed @($failed).Count -Rebooting @($rebooting).Count)

        # The same fact in the form a tree row wears it - see the -Caption note
        # on Get-HDTConsoleMonitorSummary for why the quiet case is not a
        # sentence in brackets.
        Caption         = (Get-HDTConsoleMonitorSummary -Live @($live).Count -Stalled @($stalled).Count `
                -Finished @($finished).Count -Unreadable @($unreadable).Count `
                -Failed @($failed).Count -Rebooting @($rebooting).Count -Caption)
        LiveCount       = @($live).Count
        StalledCount    = @($stalled).Count
        FinishedCount   = @($finished).Count
        UnreadableCount = @($unreadable).Count
        FailedCount     = @($failed).Count
        RebootingCount  = @($rebooting).Count
        ActivePath      = $activePath
    }
}
