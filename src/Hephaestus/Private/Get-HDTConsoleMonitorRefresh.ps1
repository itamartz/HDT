function Get-HDTConsoleMonitorRefresh {
    <#
        .SYNOPSIS
            Which monitoring branches the console's refresh timer has to rebuild,
            and what to rebuild each one with.

        .DESCRIPTION
            THE DECISION, TAKEN OUT OF THE TIMER'S HANDLER. DESIGN 12's
            monitoring view refreshes on a DispatcherTimer, and the tick used to
            walk the tree itself: find the MonitorCategory row under every share,
            remember which run was highlighted, and hand both to
            Get-HDTConsoleMonitorNode. Six branches inside a WPF event handler is
            six branches no test can reach, and every console defect this
            repository has had was found by looking at the window rather than by
            a test that failed first.

            IT TOUCHES NO WINDOW AND NO SHARE. It is handed the rows the tree is
            already carrying and returns instructions; the caller does the two
            things only the UI thread may do - call Get-HDTConsoleMonitorNode and
            assign into the ObservableCollection.

            THE HIGHLIGHT IS READ BEFORE ANYTHING IS REPLACED. Children is an
            ObservableCollection, and swapping the object in it is what makes WPF
            redraw the branch - which is also what drops the selection. So the
            run being watched is captured here, up front, and handed back to the
            rebuilt node. Without it a technician watching one deployment has the
            highlight taken off it every few seconds, which looks like the window
            fighting them.

            ONLY A RUN IS SOMETHING BEING WATCHED. The category row and the share
            row are selectable too and neither names a deployment; reading Name
            off them would ask the rebuild to highlight a run called
            'Monitoring'.

            THE LAST MATCHING ROW WINS, which is what the handler did before this
            and is kept deliberately. A share carries one monitoring row, so the
            two answers only differ on a tree that is already wrong - and taking
            the last one leaves that tree refreshing rather than throwing in a
            timer tick, where nothing would report the failure anyway.

            EVERY ROOT AND EVERY SHARE, not the collection the window started
            with. Creating a task sequence rebuilds the rows, and a timer holding
            the originals refreshes rows that are no longer on screen; a console
            with two shares open used to leave the second one showing a
            deployment that had finished ten minutes earlier.

        .PARAMETER Root
            The tree's roots, as the window's ItemsSource carries them. An empty
            or absent tree asks for nothing rather than failing: the timer starts
            before the share has finished loading.

        .PARAMETER Selected
            The row the tree has selected, or $null. Only a MonitorRun changes
            the answer.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            Zero or more System.Management.Automation.PSCustomObject, one per
            monitoring row to rebuild:

              Parent        the share row that owns it
              Index         where it sits in that share's Children
              Path          the deployment share to read the runs from
              SelectedName  the run to highlight, or '' for none
              Header        Title, Root and DeployRoot for the rebuilt row

        .EXAMPLE
            Get-HDTConsoleMonitorRefresh -Root $tree.ItemsSource -Selected $tree.SelectedItem

        .EXAMPLE
            foreach ($item in @(Get-HDTConsoleMonitorRefresh -Root $tree.ItemsSource -Selected $tree.SelectedItem)) {
                $item.Parent.Children[$item.Index] = Get-HDTConsoleMonitorNode -Path $item.Path `
                    -SelectedName $item.SelectedName -Header $item.Header
            }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Root,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object] $Selected
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # WHICH RUN IS BEING WATCHED, read before any row is replaced.
    $watching = ''

    if ($null -ne $Selected -and $Selected.PSObject.Properties.Name -contains 'Kind' -and
        [string] $Selected.Kind -eq 'MonitorRun') {

        $watching = [string] $Selected.Name
    }

    foreach ($branch in @($Root)) {
        if ($null -eq $branch -or $branch.PSObject.Properties.Name -notcontains 'Children') { continue }

        foreach ($share in @($branch.Children)) {
            if ($null -eq $share -or $share.PSObject.Properties.Name -notcontains 'Children') { continue }

            $children = @($share.Children)
            $at = -1

            for ($i = 0; $i -lt $children.Count; $i++) {
                if ($null -eq $children[$i]) { continue }
                if ($children[$i].PSObject.Properties.Name -notcontains 'Kind') { continue }

                if ([string] $children[$i].Kind -eq 'MonitorCategory') { $at = $i }
            }

            # A share whose monitoring branch has not been built yet. The timer
            # starts with the window; the rows arrive when the share is read.
            if ($at -lt 0) { continue }

            $row = $children[$at]

            [pscustomobject] @{
                Parent       = $share
                Index        = $at
                Path         = [string] $row.HeaderRoot
                SelectedName = $watching
                Header       = [pscustomobject] @{
                    Title      = [string] $row.HeaderTitle
                    Root       = [string] $row.HeaderRoot
                    DeployRoot = [string] $row.HeaderDeployRoot
                }
            }
        }
    }
}
