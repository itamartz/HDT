function New-HDTConsoleView {
    <#
        .SYNOPSIS
            Builds the console window and wires every handler on it, without
            showing it.

        .DESCRIPTION
            BUILDING A WINDOW AND SHOWING ONE ARE TWO DIFFERENT JOBS, and only
            the second needs a desktop. This loads the markup with XamlReader,
            paints the palette, fills the tree and hangs all 126 handlers off it;
            New-HDTConsoleHost's Show method then calls ShowDialog, which is the
            part that blocks and the part that needs a window station.

            THAT SPLIT IS WHAT MAKES THE WIRING REACHABLE. A WPF visual tree
            builds perfectly well on a thread that never shows it - Windows
            PowerShell's console host is already STA, XamlReader::Load is a
            markup parser with no compiler behind it, and a handler attached here
            can be raised with RaiseEvent against no display at all. While the
            only entry point was a method ending in ShowDialog, none of that
            could be exercised.

            THE HOST IS INJECTED RATHER THAN BEING $this. Inside an Add_Click
            handler $this is the BUTTON that raised the event, not the service
            object, and a ScriptMethod's enclosing scope is not in scope either -
            so the handlers close over $consoleHost by name, and that name has to
            come from somewhere. It comes in as a parameter now, which is also
            what lets a test hand it one it can inspect afterwards.

            IT SHOWS NOTHING AND RETURNS THE WINDOW. What a dismissed window
            means is Show-HDTConsole's decision, not this one's.

        .PARAMETER ConsoleHost
            The service object the handlers write their answer to. Show passes
            $this; a test passes one of its own.

        .PARAMETER Xaml
            The console markup.

        .PARAMETER Title
            The window title.

        .PARAMETER Node
            The tree's root rows.

        .PARAMETER Theme
            The palette, as brushes.

        .PARAMETER Size
            The remembered window size.

        .PARAMETER RefreshSecond
            How often the monitoring branch rebuilds.

        .PARAMETER NewSequenceXaml
            Markup for the New Task Sequence dialog.

        .PARAMETER ImportOperatingSystemXaml
            Markup for the Import Operating System dialog.

        .PARAMETER ImportApplicationXaml
            Markup for the Import Application dialog.

        .PARAMETER ImportWindowsUpdateXaml
            Markup for the Import Windows Update dialog.

        .PARAMETER ApplicationDependencyXaml
            Markup for the application dependency picker.

        .PARAMETER ApplicationDetectionXaml
            Markup for the detection rule editor.

        .PARAMETER Fill
            The scriptblock that re-reads a share.

        .PARAMETER NewWorkspaceXaml
            Markup for the New Deployment Share dialog.

        .PARAMETER NewMediaXaml
            Markup for the New Media dialog.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built and wired, never shown.

        .EXAMPLE
            New-HDTConsoleView -ConsoleHost $service -Xaml $xaml -Title 'HDT' -Node $node -Theme $theme -Size $size

        .EXAMPLE
            $window = New-HDTConsoleView -ConsoleHost $host -Xaml $xaml -Title 'HDT' -Node $node -Theme $theme -Size $size
            $window.FindName('HDTCloseButton').RaiseEvent($click)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a window object and shows nothing; ShowDialog is the caller''s.')]
    [CmdletBinding()]
    [OutputType([System.Windows.Window])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ConsoleHost,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Xaml,

        [Parameter()] [AllowEmptyString()] [string] $Title = '',
        [Parameter()] [AllowNull()] [object[]] $Node = @(),
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Size = $null,
        [Parameter()] [int] $RefreshSecond = 10,
        [Parameter()] [AllowEmptyString()] [string] $NewSequenceXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $ImportOperatingSystemXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $ImportApplicationXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $ImportWindowsUpdateXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $ApplicationDependencyXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $ApplicationDetectionXaml = '',
        [Parameter()] [AllowNull()] [object] $Fill = $null,
        [Parameter()] [AllowEmptyString()] [string] $NewWorkspaceXaml = '',
        [Parameter()] [AllowEmptyString()] [string] $NewMediaXaml = ''
    )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        # THE ICON, BEFORE THE WINDOW IS SHOWN. A window that declares none
        # wears the icon of the process hosting it, and that is powershell.exe -
        # which put the PowerShell feather on the taskbar button and left an
        # administrator with two identical buttons for the console and the shell
        # that started it. Get-HDTConsoleWindowIcon draws the anvil; every window
        # this host opens gets it, and a test counts the two against each other.
        $window.Icon = Get-HDTConsoleWindowIcon

        # THE TEXT COMES OUT OF A FILE, NOT OUT OF THE MARKUP, and it is applied
        # before anything else is written to a control: the banner is filled from
        # the selected row a moment later, and a table applied after that would
        # put the placeholder back.
        [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'Console'))

        # THE ENGINE VERSION GOES IN THE TITLE BAR, and this is the only place
        # on the screen that says which engine is answering. A stale boot image
        # carrying an older engine than the share is a confusing failure that
        # used to take a shell and a command to diagnose; the number is now
        # readable from a photograph of the window.
        #
        # THE WORDS CAME FROM THE TABLE A MOMENT AGO ('HDTConsoleWindow.Title');
        # the number cannot, because a build writes it. Get-HDTConsoleTitle is
        # the join, and it reads Get-HDTModuleVersion rather than any literal,
        # so a title disagreeing with the manifest is impossible.
        $window.Title = Get-HDTConsoleTitle -Text $Title

        # The size the console was last left at, over the markup's first-run
        # numbers, and the corner of the desktop it opens in.
        # Get-HDTConsoleSetting decided all four; this applies them. Left and Top
        # mean nothing without WindowStartupLocation="Manual" in the markup.
        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height
        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top

        # THE PALETTE, OVER THE DEFAULTS THE MARKUP DECLARED. Every colour in the
        # window is a DynamicResource, so replacing the resource repaints it.
        # Which colours those are is Get-HDTConsoleTheme's decision; this only
        # applies them, key by key, with no opinion about what is in the list.
        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $ConsoleHost.Answer = ''

        # THE HOST, CAPTURED BY NAME. Inside an Add_Click handler $this is the
        # BUTTON that raised the event, not this object - and the enclosing
        # function's $service is not in scope inside a ScriptMethod at all, so a
        # handler written against it closes over a variable that does not exist
        # and throws under StrictMode. New-HDTWizardHost hit exactly this and
        # documented it in cb4200e; this adapter was written the same way and
        # carried the same bug, and it survived every screenshot because a window
        # dismissed with WM_CLOSE or the title-bar X never runs the handler at
        # all. It took an administrator pressing Close.
        $consoleHost = $ConsoleHost

        # The editor is opened from a handler on this window, and an owned dialog
        # is what keeps it above the window it was opened from instead of behind
        # it. The position no longer depends on this - both windows are placed
        # explicitly - but the z-order does, and a task sequence editor that
        # vanished behind the browser the moment somebody clicked the browser
        # would read as an editor that closed itself.
        $consoleHost.Window = $window

        # PARSED .inf FILES, FOR AS LONG AS THIS WINDOW IS OPEN. Selecting a
        # driver folder re-read and re-parsed every .inf under it: 2.5 seconds
        # for the 211 on the real share, every single click, on this thread.
        #
        # IT IS NOT AN INDEX AND IT CANNOT GO STALE AGAINST THE SHARE, which is
        # the distinction DESIGN 7 draws when it rejects a driver-index.json.
        # This lives in the window, dies with it, and every entry is keyed on the
        # file's own last-write time - so a re-imported pack re-reads exactly the
        # files that changed and nothing else.
        # SYNCHRONIZED, because it crosses a thread boundary. The grid is read
        # in the window's own runspace (see $gridReader below) and both threads
        # touch this table; a plain hashtable corrupts under that in a way that
        # surfaces much later as a wrong driver list.
        $driverCache = [hashtable]::Synchronized(@{})

        # THE GRID IS READ OFF THE DISPATCHER. Selecting a folder used to call
        # Get-HDTConsoleDriverRow from the selection handler and freeze the
        # window for the length of the read - 2.5 seconds cold, on every FIRST
        # look at a folder. An administrator clicking two folders waits twice,
        # and a window that ignores the mouse gets reported as hung.
        #
        # THE RUNSPACE IS OPENED ONCE, HERE. The comment on the tree fill below
        # is right that a second runspace costs a module import before it can
        # read anything - so that cost is paid at window open, once, rather than
        # per click. The tree fills once and the dispatcher suits it; the grid
        # reloads on every selection and it does not.
        $gridReader = & $call 'New-HDTConsoleGridReader' -ModulePath $script:HDTModuleRoot

        $share = $window.FindName('HDTShareText')
        $deployRoot = $window.FindName('HDTDeployRootText')
        $root = $window.FindName('HDTRootText')
        $tree = $window.FindName('HDTConsoleTree')
        $detail = $window.FindName('HDTDetailList')
        $detailScroll = $window.FindName('HDTDetailScroll')
        $driverGrid = $window.FindName('HDTDriverGrid')

        $command = $window.FindName('HDTCommandText')
        $close = $window.FindName('HDTCloseButton')

        # =====================================================================
        # THE GRID'S READER, WIRED HERE AND NOT EARLIER
        # =====================================================================
        #
        # GetNewClosure() COPIES WHAT IS IN SCOPE AT THE MOMENT IT RUNS. This
        # block sat above the FindName calls, so the tick closure captured
        # $driverGrid and $command as nothing - and under Set-StrictMode the
        # first tick threw INSIDE A DISPATCHER TIMER, which is unhandled and
        # takes the whole console down. Clicking a driver folder crashed the
        # window.
        #
        # The comment inside the tick already said an exception here takes the
        # console down. It was right, and the capture order made it happen
        # anyway: a rule written down is not a rule enforced.
        $gridTimer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $gridTimer.Interval = [timespan]::FromMilliseconds(60)

        # THE ONLY THING ON THE DISPATCHER IS DRAWING THE ANSWER. The timer asks
        # "is it done", and when it is, hands the rows over and stops.
        # Everything expensive happened on the reader's thread.
        $gridTimer.Add_Tick({
                # WRAPPED WHOLE, because this is a dispatcher timer and nothing
                # it throws has anywhere to go but the top of the application.
                # A grid that fails to fill is a grid; a tick that throws is a
                # closed console.
                try {
                    if (-not $gridReader.IsDone()) { return }

                    $gridTimer.Stop()
                    $window.Cursor = $null

                    $row = @($gridReader.End())

                    if (-not [string]::IsNullOrWhiteSpace([string] $gridReader.Failure)) {
                        $command.Text = '# {0}' -f [string] $gridReader.Failure
                    }

                    $driverGrid.ItemsSource = [object[]] $row
                } catch {
                    $gridTimer.Stop()
                    $window.Cursor = $null
                    $window.Tag = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        # THE READ, STARTED AND LEFT TO RUN. The wait cursor is what the tree
        # fill already uses to say the window is busy rather than broken - and
        # unlike the tree, this one keeps taking the mouse while it works.
        $startGridRead = {
            param([string] $Root, [string] $Path)

            try {
                $window.Cursor = [System.Windows.Input.Cursors]::AppStarting

                [void] $gridReader.Begin($Root, $Path, $driverCache)

                $gridTimer.Start()
            } catch {
                $window.Cursor = $null
                $command.Text = '# {0}' -f [string] $_.Exception.Message
            }
        }.GetNewClosure()

        # A DOUBLE-CLICK ON A DRIVER OPENS ITS PROPERTIES, which is where the
        # enabled tick box lives - the grid is read-only on purpose, because a
        # tick box on two hundred rows leaves no room for the PnP ids that say
        # which machine each driver is for.
        #
        # IT SAYS SO RATHER THAN DOING NOTHING, as every other opener here: a
        # double-click that opens nothing is one somebody does again.
        $driverGrid.Add_MouseDoubleClick({
                $chosen = $driverGrid.SelectedItem
                if ($null -eq $chosen) { return }

                $selected = $tree.SelectedItem
                if ($null -eq $selected) { return }

                $shareRoot = [string] $selected.Subject

                if ([string]::IsNullOrWhiteSpace($shareRoot)) {
                    $command.Text = 'that row does not name a share, so the driver cannot be opened.'
                    return
                }

                # THE IDS ARE FETCHED HERE, FOR THIS ONE DRIVER. The grid is
                # filled without them - they are 43% of the parse and it shows
                # none of them - so the properties window, which is the only
                # thing that displays them, reads the file it is about to
                # describe. One .inf instead of two hundred and eleven.
                #
                # A FAILURE HERE IS NOT FATAL: the window still opens, with an
                # empty PnP list, rather than refusing to show the driver's
                # class and version because its ids could not be re-read.
                $full = $chosen

                try {
                    # -Path IS A FOLDER, and the row's Path names the .inf
                    # itself. Its Folder is the one to ask for, and the file is
                    # matched back by FullPath - a folder holds many drivers and
                    # taking the first would describe the wrong one.
                    $withIds = @(& $call 'Get-HDTDriver' @{
                            Root = $shareRoot; Path = [string] $chosen.Folder
                        })

                    $mine = @($withIds | Where-Object {
                            [string] $_.FullPath -eq [string] $chosen.FullPath
                        })

                    if (@($mine).Count -gt 0) { $full = @($mine)[0] }
                } catch {
                    Write-Verbose ("the hardware ids could not be re-read: {0}" -f [string] $_.Exception.Message)
                }

                try {
                    [void] (& $call 'Show-HDTDriverWindow' @{
                            Root = $shareRoot; Driver = $full; ConsoleHost = $consoleHost
                            OwnerWidth = [int] $window.Width; OwnerHeight = [int] $window.Height
                        })
                } catch {
                    $command.Text = '# {0}' -f [string] $_.Exception.Message
                    return
                }

                # THE STATE MAY HAVE CHANGED WHILE IT WAS OPEN, and the grid is
                # what shows it - so it is stale until the folder is read again.
                & $startGridRead $shareRoot ([string] $selected.Name)
            }.GetNewClosure())


        # -- Apply, which is the only button on this window that writes --------
        #
        # THE BOXES ALREADY WRITE WHEN THEY LOSE FOCUS, and that is not enough:
        # the box somebody is typing in is the one still holding the caret when
        # they go looking for a button, so a pane with no Apply asks them to
        # click somewhere else before their change is real - a rule nobody can
        # see and nobody would guess.
        #
        # IT WRITES EVERY CHANGED ROW, not the one with focus.
        # Get-HDTConsoleStepChange is the same comparison the editor's Properties
        # tab makes: an editable row whose Value differs from the Original it was
        # built with.

        $apply = $window.FindName('HDTApplyButton')

        $applyState = {
            if ($null -eq $apply) { return }

            $chosen = $tree.SelectedItem
            $ready = $false

            if ($null -ne $chosen -and [string] $chosen.Kind -eq 'TaskSequence') {
                $pending = @(& $call 'Get-HDTConsoleStepChange' -Field ([object[]] @($detail.ItemsSource)) `
                        -Name ([string] $chosen.Name))

                $ready = (@($pending).Count -gt 0)
            }

            $apply.IsEnabled = $ready
        }.GetNewClosure()

        # -- Open Report, the last clause of DESIGN 12's monitoring view -------
        #
        # "tails Logs\_active\ ... AND OPENS THE FULL REPORT ON COMPLETION."
        # ConvertTo-HDTReport has rendered that report since M2; this is the
        # click that reaches it.
        #
        # DARK UNTIL THERE IS ONE TO OPEN. The report is rendered from the log
        # Copy-HDTLog brings back when the sequence ends, so a run still
        # deploying has nothing to render - and a button that is live on every
        # row is one somebody presses to be told no.
        #
        # THE DECISION IS Get-HDTConsoleMonitorReport'S. It searches the share,
        # recovers the machine's name and picks the paths; this asks it whether
        # there is anything, which is why the handler below has no rule of its
        # own about where a log lives.

        $report = $window.FindName('HDTReportButton')

        $reportState = {
            if ($null -eq $report) { return }

            $chosen = $tree.SelectedItem
            $ready = $false

            if ($null -ne $chosen -and [string] $chosen.Kind -eq 'MonitorRun' -and $null -ne $chosen.Subject) {
                $ready = ((& $call 'Get-HDTConsoleMonitorReport' -Path ([string] $chosen.HeaderRoot) `
                            -RunId ([string] $chosen.Name) `
                            -Health ([string] $chosen.Subject.Health)).Status -eq 'Ok')
            }

            $report.IsEnabled = $ready
        }.GetNewClosure()


        # The roots only. WPF builds the rest from each row's Children through
        # the HierarchicalDataTemplate, so the nesting, the expanders and the
        # icons all come out of data this adapter never inspects.
        $tree.ItemsSource = $Node

        # Five assignments off the selected row and nothing else. The banner
        # follows the selection because with several shares open it has to name
        # the one being looked at - and the row already knows which that is, so
        # this does not have to work it out.
        $tree.Add_SelectedItemChanged({
                $selected = $tree.SelectedItem
                $detail.ItemsSource = $selected.Field
                $command.Text = [string] $selected.Command

                # A DRIVER FOLDER SHOWS A LIST, NOT FIELDS. Which pane is on is
                # the ROW's decision, worked out in a command so Pester can see
                # it - see Get-HDTConsoleDetailPane.
                $pane = & $call 'Get-HDTConsoleDetailPane' -Kind ([string] $selected.Kind)

                if ($pane.ShowGrid) {
                    # THE GRID IS SHOWN EMPTY AND FILLED WHEN THE READ LANDS,
                    # rather than the window stopping for two seconds and then
                    # showing a full one. The rows of the folder somebody just
                    # left must not sit under the name of the one they picked.
                    $driverGrid.ItemsSource = [object[]] @()

                    & $startGridRead ([string] $selected.Subject) ([string] $selected.Name)

                    $driverGrid.Visibility = [System.Windows.Visibility]::Visible
                    $detailScroll.Visibility = [System.Windows.Visibility]::Collapsed
                } else {
                    $driverGrid.Visibility = [System.Windows.Visibility]::Collapsed
                    $detailScroll.Visibility = [System.Windows.Visibility]::Visible
                }
                $share.Text = [string] $selected.HeaderTitle
                $deployRoot.Text = [string] $selected.HeaderDeployRoot
                $root.Text = [string] $selected.HeaderRoot

                # AND Apply GOES DARK, because a fresh pane has nothing pending.
                # Declared below this handler and reached through the closure -
                # $applyState is a variable, not a function, so it only has to
                # exist by the time somebody clicks.
                if ($null -ne $applyState) { & $applyState }

                # AND Open Report follows the selection the same way, because
                # whether there is a report to open is a fact about the row.
                if ($null -ne $reportState) { & $reportState }
            }.GetNewClosure())

        # OPENING THE WINDOWS PE WINDOW, IN ONE PLACE. Two rows reach it - the
        # boot image row on a double-click, and the Boot Image category and that
        # same row from the right-click menu - and a second copy of this call is
        # a second place for the owner or the theme to be forgotten.
        #
        # -ConsoleHost IS WHAT CARRIES THE OWNER, as it is for the editor below:
        # without it the window is owned by nothing and drops behind whatever is
        # clicked next.
        $openBootImage = {
            param([string] $DocumentPath)

            if ([string]::IsNullOrWhiteSpace($DocumentPath)) { return }

            [void] (Show-HDTBootImageWindow -Path $DocumentPath `
                    -ConsoleHost $consoleHost `
                    -OwnerWidth ([int] $window.ActualWidth) -OwnerHeight ([int] $window.ActualHeight))
        }.GetNewClosure()

        # DOUBLE-CLICKING A TASK SEQUENCE OPENS THE EDITOR ON IT, which is what
        # Deployment Workbench does and the first thing an administrator will
        # try. Which rows those are is not worked out here: the row says whether
        # it opens and carries the object the editor takes, both decided in
        # Get-HDTConsoleTreeNode and asserted there.
        #
        # THE OBJECT, NEVER AN ID. Two shares commonly hold a task sequence with
        # the same id - both of this lab's do - so an editor opened by id could
        # write to one share's document while showing the other's.
        $tree.Add_MouseDoubleClick({
                $selected = $tree.SelectedItem

                # TWO KINDS OF ROW OPEN, AND THE ROW SAYS WHICH IT IS - routed
                # on the Kind Get-HDTConsoleTreeNode already decided, not worked
                # out again here. CanOpen is NOT an invitation to open the
                # editor: an operating system carries a subject so the details
                # pane can write its document, and its properties ARE that pane.
                # tests/unit/ConsoleOpenAction.Tests.ps1.
                $open = & $call 'Get-HDTConsoleOpenAction' -Row $selected

                if ($open.Open -eq 'BootImage') {
                    & $openBootImage ([string] $open.Subject)
                    return
                }

                if ($open.Open -ne 'SequenceEditor') { return }

                # AND IT COMES UP THE SIZE OF THIS WINDOW. ActualWidth, not the
                # markup and not RestoreBounds: what was asked for is the size
                # the administrator is looking at, so a maximised console opens
                # an editor the size of the maximised console. What to do with
                # those two numbers - the floor, the desktop, and the case where
                # there is no console at all - is Resolve-HDTConsoleEditorSize's.
                # -ConsoleHost IS WHAT CARRIES THE OWNER. Without it
                # Show-HDTSequenceEditor builds a fresh host, whose Window is
                # $null, so the editor is owned by nothing and drops behind the
                # browser the first time the browser is clicked.
                [void] (Show-HDTSequenceEditor -Sequence $open.Subject `
                        -ConsoleHost $consoleHost `
                        -OwnerWidth ([int] $window.ActualWidth) -OwnerHeight ([int] $window.ActualHeight))
            }.GetNewClosure())

        # THE MONITORING BRANCH TAILS Logs\_active\ WHILE THE WINDOW IS OPEN.
        # ROADMAP M8 asks for a view that TAILS the directory: one that read it
        # at startup and then showed an hour-old answer would be a report that
        # looks like a monitor, which is how somebody comes to believe a machine
        # is fine.
        #
        # ONLY THAT BRANCH IS REBUILT. Rebuilding the tree would re-read
        # workspace.yaml, every sequence document and the boot image manifest -
        # over SMB, every few seconds - and would throw away the expansion and
        # the selection an administrator had arranged. Get-HDTConsoleMonitorNode
        # reads one directory and hands back one node.
        #
        # THE NODE IS REPLACED RATHER THAN EDITED, because a PSCustomObject
        # raises no change notification: editing Text on a row already on screen
        # changes nothing anybody can see. Children is an ObservableCollection,
        # so swapping the object in it is what makes WPF redraw the branch.
        #
        # A DispatcherTimer, NOT A BACKGROUND THREAD. It ticks on the UI thread,
        # which is the only thread allowed to touch these collections, and it
        # stops when the window closes without anything having to remember to
        # stop it.
        $refresh = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $refresh.Interval = [timespan]::FromSeconds([double] $RefreshSecond)

        $refresh.Add_Tick({
                # WHICH ROWS TO REBUILD AND WHAT TO REBUILD THEM WITH, decided
                # away from the window. Finding the monitoring row under every
                # share and remembering which run was highlighted used to happen
                # here, in the tick, where no test could reach it;
                # tests/unit/ConsoleMonitorRefresh.Tests.ps1 covers it now.
                #
                # The highlight is read before anything is replaced, because
                # replacing the branch is what loses it.
                foreach ($item in @(& $call 'Get-HDTConsoleMonitorRefresh' `
                            -Root $tree.ItemsSource -Selected $tree.SelectedItem)) {

                    $item.Parent.Children[$item.Index] = & $call 'Get-HDTConsoleMonitorNode' `
                        -Path $item.Path `
                        -SelectedName $item.SelectedName `
                        -Header $item.Header
                }

                # THE RUN BEING WATCHED IS THE ONE THAT FINISHES WHILE SOMEBODY
                # IS WATCHING IT, and that is the tick where Open Report becomes
                # available. Without this it stays dark until the row is clicked
                # again - which is the click a technician makes to find out
                # whether they can click.
                if ($null -ne $reportState) { & $reportState }
            }.GetNewClosure())

        # Selecting the root raises SelectedItemChanged, which is what fills the
        # two panes and the banner; the window is never shown blank.
        $window.Add_ContentRendered({
                # THE SHARE IS READ HERE, NOT BEFORE THE WINDOW EXISTED.
                # Get-HDTConsoleWorkspace costs 820ms on the lab share, and the
                # tree it builds used to have to exist before this window could
                # be shown - so that second was spent on an empty screen. The
                # window now comes up holding one row saying it is reading, and
                # this is where the reading happens.
                #
                # ON THE DISPATCHER, DELIBERATELY. The window is visible and
                # busy for that second rather than absent for it, and a second
                # runspace would need this module imported into it - the other
                # second - before it could read anything.
                #
                # THE WAIT CURSOR IS WHAT SAYS SO. A window that ignores the
                # mouse without one is a window somebody reports as hung.
                if ($null -ne $Fill) {
                    $window.Cursor = [System.Windows.Input.Cursors]::AppStarting

                    try {
                        $tree.ItemsSource = [object[]] (& $Fill)
                        $tree.UpdateLayout()
                    } catch {
                        # A READ THAT FAILED STILL HAS TO LEAVE A WINDOW SOMEBODY
                        # CAN READ. The placeholder row stays, and what went
                        # wrong is put where a failure belongs - on the window,
                        # in the box that shows what was run.
                        #
                        # ON THE WINDOW'S Tag AS WELL, because the row selected
                        # a moment later writes that box too: an error that only
                        # lived there would be overwritten before anybody read
                        # it, which is exactly how this arrangement hid its own
                        # first failure.
                        $window.Tag = [string] $_.Exception.Message
                        $command.Text = [string] $_.Exception.Message
                    } finally {
                        $window.Cursor = $null
                    }
                }

                $first = $tree.ItemContainerGenerator.ContainerFromIndex(0)
                if ($null -ne $first) { $first.IsSelected = $true }

                # A ZERO INTERVAL IS A SPIN, NOT A PAUSE. DispatcherTimer with
                # TimeSpan.Zero re-queues itself at Background priority as fast
                # as the thread will take it, so nothing at ApplicationIdle ever
                # runs again - the window draws and then answers nothing, which
                # looks exactly like a hang and is one. Show-HDTConsole's
                # ValidateRange keeps an administrator out of it; this keeps
                # anything that builds the view directly out of it too.
                if ($RefreshSecond -gt 0) { $refresh.Start() }
            }.GetNewClosure())

        # A timer left running holds a reference to a window that has gone.
        # A RUNSPACE NOBODY CLOSED IS A THREAD THAT OUTLIVES ITS WINDOW, and a
        # console opened and closed a dozen times in a session would leak one
        # each time. Close is guarded internally, because this runs while the
        # window is coming down and sometimes because something already went
        # wrong.
        $window.Add_Closed({
                $refresh.Stop()
                $gridTimer.Stop()
                $gridReader.Close()
            }.GetNewClosure())

        # MDT'S New Task Sequence. It creates into the share the tree is showing
        # - the selected row carries its own root, and two shares in one window
        # commonly hold sequences with the same id, so "the selected one" is the
        # only answer that cannot write to the wrong share.
        #
        # THE TREE, REBUILT FROM THE SHARES IT IS ALREADY SHOWING. Creating a
        # sequence and removing one both need it, and the refresh timer only
        # rebuilds the monitor rows.
        #
        # THE SAME TWO CALLS Show-HDTConsole MAKES: a share is read, its rows are
        # built. A share that will not read becomes a failure row rather than
        # taking the window down.
        # WHICH SHARES THE WINDOW HAS OPEN, read off the tree rather than kept
        # in a list beside it: the tree is what somebody is looking at, and a
        # second list is a second thing to get out of step with it.
        $openShare = {
            $shareRoot = New-Object -TypeName System.Collections.ArrayList

            foreach ($root in @($tree.ItemsSource)) {
                foreach ($share in @($root.Children)) {
                    $one = [string] $share.HeaderRoot
                    if (-not [string]::IsNullOrWhiteSpace($one)) { [void] $shareRoot.Add($one) }
                }
            }

            return [string[]] @($shareRoot)
        }.GetNewClosure()

        # REBUILT FROM A LIST, so adding a share and closing one are the same
        # operation with a different list - and the ordinary rebuild is that
        # operation with the list the tree already has.
        $rebuildFrom = {
            param([string[]] $Root)

            $rebuiltShare = New-Object -TypeName System.Collections.ArrayList

            foreach ($one in @($Root)) {
                try {
                    [void] $rebuiltShare.Add((& $call 'Get-HDTConsoleWorkspace' -Path $one))
                } catch {
                    [void] $rebuiltShare.Add((& $call 'New-HDTConsoleShareFailure' -Path $one `
                                -Message ([string] $_.Exception.Message)))
                }
            }

            # THE DEPTH-0 ROWS, NOT EVERY ROW. Get-HDTConsoleTreeNode returns the
            # tree flat and WPF builds the branches from each row's Children, so
            # handing it everything draws every node twice.
            # WHAT WAS OPEN, BEFORE IT STOPS EXISTING. Every node below is a new
            # object, so the chevrons somebody clicked go with the old ones -
            # and the console now opens FOLDED, so without this a rename would
            # fold the tree back up around the person doing it.
            $wasOpen = [string[]] @(& $call 'Get-HDTConsoleExpandedPath' `
                    -Node ([object[]] @($tree.ItemsSource)))

            # -Collapsed, LIKE THE FIRST BUILD, and this was missing.
            #
            # Show-HDTConsole builds the opening tree folded; this rebuild did
            # not, so every fresh row arrived EXPANDED - and
            # Set-HDTConsoleExpandedPath below only ever sets IsExpanded true,
            # never false. It had nothing to close. So the restore re-opened
            # what was open, the default left everything else open too, and
            # saving a new folder unfolded the entire tree around whoever had
            # just carefully folded it.
            #
            # Folded first, then reopen exactly what was open, is the only order
            # that ends with the tree the administrator was looking at.
            $rebuiltNode = @(& $call 'Get-HDTConsoleTreeNode' -Workspace ([object[]] @($rebuiltShare)) -Collapsed)

            $rebuiltRoot = [object[]] @($rebuiltNode | Where-Object { $_.Depth -eq 0 })

            [void] (& $call 'Set-HDTConsoleExpandedPath' -Node $rebuiltRoot -Path $wasOpen)

            $tree.ItemsSource = $rebuiltRoot

            # WHAT THE WINDOW ENDED UP WITH, for Show-HDTConsole to remember
            # after it closes. Read from the rebuild rather than from the tree,
            # because a share that would not open is still one somebody added.
            $consoleHost.OpenShare = [string[]] @($Root)
        }.GetNewClosure()

        $rebuildTree = { & $rebuildFrom (& $openShare) }.GetNewClosure()

        # A TYPEABLE DETAIL BOX WRITES WHEN IT LOSES FOCUS, which is how every
        # other box in this console behaves. Which boxes those are is the row's
        # decision - New-HDTConsoleField sets ReadOnly from whether the row names
        # a key - so this handler keeps no list of labels.
        #
        # ONE HANDLER FOR THE WHOLE PANE, not one per box: the boxes are made by
        # a DataTemplate and remade on every selection, so a handler attached to
        # each would have to be attached again on every click of the tree.
        # LostFocus bubbles, and OriginalSource is the box that lost it.
        #
        # IT WRITES THE FILE, IT DOES NOT HOLD THE EDIT. There is no Save on this
        # window - the pane is a properties sheet off a live share - so the
        # document is read, spliced and saved in one go, and the tree is rebuilt
        # so the row's label follows the name that was just typed.
        # TYPING LIGHTS Apply. TextChanged fires per keystroke, which is what a
        # button that says 'there is something to write' has to follow - waiting
        # for focus to move would leave it dark at the moment it is wanted.
        $detail.AddHandler([System.Windows.Controls.TextBox]::TextChangedEvent,
            [System.Windows.RoutedEventHandler] {
                if ($null -ne $applyState) { & $applyState }
            }.GetNewClosure())

        # ONE WRITE PATH, TWO CONTROLS. A row whose document allows a closed
        # set is a ComboBox rather than a TextBox, and a ComboBox raises neither
        # TextChanged nor TextBox.LostFocus - so without this the Log level list
        # would offer the four levels and write none of them.
        #
        # THE CONTROL IS READ BY THE HANDLER AND NOTHING ELSE. Which one lost
        # focus, what it holds and how to put it back are the only things the
        # two differ on; the read-splice-save below is the same work either way,
        # and a second copy of it is the copy that would rot.
        $writeRow = {
            param(
                [object] $row,
                [string] $typed,
                [scriptblock] $revert
            )

            # THE DOOR IS CAPTURED, NOT ASKED FOR. $writeRow used to be a plain
            # scriptblock and fetched its own $call here; d0470cd made it a
            # closure so it could see this function's locals, and that turned
            # the fetch into the one thing a closure cannot do. GetNewClosure
            # binds a block to a fresh dynamic module whose command lookup falls
            # through to the GLOBAL scope, where no private function of this
            # module exists - Get-HDTHandlerCall least of all. Typing a version
            # into a task sequence raised 'The term Get-HDTHandlerCall is not
            # recognized' in a message box and took the console down with it.
            #
            # So it comes from the enclosing scope, the way every other closure
            # on this window gets it, and the contract sweeps the whole module
            # for the mistake rather than two files of it.

            # WHICH DOCUMENT THIS ROW EDITS IS THE ROW'S KIND, and the pair
            # of commands follows from it: a sequence and an imported
            # operating system have the same flat header and two different
            # validators, so the wrong pair writes a file the other one then
            # refuses to read. That decision, the Share projection's missing
            # Path and the rebuild rule all live in
            # Get-HDTConsoleRowDocument now, with tests -
            # tests/unit/ConsoleRowDocument.Tests.ps1.
            $selected = $tree.SelectedItem
            if ($null -eq $selected) { return }

            $edit = & $call 'Get-HDTConsoleRowDocument' -Row $selected -Property ([string] $row.Property)
            if (-not $edit.Supported) { return }

            $kind = [string] $edit.Kind

            # AN APPLICATION IS THE ONE THAT WRITES ITSELF. Set-HDTApplication
            # takes a share and an id rather than lines, and saves - there is
            # no Save-HDTApplicationDocument to pair it with, because splicing
            # app.yaml is what Set-HDTApplicationLine already does inside it.
            # So this row's edit is one call, and it returns before the
            # read-set-save the other three share.
            if ($kind -eq 'Application') {
                $splat = @{
                    WorkspaceRoot = [string] $selected.HeaderRoot
                    Id            = [string] $selected.Name
                    Confirm       = $false
                }

                # NOT EVERY ROW IS A STRING ANY MORE. The exit codes are
                # int[], the dependencies string[] and the detection rule a
                # block, and their parameters are singular where the document
                # keys are plural - so what to pass, and what to call it, is
                # Get-HDTConsoleApplicationEdit's decision rather than a
                # capital letter's.
                $key = [string] $row.Property
                $edit = $null

                try {
                    # THROUGH THE DOOR, because this is a closure: a private
                    # name written straight into one resolves in the global
                    # scope. Editing any application field would have thrown
                    # 'Get-HDTConsoleApplicationEdit is not recognized' the
                    # moment the version defect above stopped hiding it.
                    $edit = & $call 'Get-HDTConsoleApplicationEdit' -Property $key -Text $typed
                } catch {
                    # A LIST THAT WILL NOT PARSE NEVER REACHES THE DOCUMENT.
                    # The box goes back and the footer says which word was
                    # not a number, which is the sentence a technician can
                    # act on.
                    & $revert ([string] $row.Original)
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $splat[$edit.Parameter] = $edit.Value

                try {
                    [void] (Set-HDTApplication @splat)
                } catch {
                    # A REFUSAL PUTS THE BOX BACK, as everywhere else: a box
                    # holding a value the document rejected is a lie about
                    # what is on disk.
                    & $revert ([string] $row.Original)
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $row.Original = $typed

                # THE ROW READS 'id - name', so only a rename makes the tree
                # stale - and rebuilding re-reads every open share.
                if ($key -eq 'name') { & $rebuildTree }

                $command.Text = "Set-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -{2} {3}" -f
                $splat.WorkspaceRoot, $splat.Id, $edit.Parameter, $edit.Text

                return
            }

            # A MEDIA ITEM WRITES ITSELF TOO, the same shape as an application:
            # Set-HDTMedia takes a share and an id rather than lines. Enabled is
            # the one row that is not a string - Get-HDTConsoleMediaEdit is
            # where that split lives, the same way successCodes and dependencies
            # live in Get-HDTConsoleApplicationEdit for an application row.
            #
            # NO REBUILD, EVER. Get-HDTConsoleRowDocument already says so for
            # every key this pane edits on a media row - none of them is on the
            # tree's own label - so there is nothing here to check.
            if ($kind -eq 'Media') {
                $splat = @{
                    WorkspaceRoot = [string] $selected.HeaderRoot
                    Id            = [string] $selected.Name
                    Confirm       = $false
                }

                $key = [string] $row.Property
                $edit = $null

                try {
                    $edit = & $call 'Get-HDTConsoleMediaEdit' -Property $key -Text $typed
                } catch {
                    # A WORD THAT IS NOT YES OR NO NEVER REACHES THE DOCUMENT.
                    # The box goes back and the footer says what was wrong,
                    # which is the sentence a technician can act on.
                    & $revert ([string] $row.Original)
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $splat[$edit.Parameter] = $edit.Value

                try {
                    [void] (Set-HDTMedia @splat)
                } catch {
                    # A REFUSAL PUTS THE BOX BACK, as everywhere else: a box
                    # holding a value the document rejected is a lie about
                    # what is on disk.
                    & $revert ([string] $row.Original)
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $row.Original = $typed

                $command.Text = "Set-HDTMedia -WorkspaceRoot '{0}' -Id '{1}' -{2} {3}" -f
                $splat.WorkspaceRoot, $splat.Id, $edit.Parameter, $edit.Text

                return
            }

            # AN IMPORTED UPDATE WRITES ITSELF TOO, and with nothing to decide
            # about types on the way: only name and description reach here -
            # everything else on that pane came out of the package's own
            # metadata, and the id is the folder name - so both are plain
            # strings and there is no Get-HDTConsoleUpdateEdit to route through.
            #
            # AN EMPTY DESCRIPTION IS A REMOVAL, not a refusal, which is why the
            # box is allowed to be cleared; an empty NAME is refused by the
            # command and the box goes back, the way it does everywhere else.
            if ($kind -eq 'WindowsUpdate') {
                $splat = @{
                    WorkspaceRoot = [string] $edit.WorkspaceRoot
                    Id            = [string] $edit.Id
                    Confirm       = $false
                }

                $splat[[string] $edit.Parameter] = $typed

                try {
                    [void] (Set-HDTWindowsUpdate @splat)
                } catch {
                    # A REFUSAL PUTS THE BOX BACK, as everywhere else: a box
                    # holding a value the document rejected is a lie about what
                    # is on disk.
                    & $revert ([string] $row.Original)
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $row.Original = $typed

                # THE ROW READS 'KB - name', so only a rename makes the tree
                # stale - and rebuilding re-reads every open share.
                if ($edit.NeedsRebuild) { & $rebuildTree }

                $command.Text = $edit.CommandFormat -f $typed

                return
            }

            # A SHARE POINTS AT ITS workspace.yaml UNDER ANOTHER NAME, because
            # a workspace projection carries the root it was opened from as
            # well as the document - and it has NO Path at all, so reading one
            # off it under Set-StrictMode is a terminating error on the
            # dispatcher, which takes the window down. That branch is
            # Get-HDTConsoleRowDocument's now, and it is asserted rather than
            # remembered.
            $documentPath = [string] $edit.DocumentPath

            try {
                $fileSystem = New-HDTFileSystem
                $document = [string[]] @([string] $fileSystem.ReadAllText($documentPath) -split "`r?`n")

                $splat = @{ Line = $document; Confirm = $false }
                $splat[[string] $row.Property] = $typed

                # THE SETTER AND THE SAVER ARE A PAIR, and which pair is the
                # row's kind: every one of these validates the lines before
                # writing them, and the workspace one checks them against
                # workspace.yaml's keys - so it refuses a sequence for
                # declaring 'description'.
                [void] (& $edit.Saver -Path $documentPath `
                        -Line @(& $edit.Setter @splat) -FileSystem $fileSystem -Confirm:$false)

                $row.Original = $typed

                # THE REBUILD IS THE EXPENSIVE HALF - it re-reads every open
                # share and revalidates every sequence in it, which is about
                # a third of a second against this lab's one share and grows
                # with the number open. The tree row reads 'id - name', so
                # it is only out of date when the NAME changed; a
                # description is not on it, and re-reading the share to find
                # that out would be paying the cost to learn nothing.
                if ($edit.NeedsRebuild) { & $rebuildTree }

                # DESIGN 12's "learn the automation surface by clicking
                # around": what was just run, in the box that shows it.
                #
                # AFTER THE REBUILD, NOT BEFORE. Rebuilding the tree changes
                # the selection, and the selection handler writes this box -
                # so a line written first is gone before anybody reads it.
                $command.Text = $edit.CommandFormat -f $typed
            } catch {
                # A REFUSAL PUTS THE BOX BACK. Set-HDTTaskSequenceProperty
                # will not clear a name, and a box left holding a value the
                # document rejected is a lie about what is on disk.
                & $revert ([string] $row.Original)
                $command.Text = [string] $_.Exception.Message
            }
        }.GetNewClosure()

        $detail.AddHandler([System.Windows.Controls.TextBox]::LostFocusEvent,
            [System.Windows.RoutedEventHandler] {
                param([object] $raiser, [System.Windows.RoutedEventArgs] $lost)

                $box = $lost.OriginalSource -as [System.Windows.Controls.TextBox]
                if ($null -eq $box) { return }

                $row = $box.DataContext
                $typed = [string] $box.Text

                # WHETHER THIS IS AN EDIT AT ALL, asked in one place for both
                # gestures. Not every row here comes from New-HDTConsoleField -
                # a monitor row and a share that would not open build their own
                # - so Editable may not be on the row, and reading a property
                # that is not there is a terminating error on the dispatcher.
                # tests/unit/ConsoleRowCommit.Tests.ps1.
                if (-not (& $call 'Test-HDTConsoleRowCommit' -Row $row -Typed $typed)) { return }

                & $writeRow $row $typed { param([string] $text) $box.Text = $text }.GetNewClosure()
            }.GetNewClosure())

        # A PICK IS FINISHED THE MOMENT IT IS MADE. There is no equivalent of
        # moving focus off a box - the list closes on the click - so this writes
        # on SelectionChanged rather than waiting for LostFocus that a technician
        # has no reason to cause.
        $detail.AddHandler([System.Windows.Controls.ComboBox]::SelectionChangedEvent,
            [System.Windows.RoutedEventHandler] {
                param([object] $raiser, [System.Windows.RoutedEventArgs] $changed)

                $combo = $changed.OriginalSource -as [System.Windows.Controls.ComboBox]
                if ($null -eq $combo) { return }

                $row = $combo.DataContext

                # NOTHING PICKED IS NOT A PICK. Rebuilding the pane raises this
                # with SelectedItem null before the binding has settled, and
                # writing that would clear the key on every click of the tree -
                # which is the opposite of what an emptied TEXT box means, so
                # -Picked is what tells the two apart.
                $picked = ''
                if ($null -ne $combo.SelectedItem) { $picked = [string] $combo.SelectedItem }

                if (-not (& $call 'Test-HDTConsoleRowCommit' -Row $row -Typed $picked -Picked)) { return }

                & $writeRow $row $picked { param([string] $text) $combo.SelectedItem = $text }.GetNewClosure()

                if ($null -ne $applyState) { & $applyState }
            }.GetNewClosure())

        if ($null -ne $apply) {
            $apply.Add_Click({
                    $chosen = $tree.SelectedItem
                    if ($null -eq $chosen -or [string] $chosen.Kind -ne 'TaskSequence') { return }

                    $documentPath = [string] $chosen.Subject.Path

                    $pending = @(& $call 'Get-HDTConsoleStepChange' -Field ([object[]] @($detail.ItemsSource)) `
                            -Name ([string] $chosen.Name))

                    if (@($pending).Count -eq 0) { return }

                    # WHAT THIS PRESS WRITES AND WHAT IT ECHOES, decided away
                    # from the window: the parameter each document key binds to,
                    # whether one of them was the name, and every command line
                    # the press ran. tests/unit/ConsoleSequenceSave.Tests.ps1.
                    $save = & $call 'Get-HDTConsoleSequenceSave' -Pending ([object[]] @($pending)) `
                        -Path $documentPath

                    $ran = New-Object -TypeName System.Collections.ArrayList
                    $renamed = [bool] $save.Renamed

                    try {
                        $fileSystem = New-HDTFileSystem
                        $line = [string[]] @([string] $fileSystem.ReadAllText($documentPath) -split "`r?`n")

                        # ONE READ, EVERY CHANGE, ONE WRITE. Saving per row would
                        # write the document twice for a name and a description
                        # typed together, and the second write would be built
                        # from lines read before the first.
                        foreach ($one in @($save.Edit)) {
                            $splat = @{ Line = $line; Confirm = $false }
                            $splat[[string] $one.Parameter] = [string] $one.Value

                            $line = [string[]] @(Set-HDTTaskSequenceProperty @splat)
                        }

                        [void] (Save-HDTSequenceDocument -Path $documentPath -Line $line `
                                -FileSystem $fileSystem -Confirm:$false)

                        foreach ($one in @($save.Command)) { [void] $ran.Add([string] $one) }

                        foreach ($one in @($pending)) {
                            @($detail.ItemsSource) |
                                Where-Object { [string] $_.Property -eq [string] $one.Property } |
                                ForEach-Object { $_.Original = [string] $one.Value }
                        }
                    } catch {
                        # A REFUSAL LEAVES THE PANE AS IT IS. The boxes still
                        # hold what was typed, so it can be corrected rather than
                        # retyped.
                        $command.Text = [string] $_.Exception.Message
                        return
                    }

                    # THE TREE ROW READS 'id - name', so only a rename makes it
                    # stale - and rebuilding re-reads every open share, which is
                    # the expensive half.
                    if ($renamed) { & $rebuildTree }

                    $command.Text = (@($ran) -join [System.Environment]::NewLine)

                    & $applyState
                }.GetNewClosure())
        }

        # -- and the click that renders the report and opens it ---------------
        #
        # RENDER, THEN HAND IT TO THE SHELL. ConvertTo-HDTReport returns the
        # path it wrote and Start-Process opens it in whatever the machine uses
        # for HTML, which is the same two lines the command in the footer says.
        #
        # IT RENDERS EVERY TIME rather than reusing a report already sitting in
        # the folder. The stream is finished, so the answer is the same one -
        # but the RENDERER is not: a report written by an older module would
        # otherwise outlive the version that can explain it.
        #
        # A FAILURE GOES IN THE FOOTER, WHICH IS WHERE THIS WINDOW PUTS THEM.
        # A share that went away between the button lighting up and the click,
        # or a folder that cannot be written to, must not take the console down
        # while a technician is watching a deployment through it.
        if ($null -ne $report) {
            $report.Add_Click({
                    $chosen = $tree.SelectedItem

                    if ($null -eq $chosen -or [string] $chosen.Kind -ne 'MonitorRun' -or $null -eq $chosen.Subject) { return }

                    $answer = & $call 'Get-HDTConsoleMonitorReport' -Path ([string] $chosen.HeaderRoot) `
                        -RunId ([string] $chosen.Name) -Health ([string] $chosen.Subject.Health)

                    if ($answer.Status -ne 'Ok') {
                        $command.Text = [string] $answer.Message
                        return
                    }

                    try {
                        $written = ConvertTo-HDTReport -JsonlPath $answer.JsonlPath -Path $answer.ReportPath `
                            -Title $answer.Title -Confirm:$false

                        $command.Text = [string] $answer.Command

                        [void] (Start-Process -FilePath ([string] $written))
                    } catch {
                        $command.Text = [string] $_.Exception.Message
                    }
                }.GetNewClosure())
        }

        # NO MARKUP, NO BUTTON. A button that cannot open its window is one a
        # technician presses to find out nothing happens.
        $newWorkspace = $window.FindName('HDTNewWorkspaceMenuItem')
        $openWorkspace = $window.FindName('HDTOpenWorkspaceMenuItem')
        $closeWorkspace = $window.FindName('HDTCloseWorkspaceMenuItem')
        $bootImageItem = $window.FindName('HDTBootImageMenuItem')
        $newSequence = $window.FindName('HDTNewSequenceMenuItem')
        $removeSequence = $window.FindName('HDTRemoveSequenceMenuItem')
        $importOperatingSystem = $window.FindName('HDTImportOperatingSystemMenuItem')
        $removeOperatingSystem = $window.FindName('HDTRemoveOperatingSystemMenuItem')
        $newApplication = $window.FindName('HDTNewApplicationMenuItem')
        $removeApplication = $window.FindName('HDTRemoveApplicationMenuItem')
        $applicationDependency = $window.FindName('HDTApplicationDependencyMenuItem')
        $applicationDetection = $window.FindName('HDTApplicationDetectionMenuItem')
        $selectionProfileItem = $window.FindName('HDTSelectionProfileMenuItem')
        $newDriverFolderItem = $window.FindName('HDTNewDriverFolderMenuItem')
        $importDriverItem = $window.FindName('HDTImportDriverMenuItem')
        $renameDriverFolderItem = $window.FindName('HDTRenameDriverFolderMenuItem')
        $removeDriverFolderItem = $window.FindName('HDTRemoveDriverFolderMenuItem')
        $removeMonitorRunItem = $window.FindName('HDTRemoveMonitorRunMenuItem')
        $importWindowsUpdateItem = $window.FindName('HDTImportWindowsUpdateMenuItem')
        $removeWindowsUpdateItem = $window.FindName('HDTRemoveWindowsUpdateMenuItem')
        $updateMediaItem = $window.FindName('HDTUpdateMediaMenuItem')
        $newMediaItem = $window.FindName('HDTNewMediaMenuItem')
        $removeMedia = $window.FindName('HDTRemoveMediaMenuItem')

        $newFolder = $window.FindName('HDTNewFolderMenuItem')
        $moveToFolder = $window.FindName('HDTMoveToFolderMenuItem')
        $deleteFolder = $window.FindName('HDTDeleteFolderMenuItem')
        $folderUp = $window.FindName('HDTMoveFolderUpMenuItem')
        $folderDown = $window.FindName('HDTMoveFolderDownMenuItem')
        $folderSeparator = $window.FindName('HDTFolderMenuSeparator')

        # THE MENU BELOW IS NOT THE NEW TASK SEQUENCE ITEM'S BUSINESS.
        #
        # Every handler on this tree's context menu - the guard that decides
        # what a row offers, right-click-selects-the-row, and the Click on
        # Clear Run, Delete Folder, Import Drivers, Remove Task Sequence, New
        # Folder and the rest - used to live inside the ELSE of this test. So a
        # view built without the New Task Sequence markup got no right-click
        # menu AT ALL, rather than one item fewer.
        #
        # Show-HDTConsole defaults -NewSequenceXamlPath to the shipped file and
        # so always passes it, which is why nothing ever hit this. It was still
        # a trap with a lying symptom: a view built any other way - a test, a
        # probe, an embedded host - comes up with every item Visible and no
        # guard, which looks exactly like broken visibility logic and is not.
        # It cost twenty minutes of looking at the wrong code.
        #
        # NO MARKUP, NO ITEM is the rule this test is actually for, and it is
        # all it does now. The item stays collapsed - see the menu guard, which
        # will not re-show it either - so its Click below can never be reached.
        if ($null -ne $newSequence -and [string]::IsNullOrWhiteSpace($NewSequenceXaml)) {
            $newSequence.Visibility = [System.Windows.Visibility]::Collapsed
        }

        if ($null -ne $newMediaItem -and [string]::IsNullOrWhiteSpace($NewMediaXaml)) {
            $newMediaItem.Visibility = [System.Windows.Visibility]::Collapsed
        }

        # RIGHT-CLICK DOES NOT SELECT, IN WPF. The menu would otherwise
        # act on whatever was last left-clicked, which is the row above
        # the one somebody just pointed at - and this menu writes a file
        # into a share.
        $tree.Add_PreviewMouseRightButtonDown({
                param($raiser, $mouse)

                $hit = [System.Windows.Media.VisualTreeHelper]::HitTest($tree,
                    $mouse.GetPosition($tree))

                if ($null -eq $hit) { return }

                $walk = $hit.VisualHit

                while ($null -ne $walk -and $walk -isnot [System.Windows.Controls.TreeViewItem]) {
                    $walk = [System.Windows.Media.VisualTreeHelper]::GetParent($walk)
                }

                if ($null -ne $walk) { $walk.IsSelected = $true }
            }.GetNewClosure())

        # AND NO MENU AT ALL ANYWHERE ELSE. A menu that opens on every
        # row with one dead item is worse than no menu: it teaches that
        # right-click does nothing here, on the one row where it does.
        #
        # Handled STOPS IT OPENING. The alternative - opening it and
        # greying the item out - still puts a menu on the boot image,
        # the drivers folder and every task sequence in the share.
        $tree.Add_ContextMenuOpening({
                param($raiser, $opening)

                $chosen = $tree.SelectedItem

                # WORKBENCH'S ROOT NODE: New and Open hang off the
                # 'Deployment Shares' row, and Close off a share.
                $isRoot = ($null -ne $chosen -and [string] $chosen.Kind -eq 'Root')
                $isShare = ($null -ne $chosen -and [string] $chosen.Kind -eq 'Share')

                $isCategory = ($null -ne $chosen -and
                    [string] $chosen.Kind -eq 'Category' -and
                    [string] $chosen.Name -eq 'TaskSequences')

                # BOTH BOOT IMAGE ROWS OFFER IT - the category and the
                # image under it. They are the same action on the same
                # document, and which of the two somebody right-clicks
                # when there is no image yet is not worth being wrong
                # about.
                $isBootImage = ($null -ne $chosen -and (
                        [string] $chosen.Kind -eq 'BootImage' -or
                        ([string] $chosen.Kind -eq 'Category' -and
                            [string] $chosen.Name -eq 'BootImage')))

                $isSequence = ($null -ne $chosen -and [string] $chosen.Kind -eq 'TaskSequence')

                $isOsCategory = ($null -ne $chosen -and
                    [string] $chosen.Kind -eq 'Category' -and
                    [string] $chosen.Name -eq 'OperatingSystems')

                $isOperatingSystem = ($null -ne $chosen -and [string] $chosen.Kind -eq 'OperatingSystem')

                $isAppCategory = ($null -ne $chosen -and
                    [string] $chosen.Kind -eq 'Category' -and
                    [string] $chosen.Name -eq 'Applications')

                $isApplication = ($null -ne $chosen -and [string] $chosen.Kind -eq 'Application')

                # BOTH PROFILE ROWS OFFER IT - the category and a profile
                # under it - for the boot image rows' reason: it is one
                # action on one document, and which of the two somebody
                # right-clicks when there are no profiles yet is not
                # worth being wrong about. A share that has never had one
                # authored still shows the built-in rows, so the category
                # is not the only thing under the pointer. Both are
                # decided by Get-HDTConsoleTreeMenuRow, further down.

                $newWorkspace.Visibility = [System.Windows.Visibility]::Collapsed
                $openWorkspace.Visibility = [System.Windows.Visibility]::Collapsed
                $closeWorkspace.Visibility = [System.Windows.Visibility]::Collapsed

                if ($isRoot) {
                    # NO MARKUP, NO ITEM, as everywhere else here. Open
                    # needs no dialog of its own - it is a folder picker
                    # and one command - so it is offered either way.
                    if (-not [string]::IsNullOrWhiteSpace($NewWorkspaceXaml)) {
                        $newWorkspace.Visibility = [System.Windows.Visibility]::Visible
                    }

                    $openWorkspace.Visibility = [System.Windows.Visibility]::Visible
                }

                if ($isShare) { $closeWorkspace.Visibility = [System.Windows.Visibility]::Visible }

                $bootImageItem.Visibility = [System.Windows.Visibility]::Collapsed

                if ($isBootImage) { $bootImageItem.Visibility = [System.Windows.Visibility]::Visible }

                # EACH ROW GETS THE ITEMS THAT APPLY TO IT, and a row
                # with none opens no menu.
                $newSequence.Visibility = [System.Windows.Visibility]::Collapsed
                $removeSequence.Visibility = [System.Windows.Visibility]::Collapsed
                $importOperatingSystem.Visibility = [System.Windows.Visibility]::Collapsed
                $removeOperatingSystem.Visibility = [System.Windows.Visibility]::Collapsed

                # NO MARKUP, NO ITEM, as everywhere else on this menu. Without
                # the second test this line re-shows an item whose window does
                # not exist, on every category row.
                if ($isCategory -and -not [string]::IsNullOrWhiteSpace($NewSequenceXaml)) {
                    $newSequence.Visibility = [System.Windows.Visibility]::Visible
                }
                if ($isSequence) { $removeSequence.Visibility = [System.Windows.Visibility]::Visible }
                # NO MARKUP, NO ITEM - the same rule the New Task
                # Sequence item follows. An item that cannot open its
                # window is one somebody presses to find out nothing
                # happens.
                if ($isOsCategory -and -not [string]::IsNullOrWhiteSpace($ImportOperatingSystemXaml)) {
                    $importOperatingSystem.Visibility = [System.Windows.Visibility]::Visible
                }
                if ($isOperatingSystem) { $removeOperatingSystem.Visibility = [System.Windows.Visibility]::Visible }

                $newApplication.Visibility = [System.Windows.Visibility]::Collapsed
                $removeApplication.Visibility = [System.Windows.Visibility]::Collapsed

                # NO MARKUP, NO ITEM, as everywhere else on this menu.
                if ($isAppCategory -and -not [string]::IsNullOrWhiteSpace($ImportApplicationXaml)) {
                    $newApplication.Visibility = [System.Windows.Visibility]::Visible
                }
                $applicationDependency.Visibility = [System.Windows.Visibility]::Collapsed
                $applicationDetection.Visibility = [System.Windows.Visibility]::Collapsed

                $selectionProfileItem.Visibility = [System.Windows.Visibility]::Collapsed

                if ($isApplication) {
                    $removeApplication.Visibility = [System.Windows.Visibility]::Visible

                    # NO MARKUP, NO ITEM, as everywhere else here.
                    if (-not [string]::IsNullOrWhiteSpace($ApplicationDependencyXaml)) {
                        $applicationDependency.Visibility = [System.Windows.Visibility]::Visible
                    }

                    if (-not [string]::IsNullOrWhiteSpace($ApplicationDetectionXaml)) {
                        $applicationDetection.Visibility = [System.Windows.Visibility]::Visible
                    }
                }

                # THE FOLDER ITEMS, AND THE ROW DECIDES WHICH.
                # Get-HDTConsoleFolderAction is where that is worked out,
                # from the row alone - re-reading the share here costs
                # 400ms in front of a menu that is supposed to appear
                # under the pointer.
                $folderAction = & $call 'Get-HDTConsoleFolderAction' -Row $chosen

                $newFolder.Visibility = [System.Windows.Visibility]::Collapsed
                $moveToFolder.Visibility = [System.Windows.Visibility]::Collapsed
                $deleteFolder.Visibility = [System.Windows.Visibility]::Collapsed
                $folderSeparator.Visibility = [System.Windows.Visibility]::Collapsed
                $folderUp.Visibility = [System.Windows.Visibility]::Collapsed
                $folderDown.Visibility = [System.Windows.Visibility]::Collapsed

                if ($folderAction.CanCreate) { $newFolder.Visibility = [System.Windows.Visibility]::Visible }
                if ($folderAction.CanMove) { $moveToFolder.Visibility = [System.Windows.Visibility]::Visible }

                # BOTH ARE SHOWN ON EVERY FOLDER AND DISABLED AT THE
                # ENDS, rather than one of them vanishing. An item that
                # disappears at the top of a list teaches that folders
                # cannot be moved up at all; a greyed one says "not this
                # one, it is already first", which is the true statement.
                if ([string] $chosen.Kind -eq 'Folder') {
                    $folderUp.Visibility = [System.Windows.Visibility]::Visible
                    $folderDown.Visibility = [System.Windows.Visibility]::Visible

                    $folderUp.IsEnabled = [bool] $folderAction.CanMoveUp
                    $folderDown.IsEnabled = [bool] $folderAction.CanMoveDown
                }

                # DELETE IS SHOWN AND DISABLED RATHER THAN HIDDEN when
                # the folder still has something in it: an item that
                # vanishes teaches that folders cannot be deleted, and
                # what is true is that THIS one cannot be, yet. The
                # reason is on the tooltip, where a disabled item's
                # reason has to be.
                if ([string] $chosen.Kind -eq 'Folder') {
                    $deleteFolder.Visibility = [System.Windows.Visibility]::Visible
                    $deleteFolder.IsEnabled = [bool] $folderAction.CanDelete
                    $deleteFolder.ToolTip = $null

                    if (-not $folderAction.CanDelete) {
                        $deleteFolder.ToolTip = [string] $folderAction.DeleteRefusal
                    }
                }

                $onFolderRow = ($folderAction.CanCreate -or $folderAction.CanMove -or
                    [string] $chosen.Kind -eq 'Folder')

                # THE SEPARATOR ONLY WHEN THERE IS SOMETHING ON BOTH
                # SIDES OF IT. A line at the top of a menu is a line
                # nobody drew on purpose.
                # WHAT THIS ROW'S MENU IS, DECIDED IN A COMMAND. Both the
                # selection profile label and whether the menu opens at
                # all live in Get-HDTConsoleTreeMenuRow, so Pester can
                # assert what a right-click does - which nothing could
                # before, and which cost a defect: an item made Visible
                # for its row still did nothing, because the guard below
                # cancelled the whole menu for a kind it did not know.
                $menuRow = & $call 'Get-HDTConsoleTreeMenuRow' `
                    -Kind ([string] $chosen.Kind) -Name ([string] $chosen.Name) `
                    -HasFolderAction ([bool] $onFolderRow) `
                    -DriverPath ([string] $chosen.Name)

                $newDriverFolderItem.Visibility = [System.Windows.Visibility]::Collapsed
                $importDriverItem.Visibility = [System.Windows.Visibility]::Collapsed
                $renameDriverFolderItem.Visibility = [System.Windows.Visibility]::Collapsed
                $removeDriverFolderItem.Visibility = [System.Windows.Visibility]::Collapsed
                $removeMonitorRunItem.Visibility = [System.Windows.Visibility]::Collapsed

                # ON THE RUN, NEVER ON THE Monitoring CATEGORY. Clearing
                # this row and clearing every run on the share are
                # different actions; one item that means whichever the
                # mouse happened to be over is how somebody loses the
                # record of a deployment they were still reading.
                if ([string] $chosen.Kind -eq 'MonitorRun') {
                    $removeMonitorRunItem.Visibility = [System.Windows.Visibility]::Visible
                }

                if ($menuRow.IsDriverRow) {
                    $newDriverFolderItem.Visibility = [System.Windows.Visibility]::Visible
                    $importDriverItem.Visibility = [System.Windows.Visibility]::Visible
                }

                # DELETE IS OFFERED ON A FOLDER, NEVER ON THE STORE. The
                # Drivers category is a driver row too - it takes New
                # Folder and Import - but Remove-HDTDriverFolder refuses
                # the store itself, so an item offered there would be one
                # that only ever answers no.
                if ([string] $chosen.Kind -eq 'DriverFolder') {
                    # RENAME IS OFFERED WHEREVER DELETE IS, and for the same
                    # reason it is refused on the store: renaming Drivers\ is
                    # not a folder rename, it is renaming the store.
                    $renameDriverFolderItem.Visibility = [System.Windows.Visibility]::Visible
                    $removeDriverFolderItem.Visibility = [System.Windows.Visibility]::Visible
                }

                if ($menuRow.IsSelectionProfile) {
                    $selectionProfileItem.Visibility = [System.Windows.Visibility]::Visible
                    $selectionProfileItem.Header = [string] $menuRow.SelectionProfileHeader
                }

                # MDT'S Packages NODE. This whole surface shipped without a
                # single item on it: the tree node, the detail pane, the import
                # dialog markup and the host method that opens it all existed,
                # and right-clicking any of it did nothing - because
                # Get-HDTConsoleTreeMenuRow cancelled the menu for kinds it had
                # never been told about. See tests/unit/ConsoleTreeMenu.Tests.ps1,
                # which now walks the whole SET of kinds the tree can emit rather
                # than the one that was last found broken.
                $importWindowsUpdateItem.Visibility = [System.Windows.Visibility]::Collapsed
                $removeWindowsUpdateItem.Visibility = [System.Windows.Visibility]::Collapsed

                # NO MARKUP, NO ITEM, as everywhere else on this menu. An item
                # that cannot open its window is one somebody presses to find out
                # nothing happens.
                if ($menuRow.IsUpdateRow -and -not [string]::IsNullOrWhiteSpace($ImportWindowsUpdateXaml)) {
                    $importWindowsUpdateItem.Visibility = [System.Windows.Visibility]::Visible
                }

                if ($menuRow.IsWindowsUpdate) {
                    $removeWindowsUpdateItem.Visibility = [System.Windows.Visibility]::Visible
                }

                # MDT'S Media NODE AND ITS ONE ACTION.
                #
                # BOTH MEDIA ROWS OFFER IT - the category and an item under it -
                # which is the boot image rows' rule: it is one action on one
                # thing, and which of the two somebody right-clicks when there
                # is a single media definition is not worth being wrong about.
                #
                # THE CATEGORY RESOLVES TO THE ONLY MEDIA WHEN THERE IS ONE, and
                # is SHOWN DISABLED WITH THE REASON ON IT when there are
                # several: naming an ambiguous target is the one thing this
                # console does not do, and an item that vanished instead would
                # teach that media cannot be built from the category at all.
                # Hidden entirely on a share with none, because there is then
                # nothing it could ever name - the update store's own rule that
                # an item which can only answer no is worse than no item.
                $updateMediaItem.Visibility = [System.Windows.Visibility]::Collapsed
                $updateMediaItem.IsEnabled = $true
                $updateMediaItem.ToolTip = $null

                if ($menuRow.IsMediaRow) {
                    # THE ROW'S CHILDREN ARE READ, NOT THE SHARE. This runs in
                    # front of a menu that is supposed to appear under the
                    # pointer, and re-reading Media\ over SMB to count two
                    # folders is the 400ms the folder actions above refuse to
                    # spend for the same reason.
                    $mediaUnder = @(@($chosen.Children) |
                            Where-Object { [string] $_.Kind -eq 'Media' })

                    $mediaCount = @($mediaUnder).Count
                    if ([string] $chosen.Kind -eq 'Media') { $mediaCount = 1 }

                    if ($mediaCount -ge 1) {
                        $updateMediaItem.Visibility = [System.Windows.Visibility]::Visible
                    }

                    if ($mediaCount -gt 1) {
                        $updateMediaItem.IsEnabled = $false
                        $updateMediaItem.ToolTip = ('This share has {0} media definitions. Right-click the one you want to build.' -f $mediaCount)
                    }
                }

                # MDT'S New Media - THE CATEGORY ONLY, NEVER A MEDIA ITEM. "New"
                # on a row that already names one existing definition is not a
                # press that means anything, which is why this does not follow
                # Update Media Content's "both rows offer it" rule just above -
                # NO MARKUP, NO ITEM, as everywhere else on this menu.
                $isMediaCategory = ($null -ne $chosen -and
                    [string] $chosen.Kind -eq 'Category' -and
                    [string] $chosen.Name -eq 'Media')

                $newMediaItem.Visibility = [System.Windows.Visibility]::Collapsed

                if ($isMediaCategory -and -not [string]::IsNullOrWhiteSpace($NewMediaXaml)) {
                    $newMediaItem.Visibility = [System.Windows.Visibility]::Visible
                }

                # MDT'S Media NODE'S Delete - THE ITEM ONLY, NEVER THE
                # CATEGORY. The opposite asymmetry from Update Media Content
                # above: removing the category would have to mean removing
                # every media definition on the share at once, which is not
                # the press anybody is making by right-clicking a branch. No
                # markup gate - Remove Media composes a MessageBox from
                # Get-HDTConsoleRemoval, not a window of its own, so it needs
                # no -XamlPath to exist.
                $removeMedia.Visibility = [System.Windows.Visibility]::Collapsed

                if ($null -ne $chosen -and [string] $chosen.Kind -eq 'Media') {
                    $removeMedia.Visibility = [System.Windows.Visibility]::Visible
                }

                if ($onFolderRow -and ($isRoot -or $isShare -or $isCategory -or $isSequence -or $isOsCategory -or $isOperatingSystem -or $isAppCategory -or $isApplication -or $isBootImage -or $menuRow.IsSelectionProfile)) {
                    $folderSeparator.Visibility = [System.Windows.Visibility]::Visible
                }

                if (-not $menuRow.Opens) {
                    $opening.Handled = $true
                }
            }.GetNewClosure())

        # AND IT OPENS THE SAME WINDOW THE DOUBLE-CLICK OPENS. Both
        # rows carry workspace.yaml, so this reads the subject rather
        # than building a path from the share root: two shares in this
        # lab hold an image of the same name, and a window opened by
        # name could save one share's settings into the other's.
        $bootImageItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $document = [string] $chosen.Subject

                # AND IT SAYS SO RATHER THAN DOING NOTHING, as the
                # remove items do: a menu item that returns quietly is
                # one somebody presses twice and then reports as broken.
                if ([string]::IsNullOrWhiteSpace($document)) {
                    $command.Text = 'that row does not name a workspace document, so there is no boot image to open.'
                    return
                }

                & $openBootImage $document

                # THE IMAGE MAY HAVE BEEN BUILT WHILE IT WAS OPEN, and
                # the row under Boot Image reads the manifest - so it is
                # stale until the tree is read again.
                & $rebuildTree
            }.GetNewClosure())

        # WORKBENCH'S Advanced Configuration \ Selection Profiles. The
        # row carries the SHARE ROOT rather than a document, because a
        # profile is share-wide and the window works out its own path.
        $selectionProfileItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $shareRoot = [string] $chosen.Subject

                # IT SAYS SO RATHER THAN DOING NOTHING, as the boot image
                # item does: a menu item that returns quietly is one
                # somebody presses twice and then reports as broken.
                if ([string]::IsNullOrWhiteSpace($shareRoot)) {
                    $command.Text = 'that row does not name a share, so there are no selection profiles to open.'
                    return
                }

                try {
                    [void] (& $call 'Show-HDTSelectionProfileWindow' @{
                            Root = $shareRoot; ConsoleHost = $consoleHost
                            OwnerWidth = [int] $window.Width; OwnerHeight = [int] $window.Height
                        })
                } catch {
                    $command.Text = '# {0}' -f [string] $_.Exception.Message
                    return
                }

                # THE PROFILES MAY HAVE CHANGED WHILE IT WAS OPEN, and
                # the branch lists them - so it is stale until the tree
                # is read again.
                & $rebuildTree
            }.GetNewClosure())

        # REMOVE ASKS, AND THE DIALOG IS THE ONLY PLACE IT IS ASKED.
        # Remove-HDTTaskSequence carries ConfirmImpact High, which would
        # otherwise prompt at a console nobody is looking at - a window
        # that appears to hang. The answer here is passed as
        # -Confirm:$false: one decision, made where it was offered.
        $removeSequence.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                # AND IT SAYS SO RATHER THAN DOING NOTHING. A handler
                # that returns quietly on a row it cannot read is a menu
                # item somebody presses twice and then reports as broken.
                # This is one of the three irreversible presses in the
                # window, and all three compose their question in
                # Get-HDTConsoleRemoval now -
                # tests/unit/ConsoleRemoval.Tests.ps1.
                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'TaskSequence' -Root $where -Id $which
                if (-not $ask.CanRemove) {
                    $command.Text = [string] $ask.Refusal
                    return
                }

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (Remove-HDTTaskSequence -Workspace $where -Id $which -Confirm:$false)
                    $command.Text = [string] $ask.Command
                } catch {
                    # THE REFUSAL IS THE ANSWER, and this command's
                    # refusals are the ones worth reading: a folder that
                    # holds no sequence, an id that is a path.
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        $importOperatingSystem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                # THE ROW SAYS WHICH SHARE, for the same reason the New
                # Task Sequence item reads it: several shares in one
                # window, and only the row knows which one was clicked.
                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $made = [string] $consoleHost.ShowImportOperatingSystem(
                    $ImportOperatingSystemXaml, $where, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                $command.Text = "Import-HDTOperatingSystem -WorkspaceRoot '{0}' -Id '{1}' -SourcePath ..." -f $where, $made

                & $rebuildTree
            }.GetNewClosure())

        # REMOVING MEDIA IS WORSE THAN REMOVING A SEQUENCE, and the
        # dialog says so: a sequence is a file somebody wrote, and this
        # is several gigabytes that came off a DVD. UsedBy is why the
        # command reads the sequences first - a deployment that would
        # have failed at Apply Operating System, minutes in, is worth
        # naming before it does.
        $removeOperatingSystem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                $refusal = & $call 'Get-HDTConsoleRemoval' -Kind 'OperatingSystem' -Root $where -Id $which
                if (-not $refusal.CanRemove) {
                    $command.Text = [string] $refusal.Refusal
                    return
                }

                # ASKED FOR WITHOUT REMOVING ANYTHING: -WhatIf returns
                # UsedBy, so the dialog can name the sequences before
                # anybody agrees to anything - and a sequence without
                # its image FAILS, which is not what a missing
                # application does. Get-HDTConsoleRemoval keeps those
                # two sentences apart.
                $using = @()

                try {
                    $using = @((Remove-HDTOperatingSystem -Workspace $where -Id $which -WhatIf).UsedBy)
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'OperatingSystem' -Root $where -Id $which `
                    -UsedBy ([string[]] @($using))

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (Remove-HDTOperatingSystem -Workspace $where -Id $which -Confirm:$false)
                    $command.Text = [string] $ask.Command
                } catch {
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        # MDT'S Import OS Packages, REACHABLE AT LAST. The dialog and
        # the host method that shows it were both written and nothing on
        # this window opened either of them.
        $importWindowsUpdateItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot

                # AND IT SAYS SO RATHER THAN DOING NOTHING, as every other
                # item here does: a menu item that returns quietly is one
                # somebody presses twice and then reports as broken.
                if ([string]::IsNullOrWhiteSpace($where)) {
                    $command.Text = 'that row does not name a share, so there is nowhere to import an update to.'
                    return
                }

                # THE RELEASE THE ROW IS FOR, AND ONLY FROM A RELEASE ROW.
                # The dialog preselects nothing when it is opened from the
                # category, deliberately - -Release is mandatory because no
                # .msu says which operating system it is for, and defaulting
                # to the first row is how a Windows Server update gets filed
                # under a client release. Right-clicking 'Windows Server
                # 2025' is not a default: it is the administrator naming the
                # release, so that one row arrives preselected.
                #
                # ASKED AGAIN RATHER THAN CARRIED FROM THE OPENING HANDLER.
                # The same command answers both, so the item and the press
                # cannot disagree about which release the row is for - and
                # there is no shared mutable holder between two closures to
                # get stale.
                $menuRow = & $call 'Get-HDTConsoleTreeMenuRow' `
                    -Kind ([string] $chosen.Kind) -Name ([string] $chosen.Name)

                $made = [string] $consoleHost.ShowImportWindowsUpdate(
                    $ImportWindowsUpdateXaml, $where, [string] $menuRow.UpdateRelease, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                $command.Text = "Import-HDTWindowsUpdate -WorkspaceRoot '{0}' -Id '{1}' -Release ... -Path ..." -f
                    $where, $made

                & $rebuildTree
            }.GetNewClosure())

        # REMOVING AN UPDATE IS USUALLY MILDER THAN REMOVING MEDIA, AND
        # THE DIALOG SAYS WHICH KIND IT IS. An ApplyUpdates step that
        # names only a RELEASE points at no folder by name, so the
        # machine simply arrives without this update; a step whose
        # `updates` NAMES THIS ID does point here and refuses at the
        # machine once the folder is gone. Get-HDTConsoleRemoval's
        # sentence carries both halves. The .msu is most of a gigabyte
        # somebody downloaded either way, which is why this asks at all.
        $removeWindowsUpdateItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                $refusal = & $call 'Get-HDTConsoleRemoval' -Kind 'WindowsUpdate' -Root $where -Id $which
                if (-not $refusal.CanRemove) {
                    $command.Text = [string] $refusal.Refusal
                    return
                }

                # ASKED FOR WITHOUT REMOVING ANYTHING: -WhatIf returns
                # UsedBy, so the dialog can name the sequences before
                # anybody agrees to anything.
                $using = @()

                try {
                    $using = @((Remove-HDTWindowsUpdate -WorkspaceRoot $where -Id $which -WhatIf).UsedBy)
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'WindowsUpdate' -Root $where -Id $which `
                    -UsedBy ([string[]] @($using))

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (Remove-HDTWindowsUpdate -WorkspaceRoot $where -Id $which -Confirm:$false)
                    $command.Text = [string] $ask.Command
                } catch {
                    # THE REFUSAL IS THE ANSWER, and this command's
                    # refusals are the ones worth reading: a folder that
                    # holds no update.yaml, an id that is a path.
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        $newSequence.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                # THE ROW SAYS WHICH SHARE. Two shares in one window
                # commonly hold sequences with the same id, so the
                # node's own root is the only answer that cannot write
                # to the wrong one.
                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $made = [string] $consoleHost.ShowNewSequence($NewSequenceXaml, $where, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                # THE TREE IS REBUILT, or the sequence that was just
                # created is not in the window that created it - the
                # refresh timer only rebuilds the monitor rows.
                & $rebuildTree

                                        $command.Text = "New-HDTTaskSequence -Workspace '{0}'" -f $where
            }.GetNewClosure())

        # -- the shares themselves -------------------------------
        #
        # WORKBENCH'S ROOT NODE ACTIONS, which this console had none of:
        # the shares in the window were the ones named on the command
        # line, and a new one was New-HDTWorkspace at a prompt.
        #
        # ADDING A SHARE IS A REBUILD WITH ONE MORE PATH. The tree is
        # what says which shares are open, so there is no second list to
        # keep in step with it.
        $newWorkspace.Add_Click({
                $made = [string] $consoleHost.ShowNewWorkspace($NewWorkspaceXaml, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                & $rebuildFrom ([string[]] @(@(& $openShare) + @($made)))

                $command.Text = "New-HDTWorkspace -Path '{0}'" -f $made
            }.GetNewClosure())

        # OPENING NEEDS NO DIALOG OF ITS OWN: a folder picker and a
        # check. Test-HDTConsoleOpenWorkspace is that check, and it is
        # the one place that decides what counts as a share to open.
        $openWorkspace.Add_Click({
                $picker = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $picker.Title = 'Open the deployment share folder, and press Open'
                $picker.CheckFileExists = $false
                $picker.FileName = 'this folder'
                $picker.Filter = 'All files (*.*)|*.*'

                if ($picker.ShowDialog($window) -ne $true) { return }

                $chosenPath = [string] [System.IO.Path]::GetDirectoryName($picker.FileName)
                $already = [string[]] @(& $openShare)

                $answer = & $call 'Test-HDTConsoleOpenWorkspace' -Path $chosenPath -Open $already

                # THE REFUSAL GOES IN THE COMMAND BOX, which is where
                # this window says everything else that went wrong.
                if (-not $answer.CanOpen) {
                    $command.Text = [string] $answer.Message
                    return
                }

                $window.Cursor = [System.Windows.Input.Cursors]::AppStarting

                try {
                    & $rebuildFrom ([string[]] @(@($already) + @($chosenPath)))
                } finally {
                    $window.Cursor = $null
                }

                # A command an administrator can actually run: the
                # reader behind this row is internal to the window.
                $command.Text = "Show-HDTConsole -Path '{0}'" -f $chosenPath
            }.GetNewClosure())

        # CLOSING TAKES IT OUT OF THE WINDOW AND DELETES NOTHING, and
        # the dialog says so: 'Remove' is what the task sequence and the
        # operating system items are called, and those do delete.
        $closeWorkspace.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $keep = [string[]] @(@(& $openShare) | Where-Object {
                        -not [string]::Equals([string] $_, $where, [System.StringComparison]::OrdinalIgnoreCase)
                    })

                & $rebuildFrom $keep

                $command.Text = "# '{0}' was closed. Nothing on it was changed; Open Deployment Share puts it back." -f $where
            }.GetNewClosure())

        # -- media -------------------------------------------------
        #
        # THE CATEGORY ONLY - the guard above never shows this item on a
        # media item row, so $chosen.HeaderRoot is always the share and never
        # one existing definition's own root.
        $newMediaItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $made = [string] $consoleHost.ShowNewMedia($NewMediaXaml, $where, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                & $rebuildTree

                $command.Text = "New-HDTMedia -WorkspaceRoot '{0}' -Id '{1}'" -f $where, $made
            }.GetNewClosure())

        # -- applications ----------------------------------------
        #
        # THE PART OF A SHARE THAT CHANGES WEEKLY, and until now the one
        # part with no window at all. Both of these are one cmdlet call,
        # like every other press here.
        $newApplication.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $made = [string] $consoleHost.ShowImportApplication(
                    $ImportApplicationXaml, $where, $Theme, $window)

                if ([string]::IsNullOrWhiteSpace($made)) { return }

                & $rebuildTree

                $command.Text = "Import-HDTApplication -WorkspaceRoot '{0}' -Id '{1}'" -f $where, $made
            }.GetNewClosure())

        # DETECTION IS A TYPE AND THE BOXES THAT TYPE TAKES, which is
        # why it gets a window rather than a box: a rule is four shapes,
        # and typing YAML into a field means knowing which keys the type
        # takes and the indentation between them.
        $applicationDetection.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                if ([string]::IsNullOrWhiteSpace($where) -or [string]::IsNullOrWhiteSpace($which)) {
                    $command.Text = 'that row does not name a share and an application id, so there is nothing to edit.'
                    return
                }

                # THE DOCUMENT, NOT THE ROW. The row carries the rule as
                # a sentence for reading; the window needs the keys.
                $rule = $null

                try {
                    $rule = (Get-HDTApplication -WorkspaceRoot $where -Id $which -FileSystem (New-HDTFileSystem)).Detect
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $answer = $consoleHost.ShowApplicationDetection(
                    $ApplicationDetectionXaml, $where, $which, $rule, $Theme, $window)

                # A CANCELLED DIALOG AND A CLEARED RULE BOTH COME BACK
                # NULL, so the tree is rebuilt either way rather than
                # left showing a rule that has just been removed.
                & $rebuildTree

                $command.Text = "Set-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -Detect {2}" -f
                $where, $which, (& $call 'Get-HDTConsoleDetectionForm' -Detect $answer).CommandText
            }.GetNewClosure())

        # DEPENDS ON IS PICKED FROM THE SHARE, and that is the whole
        # point of the window: a dependency is an application id in a
        # document, and a misspelled one is not caught until a
        # deployment runs, when Resolve-HDTApplicationOrder refuses the
        # WHOLE plan rather than that one application.
        #
        # THE SHARE IS RE-READ RATHER THAN TAKEN FROM THE ROW. The tree
        # holds what the share looked like when it was built, and the
        # list this offers has to be what is on it now - a dialog is
        # slow enough to open that 400ms does not show.
        $applicationDependency.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                if ([string]::IsNullOrWhiteSpace($where) -or [string]::IsNullOrWhiteSpace($which)) {
                    $command.Text = 'that row does not name a share and an application id, so there is nothing to edit.'
                    return
                }

                try {
                    $share = & $call 'Get-HDTConsoleWorkspace' -Path $where
                    $offer = @(& $call 'Get-HDTConsoleDependencyChoice' -Application ([object[]] @($share.Application)) -Id $which)
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $answer = $consoleHost.ShowApplicationDependency(
                    $ApplicationDependencyXaml, $where, $which, ([object[]] $offer), $Theme, $window)

                if ($null -eq $answer) { return }

                & $rebuildTree

                $command.Text = "Set-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -Dependency @({2})" -f
                $where, $which, ((@($answer) | ForEach-Object { "'{0}'" -f $_ }) -join ', ')
            }.GetNewClosure())

        # REMOVE ASKS, AND THE DIALOG NAMES WHAT WOULD BREAK. A missing
        # dependency is worse than a missing package: Resolve-HDTApplicationOrder
        # refuses the whole plan, so removing this one can stop an
        # unrelated application installing at all. -WhatIf answers that
        # without removing anything, which is why it is asked first.
        $removeApplication.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                # WHAT THIS DIALOG SAYS IS THE LAST THING ANYBODY READS
                # before the folder goes - app.yaml and the installer
                # with it, and no undo in this window. Which sequences
                # install it and which applications DEPEND on it are two
                # different consequences and get two different
                # sentences: the first leaves a machine missing
                # something, the second stops an install altogether,
                # later, on a deployment nobody connects to this press.
                # tests/unit/ConsoleApplicationRemoval.Tests.ps1.
                $refusal = & $call 'Get-HDTConsoleRemoval' -Kind 'Application' -Root $where -Id $which
                if (-not $refusal.CanRemove) {
                    $command.Text = [string] $refusal.Refusal
                    return
                }

                $answer = $null

                try {
                    $answer = Remove-HDTApplication -WorkspaceRoot $where -Id $which -WhatIf
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'Application' -Root $where -Id $which `
                    -UsedBy ([string[]] @($answer.UsedBy)) `
                    -RequiredBy ([string[]] @($answer.RequiredBy))

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (Remove-HDTApplication -WorkspaceRoot $where -Id $which -Confirm:$false)
                    $command.Text = [string] $ask.Command
                } catch {
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        # THE SAME SKELETON AS removeApplication ABOVE, with Remove-HDTMedia's
        # own -WhatIf answer - Id, Path, IsoLeftBehind - in place of
        # UsedBy/RequiredBy: nothing on this share depends on a media item the
        # way a sequence depends on an application or an image, so
        # Get-HDTConsoleRemoval's UsedFormat stays empty for 'Media' and the
        # one consequence this kind DOES have - an ISO left outside the media
        # folder - is appended to the question here rather than taught to
        # that generic composer.
        $removeMedia.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                $refusal = & $call 'Get-HDTConsoleRemoval' -Kind 'Media' -Root $where -Id $which
                if (-not $refusal.CanRemove) {
                    $command.Text = [string] $refusal.Refusal
                    return
                }

                $answer = $null

                try {
                    $answer = Remove-HDTMedia -WorkspaceRoot $where -Id $which -WhatIf
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'Media' -Root $where -Id $which

                # THE ONE CONSEQUENCE ONLY Remove-HDTMedia HAS, appended to
                # the shared question rather than a fourth shape taught to
                # Get-HDTConsoleRemoval for the one kind that needs it.
                $question = [string] $ask.Question
                if (-not [string]::IsNullOrEmpty([string] $answer.IsoLeftBehind)) {
                    $question = '{0}{1}{1}Its ISO is at {2}, outside the media folder, and will NOT be removed.' -f
                        $question, [System.Environment]::NewLine, [string] $answer.IsoLeftBehind
                }

                $asked = [System.Windows.MessageBox]::Show($window,
                    $question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (Remove-HDTMedia -WorkspaceRoot $where -Id $which -Confirm:$false)
                    $command.Text = [string] $ask.Command
                } catch {
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        # -- folders ---------------------------------------------
        #
        # WORKBENCH'S FOLDERS, ON A TREE THAT HAS NO DIRECTORIES TO
        # NEST. What each item offers is Get-HDTConsoleFolderAction's
        # decision; these three handlers do what every other press in
        # this window does - read a document, call one cmdlet, save,
        # rebuild - and each names the cmdlet it ran in the Command box.
        #
        # ONE TYPED LINE IS ALL THEY ASK FOR, so the prompt is built
        # here rather than given markup: a window with a label, a box
        # and an OK is the whole of it, and a .xaml file for that is a
        # file to keep in step with three call sites.
        $askForFolder = {
            param([string] $Title, [string] $Prompt, [string[]] $Choice, [string] $Initial)

            Add-Type -AssemblyName PresentationFramework

            $ask = New-Object -TypeName System.Windows.Window
            # THROUGH THE DOOR, because this prompt is reached from
            # closures. A closure resolves commands in the session state
            # it was rebound to - the console's - where a PRIVATE
            # function does not exist, so naming it directly here threw
            # "'Get-HDTConsoleWindowIcon' is not recognized" out of a
            # menu click and took the whole window down with it. See
            # Get-HDTHandlerCall.
            $ask.Icon = & $call 'Get-HDTConsoleWindowIcon'
            $ask.Title = $Title
            $ask.Width = 440
            $ask.SizeToContent = [System.Windows.SizeToContent]::Height
            $ask.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
            $ask.Owner = $window
            $ask.ResizeMode = [System.Windows.ResizeMode]::NoResize

            $panel = New-Object -TypeName System.Windows.Controls.StackPanel
            $panel.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 16

            $label = New-Object -TypeName System.Windows.Controls.TextBlock
            $label.Text = $Prompt
            $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $label.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 0, 0, 0, 10

            # EDITABLE, AND THE LIST IS A CONVENIENCE. Moving something
            # into a folder that does not exist yet is how the second
            # folder gets made, so the box has to accept a name that is
            # not in the list - and on a share with no folders at all
            # the list is empty and this is a text box.
            $entry = New-Object -TypeName System.Windows.Controls.ComboBox
            $entry.IsEditable = $true
            $entry.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 0, 0, 0, 12

            foreach ($one in @($Choice)) { [void] $entry.Items.Add([string] $one) }
            $entry.Text = $Initial

            $accept = New-Object -TypeName System.Windows.Controls.Button
            $accept.Content = 'OK'
            $accept.IsDefault = $true
            $accept.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
            $accept.Padding = New-Object -TypeName System.Windows.Thickness -ArgumentList 14, 6, 14, 6
            $accept.Add_Click({ $ask.DialogResult = $true }.GetNewClosure())

            [void] $panel.Children.Add($label)
            [void] $panel.Children.Add($entry)
            [void] $panel.Children.Add($accept)

            $ask.Content = $panel
            [void] $entry.Focus()

            # CANCELLED IS NOT EMPTY. An empty box means "take it out of
            # every folder", which is a thing to ask for, so the two
            # answers cannot come back as the same value.
            if ($ask.ShowDialog() -ne $true) { return $null }

            return ([string] $entry.Text).Trim()
        }.GetNewClosure()

        # -- the driver store's two, which are MDT's ------------------
        #
        # WIRED HERE BECAUSE $askForFolder HAS TO EXIST FIRST. A closure
        # captures a variable's VALUE, so a handler hung above it would
        # capture $null and do nothing on the one press that matters.
        #
        # NO WINDOW OF THEIR OWN. New Folder needs one string and the
        # console already has a prompt for exactly that; Import needs a
        # folder and the boot image window already browses for one. A
        # third dialog would be a third thing to keep in step.
        $newDriverFolderItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                # AND IT SAYS SO RATHER THAN DOING NOTHING, which this
                # console has a rule about and which this handler broke:
                # the Drivers category carried no Subject, so both items
                # appeared and neither did anything, twice, before
                # somebody reported it as broken.
                $where = [string] $chosen.Subject
                if ([string]::IsNullOrWhiteSpace($where)) {
                    $command.Text = 'that row does not name a share, so there is no driver store to add to.'
                    return
                }

                $menuRow = & $call 'Get-HDTConsoleTreeMenuRow' `
                    -Kind ([string] $chosen.Kind) -Name ([string] $chosen.Name) `
                    -DriverPath ([string] $chosen.Name)

                # THE PARENT IS THE ROW IT WAS ASKED ON, which is what
                # makes one item serve both "at the top of the store" and
                # "inside this vendor folder".
                $parent = [string] $menuRow.DriverParent

                $prompt = 'A folder in the driver store. Vendor WinPE packs usually go under WinPE\, model packs under the Make.'
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    $prompt = 'A folder inside {0}.' -f $parent
                }

                $typed = & $askForFolder 'New Folder' $prompt @() ''

                if ([string]::IsNullOrWhiteSpace($typed)) { return }

                $path = $typed
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    $path = [System.IO.Path]::Combine($parent, $typed)
                }

                try {
                    $made = & $call 'New-HDTDriverFolder' @{
                        Root = $where; Path = $path; Confirm = $false
                    }
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                & $rebuildTree

                $command.Text = "New-HDTDriverFolder -Root '{0}' -Path '{1}'" -f $where, [string] $made.Path
            }.GetNewClosure())

        $importDriverItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.Subject
                if ([string]::IsNullOrWhiteSpace($where)) {
                    $command.Text = 'that row does not name a share, so there is nowhere to import to.'
                    return
                }

                $menuRow = & $call 'Get-HDTConsoleTreeMenuRow' `
                    -Kind ([string] $chosen.Kind) -Name ([string] $chosen.Name) `
                    -DriverPath ([string] $chosen.Name)

                $parent = [string] $menuRow.DriverParent

                # SHELL COM, NOT System.Windows.Forms - a contract test
                # says so, because System.Windows.Forms is not guaranteed
                # by WinPE-NetFx and the rule is file-blind on purpose.
                $shell = New-Object -ComObject Shell.Application
                $picked = $shell.BrowseForFolder(0, 'Choose the folder the vendor pack was extracted into', 0)

                if ($null -eq $picked) { return }

                $source = [string] $picked.Self.Path
                if ([string]::IsNullOrWhiteSpace($source)) { return }

                # THE FOLDER IT LANDS IN IS NAMED AFTER THE PACK unless
                # the row already is one. Importing onto the store root
                # would tip a vendor's whole tree in beside the others.
                $path = $parent

                if ([string]::IsNullOrWhiteSpace($path)) {
                    $path = [string] (Split-Path -Path $source -Leaf)
                }

                # NOT ON THIS THREAD. A 2.38 GB Dell pack takes 86 seconds to
                # expand and an administrator reported the console as CRASHED -
                # it was not, it was the dispatcher blocked inside
                # Import-HDTDriver, and Windows had painted "Not Responding"
                # over it. A healthy 141-file pack freezes it too, just for
                # less time; the size only decided how obvious it was.
                #
                # The same window the boot image build uses, which is why that
                # method now takes a command rather than naming one. It shows
                # each driver as the catalogue reads it back, so the answer to
                # "what did I just import" is on screen rather than inferred
                # from a count.
                $command.Text = "Import-HDTDriver -Root '{0}' -Path '{1}' -Source '{2}'" -f $where, $path, $source

                [void] (Show-HDTBuildProgressWindow -WorkspaceRoot $where -ConsoleHost $consoleHost `
                        -Screen (New-HDTConsoleScreen) `
                        -Command 'Import-HDTDriver' `
                        -Argument @{ Root = $where; Path = $path; Source = $source } `
                        -StringPage 'ImportProgress' `
                        -LogFile ([System.IO.Path]::Combine(
                            (Get-HDTWorkspacePath -Root $where -Kind Drivers), 'driver-import.log')))

                & $rebuildTree
            }.GetNewClosure())

        # MDT'S Update Media Content, ON THE Media NODE.
        #
        # NOT ON THIS THREAD, AND FOR A LONGER REASON THAN THE DRIVER IMPORT'S.
        # Update-HDTMediaContent projects the whole share onto a bootable ISO -
        # twelve steps, a scratch tree, oscdimg - which is minutes and gigabytes
        # where a 2.38 GB driver pack was 86 seconds, and that one was already
        # reported as a crashed console. It goes through the same window the
        # boot image build and the driver import use, which is why that method
        # takes a command NAME and a plain hashtable rather than naming one: both
        # cross a runspace boundary, where a scriptblock would arrive bound to a
        # session state the far side cannot invoke. So no runspace code is
        # written here at all.
        #
        # -StringPage AND -LogFile ARE BOTH NAMED, AND NEITHER FAILS AT BIND TIME
        # WHEN IT IS NOT. -StringPage defaults to the boot image's wording, so an
        # omission heads the window 'Updating Boot Image' while it burns an ISO -
        # the exact lie the ImportProgress page was added to stop. -LogFile
        # empty derives the boot image's own Boot\<image>.build.log, and its own
        # parameter comment records the defect that cost: a driver import took
        # the default and overwrote the build log of an image it had nothing to
        # do with.
        $updateMediaItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.Subject
                if ([string]::IsNullOrWhiteSpace($where)) {
                    $command.Text = 'that row does not name a share, so there is no media to build.'
                    return
                }

                # THE ROW SAYS WHICH MEDIA, and the category says which only
                # when there is exactly one under it. The guard above already
                # disabled this item for an ambiguous category, so reaching here
                # without an id means the row was pressed some other way - and
                # it says so rather than guessing, which is the same refusal
                # Update-HDTMediaContent would make about a -Id it was not given.
                $menuRow = & $call 'Get-HDTConsoleTreeMenuRow' `
                    -Kind ([string] $chosen.Kind) -Name ([string] $chosen.Name)

                $which = [string] $menuRow.MediaId

                if ([string]::IsNullOrWhiteSpace($which)) {
                    $only = @(@($chosen.Children) | Where-Object { [string] $_.Kind -eq 'Media' })

                    if (@($only).Count -eq 1) { $which = [string] @($only)[0].Name }
                }

                # IT SAYS SO RATHER THAN DOING NOTHING, as every other item on
                # this menu does: one that returns quietly is one somebody
                # presses twice and then reports as broken.
                if ([string]::IsNullOrWhiteSpace($which)) {
                    $command.Text = 'that row does not name one media definition. Right-click the media you want to build.'
                    return
                }

                $command.Text = "Update-HDTMediaContent -WorkspaceRoot '{0}' -Id '{1}'" -f $where, $which

                # THE MEDIA'S OWN LOG, BESIDE ITS OWN DOCUMENT.
                # [IO.Path]::Combine and never Join-Path: the share may be a UNC
                # path nothing has mounted, and Join-Path resolves the drive and
                # throws DriveNotFound.
                $logFile = [System.IO.Path]::Combine(
                    (Get-HDTWorkspacePath -Root $where -Kind Media -ChildPath $which), 'media.build.log')

                [void] (Show-HDTBuildProgressWindow -WorkspaceRoot $where -ConsoleHost $consoleHost `
                        -Screen (New-HDTConsoleScreen) `
                        -Command 'Update-HDTMediaContent' `
                        -Argument @{ WorkspaceRoot = $where; Id = $which } `
                        -StringPage 'MediaProgress' `
                        -LogFile $logFile)

                # THE ISO WAS JUST WRITTEN AND THE ROW READS THE MANIFEST, so
                # 'Last build' on it is stale until the tree is read again -
                # which is what the boot image build does for the same reason.
                & $rebuildTree
            }.GetNewClosure())

        # DELETE ASKS, AND THE DIALOG IS THE ONLY PLACE IT IS ASKED, for
        # the same reason Remove Task Sequence does: Remove-HDTDriverFolder
        # carries ConfirmImpact High, which at a console nobody is looking
        # at is a window that appears to hang. The answer is passed as
        # -Confirm:$false - one decision, made where it was offered.
        # RENAME, WHICH THE CONSOLE COULD NOT DO. It could make a driver folder
        # and delete one, and an administrator fixing a typo had to leave for
        # Explorer - where the rename moves the directory and silently orphans
        # every selection profile and disabled driver that named it.
        #
        # NO WINDOW OF ITS OWN: $askForFolder is the prompt New Folder already
        # uses, and this needs the same one string.
        $renameDriverFolderItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.Subject
                if ([string]::IsNullOrWhiteSpace($where)) {
                    $command.Text = 'that row does not name a share, so there is no folder to rename.'
                    return
                }

                # The row names itself from the share's root - 'Drivers\WinPE\Dell'
                # - and Rename-HDTDriverFolder counts from inside the store.
                $which = [string] $chosen.Name
                if ($which -match '^(?i)Drivers\\') { $which = $which.Substring(('Drivers\').Length) }

                # SEEDED WITH THE CURRENT LEAF, because a rename is usually an
                # edit of the name that is there rather than a new one typed
                # from nothing.
                $leaf = [string] (Split-Path -Path $which -Leaf)

                # FOUR ARGUMENTS, NOT THREE: the prompt is
                # ($Title, $Prompt, $Choice, $Initial) and passing the name
                # third binds it to $Choice - a [string[]] of options - so the
                # box would offer the current name as a dropdown item instead of
                # seeding the field with it. It would have looked almost right.
                $answer = & $askForFolder 'Rename Driver Folder' 'New name' @() $leaf
                if ($null -eq $answer) { return }
                if ([string]::IsNullOrWhiteSpace($answer)) { return }

                try {
                    $renamed = & $call 'Rename-HDTDriverFolder' @{
                        Root = $where; Path = $which; NewName = $answer; Confirm = $false
                    }
                } catch {
                    $command.Text = '# {0}' -f [string] $_.Exception.Message
                    return
                }

                & $rebuildTree

                $command.Text = "Rename-HDTDriverFolder -Root '{0}' -Path '{1}' -NewName '{2}'" -f
                    $where, $which, $answer

                # WHAT ELSE IT TOUCHED, SAID OUT LOUD. A rename that quietly
                # rewrote a selection profile is a rename somebody will not
                # think to check when a boot image later injects the wrong set.
                if ([bool] $renamed.ProfileUpdated -or [bool] $renamed.StateUpdated) {
                    $command.Text = '{0}   # also updated: {1}' -f $command.Text,
                        ((@(
                            $(if ([bool] $renamed.ProfileUpdated) { 'selection profiles' })
                            $(if ([bool] $renamed.StateUpdated) { 'disabled drivers' })
                        ) | Where-Object { $_ }) -join ', ')
                }
            }.GetNewClosure())

        $removeDriverFolderItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.Subject

                # THE ROW NAMES ITSELF FROM THE SHARE'S ROOT -
                # 'Drivers\WinPE\Dell' - and Remove-HDTDriverFolder
                # counts from inside the store.
                $which = [string] $chosen.Name
                if ($which -match '^(?i)Drivers\\') { $which = $which.Substring(('Drivers\').Length) }

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'DriverFolder' -Root $where -Id $which
                if (-not $ask.CanRemove) {
                    $command.Text = [string] $ask.Refusal
                    return
                }

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (& $call 'Remove-HDTDriverFolder' @{
                            Root = $where; Path = $which; Confirm = $false
                        })
                    $command.Text = [string] $ask.Command
                } catch {
                    # THE REFUSAL IS THE ANSWER, and this command's are
                    # the ones worth reading: the store itself, a path
                    # that climbs out of it.
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        # CLEARING A RUN ASKS TOO, for the reason every other delete on
        # this menu asks: Remove-HDTMonitorRun carries ConfirmImpact
        # High, and a prompt raised on a console nobody is looking at is
        # a window that appears to have hung. The answer is passed as
        # -Confirm:$false - one decision, made where it was offered.
        #
        # THE QUESTION IS NOT THE OTHERS' QUESTION. Nothing on the share
        # reads a heartbeat, so Get-HDTConsoleRemoval says so rather than
        # warning about an undo that nobody needs.
        $removeMonitorRunItem.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                # THE ROW CARRIES ITS SHARE. Building the root from the
                # window instead would be wrong the moment two shares are
                # open, which is the case this console was built for.
                $where = [string] $chosen.HeaderRoot
                $which = [string] $chosen.Name

                $ask = & $call 'Get-HDTConsoleRemoval' -Kind 'MonitorRun' -Root $where -Id $which
                if (-not $ask.CanRemove) {
                    $command.Text = [string] $ask.Refusal
                    return
                }

                $asked = [System.Windows.MessageBox]::Show($window,
                    [string] $ask.Question,
                    [string] $ask.Title,
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question,
                    [System.Windows.MessageBoxResult]::No)

                if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                try {
                    [void] (& $call 'Remove-HDTMonitorRun' @{
                            Root = $where; RunId = $which; Confirm = $false
                        })
                    $command.Text = [string] $ask.Command
                } catch {
                    $command.Text = [string] $_.Exception.Message
                }

                & $rebuildTree
            }.GetNewClosure())

        $newFolder.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                if ([string]::IsNullOrWhiteSpace($where)) { return }

                $action = & $call 'Get-HDTConsoleFolderAction' -Row $chosen
                if (-not $action.CanCreate) { return }

                # THE PARENT IS THE ROW IT WAS ASKED FOR ON, which is
                # what makes one item serve both "at the top" and
                # "inside this one" - and the prompt is the last place
                # anybody can tell which of the two is about to happen.
                # tests/unit/ConsoleFolderCreate.Tests.ps1.
                #
                # Asked once for the prompt, and again once a name has
                # been typed: the folder path is not known until then.
                $ask = & $call 'Get-HDTConsoleFolderCreate' -Root $where `
                    -Parent ([string] $action.Parent) -Category ([string] $action.Category)

                $typed = & $askForFolder 'New Folder' ([string] $ask.Prompt) @() ''

                if ([string]::IsNullOrWhiteSpace($typed)) { return }

                $make = & $call 'Get-HDTConsoleFolderCreate' -Root $where `
                    -Parent ([string] $action.Parent) -Name $typed `
                    -Category ([string] $action.Category)

                $path = [string] $make.Folder
                $documentPath = [string] $make.DocumentPath

                try {
                    $fileSystem = New-HDTFileSystem
                    $line = [string[]] @([string] $fileSystem.ReadAllText($documentPath) -split "`r?`n")

                    [void] (Save-HDTWorkspaceDocument -Path $documentPath -FileSystem $fileSystem -Confirm:$false `
                            -Line @(Add-HDTWorkspaceFolder -Line $line -Category ([string] $action.Category) `
                                -Folder $path -Confirm:$false))
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                & $rebuildTree

                $command.Text = [string] $make.Command
            }.GetNewClosure())

        # MOVING IS A ONE-KEY EDIT TO THE DOCUMENT, not a file
        # operation: the sequence stays at TaskSequences\<id>, because
        # its id is the path the engine resolves it from and every rule
        # and boot image that names it would otherwise break.
        $moveToFolder.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $action = & $call 'Get-HDTConsoleFolderAction' -Row $chosen
                if (-not $action.CanMove) { return }

                # WHICH COMMANDS THIS MOVE TAKES, decided away from the
                # window - and in particular WHICH SAVER GOES WITH WHICH
                # SETTER. Each saver validates the lines against its own
                # document's keys, so the wrong one refuses a document
                # the setter has already written correctly, and the
                # failure reads as a broken setter.
                # tests/unit/ConsoleFolderMove.Tests.ps1 holds that
                # pairing, and the application exception with it.
                $move = & $call 'Get-HDTConsoleFolderMove' -Row $chosen `
                    -Category ([string] $action.Category)

                $typed = & $askForFolder 'Move to Folder' `
                    'The folder this window draws it under. Type a name that is not in the list to make that folder; leave it empty to take it out of every folder. Nothing moves on disk.' `
                ([string[]] @($action.Choice)) $move.Current

                if ($null -eq $typed) { return }
                if ($typed -eq $move.Current) { return }

                try {
                    # AN APPLICATION WRITES ITSELF: Set-HDTApplication
                    # takes a share and an id rather than lines, and
                    # saves - so there is nothing here to read first.
                    if ($move.Kind -eq 'Application') {
                        [void] (Set-HDTApplication -WorkspaceRoot ([string] $move.WorkspaceRoot) `
                                -Id ([string] $move.Id) -Folder $typed -Confirm:$false)
                    } else {
                        $fileSystem = New-HDTFileSystem
                        $line = [string[]] @([string] $fileSystem.ReadAllText($move.DocumentPath) -split "`r?`n")

                        [void] (& $move.Saver -Path ([string] $move.DocumentPath) `
                                -FileSystem $fileSystem -Confirm:$false `
                                -Line @(& $move.Setter -Line $line -Folder $typed -Confirm:$false))
                    }
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                & $rebuildTree

                $command.Text = $move.CommandFormat -f $typed
            }.GetNewClosure())

        $deleteFolder.Add_Click({
                $chosen = $tree.SelectedItem
                if ($null -eq $chosen) { return }

                $where = [string] $chosen.HeaderRoot
                $action = & $call 'Get-HDTConsoleFolderAction' -Row $chosen

                # THE REFUSAL IS SAID, NOT SWALLOWED. The item is
                # disabled, so this only runs if something else opened
                # it - and a handler that returns quietly is a menu item
                # somebody presses twice and then reports as broken.
                if (-not $action.CanDelete) {
                    $command.Text = [string] $action.DeleteRefusal
                    return
                }

                $documentPath = [System.IO.Path]::Combine($where, 'workspace.yaml')

                try {
                    $fileSystem = New-HDTFileSystem
                    $line = [string[]] @([string] $fileSystem.ReadAllText($documentPath) -split "`r?`n")

                    [void] (Save-HDTWorkspaceDocument -Path $documentPath -FileSystem $fileSystem -Confirm:$false `
                            -Line @(Remove-HDTWorkspaceFolder -Line $line -Category ([string] $action.Category) `
                                -Folder ([string] $action.Parent) -Confirm:$false))
                } catch {
                    $command.Text = [string] $_.Exception.Message
                    return
                }

                & $rebuildTree

                $command.Text = "Remove-HDTWorkspaceFolder -Line `$line -Category {0} -Folder '{1}'" -f
                [string] $action.Category, [string] $action.Parent
            }.GetNewClosure())

        # UP AND DOWN ARE ONE HANDLER TWICE, because they differ in one
        # word. A folder is an entry in an ordered list in
        # workspace.yaml; this moves it among the entries beside it and
        # rebuilds the tree, which now draws that order.
        $moveFolder = {
            param([string] $Direction)

            $chosen = $tree.SelectedItem
            if ($null -eq $chosen) { return }

            $action = & $call 'Get-HDTConsoleFolderAction' -Row $chosen

            $allowed = $action.CanMoveUp
            if ($Direction -eq 'Down') { $allowed = $action.CanMoveDown }

            # SAID, NOT SWALLOWED - the item is disabled at the ends, so
            # this only runs if something else opened it, and a handler
            # that returns quietly is a menu item somebody presses twice
            # and then reports as broken.
            if (-not $allowed) {
                $command.Text = ("'{0}' is already {1} in this folder, so there is nowhere to move it." -f
                    [string] $chosen.Text, $(if ($Direction -eq 'Down') { 'last' } else { 'first' }))
                return
            }

            # HeaderRoot, NOT Subject. Group-HDTConsoleFolderRow builds a
            # folder node without a subject - a folder is not a thing on
            # the share to act on - so the share it belongs to comes off
            # the banner it carries, which is where Delete Folder reads
            # it from too. Reading Subject here returned an empty string
            # and the handler gave up in silence.
            $where = [string] $chosen.HeaderRoot
            if ([string]::IsNullOrWhiteSpace($where)) { return }

            $documentPath = [System.IO.Path]::Combine($where, 'workspace.yaml')

            try {
                $fileSystem = New-HDTFileSystem
                $line = [string[]] @([string] $fileSystem.ReadAllText($documentPath) -split "`r?`n")

                [void] (Save-HDTWorkspaceDocument -Path $documentPath -FileSystem $fileSystem -Confirm:$false `
                        -Line @(Move-HDTWorkspaceFolder -Line $line -Category ([string] $action.Category) `
                            -Folder ([string] $action.Parent) -Direction $Direction -Confirm:$false))
            } catch {
                $command.Text = [string] $_.Exception.Message
                return
            }

            & $rebuildTree

            $command.Text = "Move-HDTWorkspaceFolder -Line `$line -Category {0} -Folder '{1}' -Direction {2}" -f
            [string] $action.Category, [string] $action.Parent, $Direction
        }.GetNewClosure()

        $folderUp.Add_Click({ & $moveFolder 'Up' }.GetNewClosure())
        $folderDown.Add_Click({ & $moveFolder 'Down' }.GetNewClosure())

        $close.Add_Click({
                $consoleHost.Answer = 'Close'
                $window.Close()
            }.GetNewClosure())

        # THE SIZE IS TAKEN WHILE THE WINDOW STILL EXISTS. Read after ShowDialog
        # returns, RestoreBounds belongs to a window that has already been torn
        # down and throws - which surfaced as an error box saying "calling Show",
        # three frames from anything to do with a size. Closing is the last
        # moment it is a real window.
        #
        # RestoreBounds, not ActualWidth: a window closed while maximised or
        # minimised reports the screen, or nothing, and remembering either is how
        # a console comes back at a size nobody chose.
        $window.Add_Closing({
                $consoleHost.Width = [int] $window.RestoreBounds.Width
                $consoleHost.Height = [int] $window.RestoreBounds.Height
            }.GetNewClosure())
        return $window
}
