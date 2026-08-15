function Get-HDTConsoleMonitorNode {
    <#
        .SYNOPSIS
            The Monitoring category and the rows beneath it, built on its own.

        .DESCRIPTION
            THE TAILING HALF OF ROADMAP M8's MONITORING VIEW. A view that reads
            the directory once and then shows an hour-old answer is a report
            rather than a monitor - and worse, a report that LOOKS like a
            monitor, which is how somebody comes to believe a machine is fine.
            The console re-runs this on a timer and swaps the node it returns
            into the tree.

            IT IS A SEPARATE BUILDER SO THE REFRESH READS ONE DIRECTORY.
            Rebuilding the whole share subtree would re-read workspace.yaml,
            every sequence document and the boot image manifest - over SMB,
            every few seconds, for a number that lives in one small folder. It
            would also throw away the expansion and the selection an
            administrator had arranged. This reads Logs\_active\ and nothing
            else.

            THE NODE IS REPLACED, NOT MUTATED. A PSCustomObject raises no change
            notification, so editing Text on a row already on screen changes
            nothing anybody can see. Handing WPF a NEW object inside an
            ObservableCollection is what makes the branch redraw - which is why
            this returns a whole category rather than a list of runs, and why
            New-HDTConsoleNode's Children is observable.

            GET-HDTConsoleShareNode CALLS THIS TOO, so the tree as first drawn
            and the tree as refreshed cannot drift into disagreeing about what a
            monitoring row looks like.

            EVERY JUDGEMENT IS Get-HDTConsoleMonitor'S. Nothing here re-reads a
            heartbeat or works out an age; this arranges what that command
            decided into rows.

        .PARAMETER Path
            The deployment share's root.

        .PARAMETER Header
            The banner these rows carry. Built from the share when there is one;
            a refresh passes the header the existing rows already had.

        .PARAMETER StaleMinute
            How long a heartbeat may go unwritten before its run is called
            stalled. Twenty minutes by default, as Get-HDTConsoleMonitor.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .PARAMETER Clock
            An IClockService. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one console node, with
            its run rows already in Children.

        .EXAMPLE
            Get-HDTConsoleMonitorNode -Path 'C:\HDTLab\Share'

        .EXAMPLE
            $category = Get-HDTConsoleMonitorNode -Path $root -Header $header
            $category.Children | ForEach-Object { $_.Text }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds display rows in memory; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object] $Header,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int] $StaleMinute = 20,

        # A READING SOMEBODY ELSE HAS ALREADY TAKEN. Get-HDTConsoleWorkspace
        # reads Logs\_active\ while it opens the share, so the first draw hands
        # that result straight over rather than reading the directory twice in
        # the same second. A refresh omits it and this reads for itself.
        [Parameter()]
        [AllowNull()]
        [object] $Monitor,

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

    # A refresh has the header the rows already carried; a first build passes
    # the share's. Neither is worth making the caller assemble, and a monitoring
    # row that lost its banner would blank the top of the window when selected.
    if ($null -eq $Header) {
        $Header = [pscustomobject] @{ Title = 'Monitoring'; Root = $Path; DeployRoot = $Path }
    }

    $monitor = $Monitor

    if ($null -eq $monitor) {
        $monitor = Get-HDTConsoleMonitor -Path $Path -StaleMinute $StaleMinute `
            -FileSystem $FileSystem -Clock $Clock
    }

    $command = "Get-HDTConsoleMonitorNode -Path '{0}'" -f $Path

    $category = New-HDTConsoleNode -Depth 2 -Kind 'MonitorCategory' -Status 'Ok' `
        -Text $monitor.Caption `
        -Field @(
        New-HDTConsoleField -Label 'Watching' -Value $monitor.ActivePath
        New-HDTConsoleField -Label 'Running' -Value ([string] $monitor.LiveCount)
        New-HDTConsoleField -Label 'Stalled' -Value ([string] $monitor.StalledCount)
        New-HDTConsoleField -Label 'Finished' -Value ([string] $monitor.FinishedCount)
        New-HDTConsoleField -Label 'Unreadable' -Value ([string] $monitor.UnreadableCount)
    ) `
        -Command $command -Header $Header

    foreach ($current in @($monitor.Run)) {
        # A stalled or unreadable run is drawn the way every other broken thing
        # in this tree is drawn, which is what makes it findable by somebody who
        # has never used this screen before.
        $runStatus = 'Ok'
        if ($current.Health -eq 'Stalled' -or $current.Health -eq 'Unreadable') { $runStatus = 'Error' }

        $runRow = New-HDTConsoleNode -Depth 3 -Kind 'MonitorRun' -Status $runStatus `
            -Text $current.Text -Name $current.RunId `
            -Field @(
            New-HDTConsoleField -Label 'Run' -Value $current.RunId
            New-HDTConsoleField -Label 'Health' -Value $current.Health
            New-HDTConsoleField -Label 'Phase' -Value (Get-HDTConsoleDisplayText -Text $current.Phase -Fallback '(unknown)')
            New-HDTConsoleField -Label 'Status' -Value (Get-HDTConsoleDisplayText -Text $current.RunStatus -Fallback '(unknown)')
            New-HDTConsoleField -Label 'Step' -Value (Get-HDTConsoleDisplayText -Text $current.StepName -Fallback '(no step yet)')
            New-HDTConsoleField -Label 'Step type' -Value (Get-HDTConsoleDisplayText -Text $current.StepType -Fallback '(unknown)')
            New-HDTConsoleField -Label 'Step number' -Value (Get-HDTConsoleDisplayText -Text $current.StepText -Fallback '(not started)')
            New-HDTConsoleField -Label 'Last heartbeat' -Value (Get-HDTConsoleDisplayText -Text $current.SinceText -Fallback '(never)')
            New-HDTConsoleField -Label 'Heartbeat file' -Value $current.Path
        ) `
            -Command $current.Command -Header $Header

        [void] $category.Children.Add($runRow)
    }

    # An empty category reads as a broken one. This says which it is.
    if (@($monitor.Run).Count -eq 0) {
        $empty = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' `
            -Text $monitor.Summary `
            -Field @(
            New-HDTConsoleField -Label 'Watching' -Value $monitor.ActivePath
            New-HDTConsoleField -Label '' -Value ('The engine writes a heartbeat here for each step of each running deployment (DESIGN 4.4.6). Nothing is running on this share, or nothing has run since this folder was last cleared.')
        ) `
            -Command $command -Header $Header

        [void] $category.Children.Add($empty)
    }

    return $category
}
