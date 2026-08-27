function Get-HDTConsoleMonitorNode {
    <#
        .SYNOPSIS
            The Monitoring category and the rows beneath it, built on its own.

        .DESCRIPTION
            THE TAILING HALF OF THE MONITORING VIEW. A view that reads
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

        # WHICH RUN WAS SELECTED WHEN THIS BRANCH WAS LAST DRAWN, so the refresh
        # can hand the highlight back to it.
        #
        # THE BRANCH IS REPLACED, NOT EDITED - that is what makes it tail - so
        # the row object that WAS selected stops existing every few seconds and
        # WPF drops the highlight to the Monitoring container, taking the detail
        # pane and the Open Report button with it. A technician watching one
        # machine lost it on a timer. IsSelected is carried on the row for
        # exactly this, and it is read at container-generation time, so it has
        # to be set before the tree is handed the rows.
        [Parameter()]
        [AllowEmptyString()]
        [string] $SelectedName = '',

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
        # A FAILURE HAS TO LOOK LIKE ONE. Failed was drawn 'Ok' - the same green
        # as a machine that deployed perfectly - because Health called it
        # Finished. Rebooting stays 'Ok': it is in flight, not wrong.
        $runStatus = 'Ok'
        if ($current.Health -eq 'Stalled' -or $current.Health -eq 'Unreadable' -or
            $current.Health -eq 'Failed') { $runStatus = 'Error' }

        # THE ROW CARRIES THE RUN, so Open Report can ask whether this
        # deployment finished. Health is a distinction Status flattens - 'Live'
        # and 'Finished' are both drawn 'Ok', because neither of them is wrong -
        # and a window recovering it from the Health field's text would be
        # parsing its own display back into a decision.
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
            # THE TIME, NOT THE AGE. The row a few pixels above already carries
            # '(1m 30s ago)', so repeating it here spent the pane's most-read
            # line on a fact that was already on screen - and left out the one
            # thing somebody puts in a ticket or lines up against a log.
            New-HDTConsoleField -Label 'Last heartbeat' -Value (Get-HDTConsoleDisplayText -Text $current.UpdatedText -Fallback '(never)')
            New-HDTConsoleField -Label 'Heartbeat file' -Value $current.Path
        ) `
            -Command $current.Command -Header $Header -Subject $current

        # AN EMPTY NAME MATCHES NOTHING, and so does a run that has since gone:
        # the branch then comes back with nothing selected, which is what the
        # tree does on its own rather than a guess about which row to jump to.
        if (-not [string]::IsNullOrEmpty($SelectedName) -and
            [string]::Equals([string] $current.RunId, $SelectedName, [System.StringComparison]::OrdinalIgnoreCase)) {

            $runRow.IsSelected = $true
        }

        [void] $category.Children.Add($runRow)
    }

    # An empty category reads as a broken one. This says which it is.
    if (@($monitor.Run).Count -eq 0) {
        $empty = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' `
            -Text $monitor.Summary `
            -Field @(
            New-HDTConsoleField -Label 'Watching' -Value $monitor.ActivePath
            New-HDTConsoleField -Label '' -Value ('The engine writes a heartbeat here for each step of each running deployment. Nothing is running on this share, or nothing has run since this folder was last cleared.')
        ) `
            -Command $command -Header $Header

        [void] $category.Children.Add($empty)
    }

    return $category
}
