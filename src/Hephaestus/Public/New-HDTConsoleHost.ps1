function New-HDTConsoleHost {
    <#
        .SYNOPSIS
            The real IConsoleHost: loads the console XAML with XamlReader and
            shows the window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY
            BRANCH-FREE. The only exception to TDD in this toolkit is a thin
            adapter over something that cannot be faked - here WPF itself - and
            the price of that exception is that there is nothing in it worth
            testing. It formats nothing, counts nothing, and decides nothing:
            every string it puts on the screen was decided by
            Get-HDTConsoleTreeNode and every one of them is asserted in
            tests/unit/ConsoleTreeNode.Tests.ps1.

            IT IS THE SAME SHAPE AS New-HDTWizardHost, on purpose. The console
            runs on a desktop with pwsh 7 and the full framework available, so
            none of XamlReader's constraints apply to it - but a page written the
            way the wizard writes them can move into WinPE later without being
            rewritten, and that is the whole reason C1 keeps the pattern.

            XamlReader::Load PARSES MARKUP ONLY. The window carries no x:Class
            and no code-behind; handlers are attached here, by name, after the
            tree exists. The seven names the markup promises are asserted by
            tests/unit/ConsoleWindow.Tests.ps1 against the shipped file.

            THE DEFAULT ANSWER IS EMPTY, NOT 'Close'. A window shut with the X
            never runs the handler, so this returns what it was given - nothing -
            and Show-HDTConsole is what turns that into a Close. The adapter does
            not get to make that decision, because then two places would have an
            opinion about what a dismissed window means.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A PSCustomObject with a Show(xaml, title, node, theme) method
            returning 'Close' or an empty string.

        .EXAMPLE
            Show-HDTConsole -Path 'C:\HDTLab\Share' -ConsoleHost (New-HDTConsoleHost)

            The real WPF host. Show-HDTConsole builds one itself when none is given,
            so this is the long way round to the same window.

        .EXAMPLE
            $consoleHost = New-HDTConsoleHost
            @($consoleHost | Get-Member -MemberType ScriptMethod | ForEach-Object { $_.Name })

            Every window the console can open. The adapter decides nothing: each of
            these loads markup, sets text by name and shows it, and the decisions
            are in the helpers it calls.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Show is where a window appears, and it is a method.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Answer = ''

        # What the window was when it closed. Show-HDTConsole remembers it; this
        # only reports it, because "should that size be kept" is a decision and
        # decisions do not go in an adapter.
        Width  = 0
        Height = 0

        # THE BROWSER WINDOW, SO THE EDITOR CAN BE OWNED BY IT. It is $null until
        # Show opens one, and $null is a legal Owner - a window with no owner is
        # exactly what Show-HDTSequenceEditor run on its own has. Keeping it here
        # rather than passing it into ShowEditor means the two methods do not
        # have to agree on an argument that only ever has one possible value.
        Window = $null
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        # THE PALETTE ARRIVES TWICE, AS BRUSHES AND AS ITS NAME. The brushes
        # paint this window; the name is what Show-HDTSequenceEditor takes, so
        # an editor opened by a double-click comes up in the palette the console
        # is already wearing. The name cannot be recovered from the brushes, and
        # a key added to the hashtable would be fed to the BrushConverter below
        # along with the colours.
        param([string] $Xaml, [string] $Title, [object[]] $Node, [object] $Theme, [object] $Size,
            [int] $RefreshSecond = 10, [string] $NewSequenceXaml = '',
            [string] $ImportOperatingSystemXaml = '', [string] $ImportApplicationXaml = '',
            [string] $ApplicationDependencyXaml = '', [string] $ApplicationDetectionXaml = '',
            [object] $Fill = $null, [string] $NewWorkspaceXaml = '')

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

        $window.Title = $Title

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

        $this.Answer = ''

        # THE HOST, CAPTURED BY NAME. Inside an Add_Click handler $this is the
        # BUTTON that raised the event, not this object - and the enclosing
        # function's $service is not in scope inside a ScriptMethod at all, so a
        # handler written against it closes over a variable that does not exist
        # and throws under StrictMode. New-HDTWizardHost hit exactly this and
        # documented it in cb4200e; this adapter was written the same way and
        # carried the same bug, and it survived every screenshot because a window
        # dismissed with WM_CLOSE or the title-bar X never runs the handler at
        # all. It took an administrator pressing Close.
        $consoleHost = $this

        # The editor is opened from a handler on this window, and an owned dialog
        # is what keeps it above the window it was opened from instead of behind
        # it. The position no longer depends on this - both windows are placed
        # explicitly - but the z-order does, and a task sequence editor that
        # vanished behind the browser the moment somebody clicked the browser
        # would read as an editor that closed itself.
        $consoleHost.Window = $window

        $share = $window.FindName('HDTShareText')
        $deployRoot = $window.FindName('HDTDeployRootText')
        $root = $window.FindName('HDTRootText')
        $tree = $window.FindName('HDTConsoleTree')
        $detail = $window.FindName('HDTDetailList')
        $command = $window.FindName('HDTCommandText')
        $close = $window.FindName('HDTCloseButton')

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

                if ($null -eq $selected) { return }
                if (-not $selected.CanOpen) { return }

                # TWO KINDS OF ROW OPEN, AND THE ROW SAYS WHICH IT IS. A task
                # sequence opens the editor; the boot image opens the Windows PE
                # window, which is Deployment Workbench's deployment share
                # Properties. This routes on the Kind the node already carries -
                # it does not work out for itself which rows are which, because
                # that is the decision Get-HDTConsoleTreeNode already made.
                if ([string] $selected.Kind -eq 'BootImage') {
                    & $openBootImage ([string] $selected.Subject)
                    return
                }

                # AND ONLY A TASK SEQUENCE OPENS THE EDITOR. CanOpen says a row
                # carries a subject, which an operating system now does so the
                # detail pane can write its document - it is not an invitation
                # to open a sequence editor on an os.yaml. An OS's properties
                # ARE the detail pane; there is no second window to show.
                if ([string] $selected.Kind -ne 'TaskSequence') { return }

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
                [void] (Show-HDTSequenceEditor -Sequence $selected.Subject `
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

                $refresh.Start()
            }.GetNewClosure())

        # A timer left running holds a reference to a window that has gone.
        $window.Add_Closed({ $refresh.Stop() }.GetNewClosure())

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
            $rebuiltNode = @(& $call 'Get-HDTConsoleTreeNode' -Workspace ([object[]] @($rebuiltShare)))

            $tree.ItemsSource = @($rebuiltNode | Where-Object { $_.Depth -eq 0 })

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

            # ITS OWN DOOR, because this one is not a closure. $writeRow is a
            # plain scriptblock, so it does not carry the Show method's locals
            # the way the .GetNewClosure() handlers do, and a $call inherited by
            # luck from whichever scope invoked it is a null reference waiting
            # for the one caller that is not a closure. The console surface
            # contract asserts that every scope naming $call declares it.
            $call = Get-HDTHandlerCall

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
                    $edit = Get-HDTConsoleApplicationEdit -Property $key -Text $typed
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
        }

        $detail.AddHandler([System.Windows.Controls.TextBox]::LostFocusEvent,
            [System.Windows.RoutedEventHandler] {
                param([object] $raiser, [System.Windows.RoutedEventArgs] $lost)

                $box = $lost.OriginalSource -as [System.Windows.Controls.TextBox]
                if ($null -eq $box) { return }

                $row = $box.DataContext
                if ($null -eq $row) { return }

                # ASKED FOR, NOT ASSUMED. Not every row in this pane comes from
                # New-HDTConsoleField - a monitor row and a share that would not
                # open build their own - and under Set-StrictMode reading a
                # property that is not there is a terminating error on the
                # dispatcher, which takes the window down for a click on a box
                # that was never editable in the first place.
                if (@($row.PSObject.Properties.Match('Editable')).Count -eq 0) { return }
                if (-not [bool] $row.Editable) { return }

                $typed = [string] $box.Text
                if ($typed -eq [string] $row.Original) { return }

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
                if ($null -eq $row) { return }

                if (@($row.PSObject.Properties.Match('Editable')).Count -eq 0) { return }
                if (-not [bool] $row.Editable) { return }

                # NOTHING PICKED IS NOT A PICK. Rebuilding the pane raises this
                # with SelectedItem null before the binding has settled, and
                # writing that would clear the key on every click of the tree.
                if ($null -eq $combo.SelectedItem) { return }

                $picked = [string] $combo.SelectedItem
                if ($picked -eq [string] $row.Original) { return }

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
        $newFolder = $window.FindName('HDTNewFolderMenuItem')
        $moveToFolder = $window.FindName('HDTMoveToFolderMenuItem')
        $deleteFolder = $window.FindName('HDTDeleteFolderMenuItem')
        $folderSeparator = $window.FindName('HDTFolderMenuSeparator')

        if ($null -ne $newSequence) {
            if ([string]::IsNullOrWhiteSpace($NewSequenceXaml)) {
                $newSequence.Visibility = [System.Windows.Visibility]::Collapsed
            } else {
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

                        if ($isCategory) { $newSequence.Visibility = [System.Windows.Visibility]::Visible }
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

                        if ($folderAction.CanCreate) { $newFolder.Visibility = [System.Windows.Visibility]::Visible }
                        if ($folderAction.CanMove) { $moveToFolder.Visibility = [System.Windows.Visibility]::Visible }

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
                        if ($onFolderRow -and ($isRoot -or $isShare -or $isCategory -or $isSequence -or $isOsCategory -or $isOperatingSystem -or $isAppCategory -or $isApplication -or $isBootImage)) {
                            $folderSeparator.Visibility = [System.Windows.Visibility]::Visible
                        }

                        if (-not ($isRoot -or $isShare -or $isCategory -or $isSequence -or $isOsCategory -or $isOperatingSystem -or $isAppCategory -or $isApplication -or $isBootImage -or $onFolderRow)) {
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
                        if ([string]::IsNullOrWhiteSpace($where) -or [string]::IsNullOrWhiteSpace($which)) {
                            $command.Text = 'that row does not name a share and a task sequence id, so there is nothing to remove.'
                            return
                        }

                        $asked = [System.Windows.MessageBox]::Show($window,
                            ("Remove the task sequence '{0}' from{1}{2}?{1}{1}Its folder goes with it - the sequence, its answer file and anything else kept beside them. This cannot be undone from here." -f
                                $which, [System.Environment]::NewLine, $where),
                            'Remove Task Sequence',
                            [System.Windows.MessageBoxButton]::YesNo,
                            [System.Windows.MessageBoxImage]::Warning,
                            [System.Windows.MessageBoxResult]::No)

                        if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                        try {
                            [void] (Remove-HDTTaskSequence -Workspace $where -Id $which -Confirm:$false)
                            $command.Text = "Remove-HDTTaskSequence -Workspace '{0}' -Id '{1}'" -f $where, $which
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

                        if ([string]::IsNullOrWhiteSpace($where) -or [string]::IsNullOrWhiteSpace($which)) {
                            $command.Text = 'that row does not name a share and an operating system id, so there is nothing to remove.'
                            return
                        }

                        # ASKED FOR WITHOUT REMOVING ANYTHING: -WhatIf returns
                        # UsedBy, so the dialog can name the sequences before
                        # anybody agrees to anything.
                        $using = @()

                        try {
                            $using = @((Remove-HDTOperatingSystem -Workspace $where -Id $which -WhatIf).UsedBy)
                        } catch {
                            $command.Text = [string] $_.Exception.Message
                            return
                        }

                        $warning = ''
                        if (@($using).Count -gt 0) {
                            $warning = '{0}{0}These task sequences apply it and will fail without it: {1}.' -f
                                [System.Environment]::NewLine, (@($using) -join ', ')
                        }

                        $asked = [System.Windows.MessageBox]::Show($window,
                            ("Remove the operating system '{0}' from{1}{2}?{1}{1}Its folder goes with it - os.yaml and whatever media was imported beside it. This cannot be undone from here.{3}" -f
                                $which, [System.Environment]::NewLine, $where, $warning),
                            'Remove Operating System',
                            [System.Windows.MessageBoxButton]::YesNo,
                            [System.Windows.MessageBoxImage]::Warning,
                            [System.Windows.MessageBoxResult]::No)

                        if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                        try {
                            [void] (Remove-HDTOperatingSystem -Workspace $where -Id $which -Confirm:$false)
                            $command.Text = "Remove-HDTOperatingSystem -Workspace '{0}' -Id '{1}'" -f $where, $which
                        } catch {
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

                        if ([string]::IsNullOrWhiteSpace($where) -or [string]::IsNullOrWhiteSpace($which)) {
                            $command.Text = 'that row does not name a share and an application id, so there is nothing to remove.'
                            return
                        }

                        $answer = $null

                        try {
                            $answer = Remove-HDTApplication -WorkspaceRoot $where -Id $which -WhatIf
                        } catch {
                            $command.Text = [string] $_.Exception.Message
                            return
                        }

                        $warning = ''
                        if (@($answer.UsedBy).Count -gt 0) {
                            $warning = '{0}{0}These task sequences install it: {1}.' -f
                            [System.Environment]::NewLine, (@($answer.UsedBy) -join ', ')
                        }
                        if (@($answer.RequiredBy).Count -gt 0) {
                            $warning = '{0}{1}{1}These applications depend on it and will not install without it: {2}.' -f
                            $warning, [System.Environment]::NewLine, (@($answer.RequiredBy) -join ', ')
                        }

                        $asked = [System.Windows.MessageBox]::Show($window,
                            ("Remove the application '{0}' from{1}{2}?{1}{1}Its folder goes with it - app.yaml and the installer copied beside it. This cannot be undone from here.{3}" -f
                                $which, [System.Environment]::NewLine, $where, $warning),
                            'Remove Application',
                            [System.Windows.MessageBoxButton]::YesNo,
                            [System.Windows.MessageBoxImage]::Warning,
                            [System.Windows.MessageBoxResult]::No)

                        if ($asked -ne [System.Windows.MessageBoxResult]::Yes) { return }

                        try {
                            [void] (Remove-HDTApplication -WorkspaceRoot $where -Id $which -Confirm:$false)
                            $command.Text = "Remove-HDTApplication -WorkspaceRoot '{0}' -Id '{1}'" -f $where, $which
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
                    $ask.Icon = Get-HDTConsoleWindowIcon
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
                }

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
            }
        }

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

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # -- the task sequence editor ------------------------------------------
    #
    # A SECOND WINDOW, THE SAME ADAPTER. It loads markup, hangs menu items off a
    # button, calls one command per press and assigns what comes back. Every
    # decision - what the menu offers, what the tree looks like after a splice,
    # which buttons are live for the selected row, what the Options tab says -
    # was made in Get-HDTConsoleStepCatalog, Get-HDTConsoleEditorState and
    # Get-HDTConsoleStepOption, and is asserted in tests against no window at
    # all. That is what keeps this method honestly exempt from TDD (rule 1).
    #
    # EVERY BUTTON IS ONE CMDLET CALL, WHICH IS DESIGN 12'S RULE. The console
    # may not do anything the cmdlets can't; Add, Remove, Up, Down, Copy, Paste,
    # Save, the two checkboxes and the condition box each map to exactly one
    # invocation, and the box at the bottom of the window shows it.
    #
    # THE DOCUMENT LIVES IN $book AND NOWHERE ELSE. It is the edited lines, the
    # clipboard and whether anything is unsaved - the three facts a window has
    # that a command cannot be handed. After every edit the lines go back
    # through Get-HDTConsoleEditorState, so the tree on screen is what the
    # ENGINE reads and not a parallel model of it.
    # =====================================================================
    # MDT'S New Task Sequence WIZARD
    # =====================================================================
    #
    # The one thing the browser could not do: everything else in that window
    # opens what exists, and this creates one. It decides nothing -
    # Get-HDTConsoleNewSequence says what may be chosen,
    # Test-HDTConsoleNewSequence says whether the answers can be used, and
    # New-HDTTaskSequence writes the file.
    #
    # IT RETURNS THE PATH IT CREATED, or an empty string when it was cancelled,
    # so the caller can refresh the tree without asking what happened.
    # =====================================================================
    # MDT'S Import Operating System WIZARD
    # =====================================================================
    #
    # THE OTHER THING THE BROWSER COULD NOT DO. Everything else opens what
    # exists; this and New Task Sequence create one.
    #
    # IT DECIDES NOTHING. Test-HDTConsoleImportOperatingSystem says whether the
    # answers can be used, Import-HDTOperatingSystem does the work, and this
    # shows a window and reports what came back.
    #
    # THE MEDIA IS REGISTERED WHERE IT STANDS. -Copy moves several gigabytes and
    # would do it on the dispatcher, greying the console out for minutes - the
    # failure the boot image build's progress window exists to prevent. The
    # dialog says so rather than offering a tick box that freezes the window.
    #
    # IT RETURNS THE ID IT IMPORTED, or an empty string when it was cancelled,
    # so the caller can refresh the tree without asking what happened.
    $service | Add-Member -MemberType ScriptMethod -Name ShowImportOperatingSystem -Value {
        param([string] $Xaml, [string] $Workspace, [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        # The text comes out of Strings\<culture>.psd1, not out of the markup.
        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'ImportOperatingSystem'))

        $rootText = $dialog.FindName('HDTImportOsRootText')
        $sourceBox = $dialog.FindName('HDTImportOsSourceBox')
        $sourceBrowse = $dialog.FindName('HDTImportOsSourceBrowseButton')
        $idBox = $dialog.FindName('HDTImportOsIdBox')
        $nameBox = $dialog.FindName('HDTImportOsNameBox')
        $descriptionBox = $dialog.FindName('HDTImportOsDescriptionBox')
        $messageText = $dialog.FindName('HDTImportOsMessageText')
        $commandText = $dialog.FindName('HDTImportOsCommandText')
        $import = $dialog.FindName('HDTImportOsImportButton')

        $rootText.Text = $Workspace

        # WHETHER THE ANSWERS CAN BE USED, ON EVERY KEYSTROKE, and the id filled
        # in from the media the first time a source names one - typed over
        # afterwards and never put back, because the second suggestion would
        # overwrite what somebody had just decided.
        $filled = @{ Id = $false }

        $check = {
            $answer = & $call 'Test-HDTConsoleImportOperatingSystem' -Workspace $Workspace `
                -Id ([string] $idBox.Text) -SourcePath ([string] $sourceBox.Text)

            if (-not $filled.Id -and [string]::IsNullOrWhiteSpace([string] $idBox.Text) -and
                -not [string]::IsNullOrWhiteSpace([string] $answer.SuggestedId)) {

                $filled.Id = $true
                $idBox.Text = [string] $answer.SuggestedId
                return
            }

            $import.IsEnabled = [bool] $answer.CanImport
            $messageText.Text = [string] $answer.Message

            $commandText.Text = "Import-HDTOperatingSystem -WorkspaceRoot '{0}' -Id '{1}' -SourcePath '{2}'" -f
                $Workspace, [string] $idBox.Text, [string] $sourceBox.Text
        }.GetNewClosure()

        $sourceBox.Add_TextChanged({ & $check }.GetNewClosure())
        $idBox.Add_TextChanged({ & $check }.GetNewClosure())

        & $check

        # THE FILE, NOT THE FOLDER. The filter names what the import can read,
        # and the dialog opens on the media rather than on Documents.
        $sourceBrowse.Add_Click({
                $picker = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $picker.Title = 'Choose the image file to import'
                $picker.Filter = 'Windows images (*.wim;*.esd;*.ffu)|*.wim;*.esd;*.ffu|All files (*.*)|*.*'
                $picker.CheckFileExists = $true

                if ($picker.ShowDialog() -ne $true) { return }

                $sourceBox.Text = [string] $picker.FileName
            }.GetNewClosure())

        $this.ImportedOperatingSystemId = ''
        $dialogHost = $this

        $import.Add_Click({
                try {
                    # THE SERVICES ARE REAL ONES BUILT HERE. Import-HDTOperatingSystem
                    # takes them injected precisely so the engine never reaches
                    # for a clock or an image reader itself - the console is the
                    # edge, and the edge is where the real ones are made.
                    $splat = @{
                        WorkspaceRoot = $Workspace
                        Id            = [string] $idBox.Text
                        SourcePath    = [string] $sourceBox.Text
                        FileSystem    = New-HDTFileSystem
                        ImageService  = New-HDTImageService
                        Clock         = New-HDTClock
                        Confirm       = $false
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string] $nameBox.Text)) {
                        $splat['Name'] = [string] $nameBox.Text
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string] $descriptionBox.Text)) {
                        $splat['Description'] = [string] $descriptionBox.Text
                    }

                    # READING THE IMAGE LIST TAKES A MOMENT even without -Copy,
                    # so the cursor says so. Minutes would need the progress
                    # window; seconds need a wait cursor.
                    $dialog.Cursor = [System.Windows.Input.Cursors]::Wait

                    $made = Import-HDTOperatingSystem @splat

                    $dialogHost.ImportedOperatingSystemId = [string] $made.Id
                    $dialog.DialogResult = $true
                } catch {
                    # THE REFUSAL LANDS ON THE PAGE, not in a message box over a
                    # dialog that has already closed.
                    $messageText.Text = [string] $_.Exception.Message
                } finally {
                    $dialog.Cursor = $null
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return [string] $this.ImportedOperatingSystemId
    }

    $service | Add-Member -MemberType NoteProperty -Name ImportedOperatingSystemId -Value ''

    # MDT'S New Application WIZARD, as one dialog. The same adapter as the one
    # above it: load markup, fill text from the string table, ask
    # Test-HDTConsoleImportApplication on every keystroke, call one cmdlet on the
    # press. Every decision it makes was made in that command, against no window.
    $service | Add-Member -MemberType ScriptMethod -Name ShowImportApplication -Value {
        param([string] $Xaml, [string] $Workspace, [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'ImportApplication'))

        $rootText = $dialog.FindName('HDTImportAppRootText')
        $sourceBox = $dialog.FindName('HDTImportAppSourceBox')
        $sourceBrowse = $dialog.FindName('HDTImportAppSourceBrowseButton')
        $installBox = $dialog.FindName('HDTImportAppInstallBox')
        $idBox = $dialog.FindName('HDTImportAppIdBox')
        $publisherBox = $dialog.FindName('HDTImportAppPublisherBox')
        $nameBox = $dialog.FindName('HDTImportAppNameBox')
        $versionBox = $dialog.FindName('HDTImportAppVersionBox')
        $messageText = $dialog.FindName('HDTImportAppMessageText')
        $commandText = $dialog.FindName('HDTImportAppCommandText')
        $import = $dialog.FindName('HDTImportAppImportButton')

        $rootText.Text = $Workspace

        # THE ID IS COMPOSED UNTIL SOMEBODY TYPES ONE, and from then on it is
        # theirs. Workbench composes both names from publisher, name and version
        # (New-HDTApplicationName); an id is the folder name and what every task
        # sequence names, so a box that rewrote itself after a decision would
        # rename the entry behind somebody's back.
        #
        # $mine IS SET BY THE TYPING, NOT BY THE WRITING - assigning .Text
        # raises TextChanged too, so the flag is lowered around the assignment
        # and a real keystroke is the only thing that can raise it.
        $mine = @{ Id = $false; Writing = $false }

        $idBox.Add_TextChanged({
                if (-not $mine.Writing) { $mine.Id = $true }
            }.GetNewClosure())

        $check = {
            $composed = & $call 'New-HDTApplicationName' -Publisher ([string] $publisherBox.Text) `
                -Name ([string] $nameBox.Text) -Version ([string] $versionBox.Text)

            if (-not $mine.Id) {
                $wanted = [string] $composed.Id

                # THE SOURCE FOLDER IS THE FALLBACK, as it was before there were
                # three boxes to compose from: a package dropped in with nothing
                # typed still gets an id offered.
                if ([string]::IsNullOrWhiteSpace($wanted)) {
                    $fromSource = & $call 'Test-HDTConsoleImportApplication' -Workspace $Workspace `
                        -SourcePath ([string] $sourceBox.Text)

                    $wanted = [string] $fromSource.SuggestedId
                }

                if ([string] $idBox.Text -ne $wanted) {
                    $mine.Writing = $true
                    $idBox.Text = $wanted
                    $mine.Writing = $false
                }
            }

            $answer = & $call 'Test-HDTConsoleImportApplication' -Workspace $Workspace `
                -Id ([string] $idBox.Text) -SourcePath ([string] $sourceBox.Text) `
                -Install ([string] $installBox.Text)

            $import.IsEnabled = [bool] $answer.CanImport
            $messageText.Text = [string] $answer.Message

            $commandText.Text = "Import-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -SourcePath '{2}' -Install '{3}'" -f
            $Workspace, [string] $idBox.Text, [string] $sourceBox.Text, [string] $installBox.Text
        }.GetNewClosure()

        $sourceBox.Add_TextChanged({ & $check }.GetNewClosure())
        $idBox.Add_TextChanged({ & $check }.GetNewClosure())
        $installBox.Add_TextChanged({ & $check }.GetNewClosure())
        $publisherBox.Add_TextChanged({ & $check }.GetNewClosure())
        $nameBox.Add_TextChanged({ & $check }.GetNewClosure())
        $versionBox.Add_TextChanged({ & $check }.GetNewClosure())

        & $check

        # A FOLDER, NOT A FILE, which is what this import takes - and WPF's file
        # picker cannot choose one. OpenFileDialog with a placeholder name is
        # the trick every tool uses; the folder is what gets kept.
        $sourceBrowse.Add_Click({
                $picker = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $picker.Title = 'Open the folder holding the installer, and press Open'
                $picker.CheckFileExists = $false
                $picker.FileName = 'this folder'
                $picker.Filter = 'All files (*.*)|*.*'

                if ($picker.ShowDialog() -ne $true) { return }

                $sourceBox.Text = [string] [System.IO.Path]::GetDirectoryName($picker.FileName)
            }.GetNewClosure())

        $this.ImportedApplicationId = ''
        $dialogHost = $this

        $import.Add_Click({
                try {
                    $splat = @{
                        WorkspaceRoot = $Workspace
                        Id            = [string] $idBox.Text
                        SourcePath    = [string] $sourceBox.Text
                        Install       = [string] $installBox.Text
                        FileSystem    = New-HDTFileSystem
                        Confirm       = $false
                    }

                    # THE DISPLAY NAME IS COMPOSED THE WAY WORKBENCH COMPOSES
                    # IT - publisher, name, version - so the row reads '7-Zip
                    # 24.09' rather than '7-Zip' three times over.
                    $composed = & $call 'New-HDTApplicationName' -Publisher ([string] $publisherBox.Text) `
                        -Name ([string] $nameBox.Text) -Version ([string] $versionBox.Text)

                    if (-not [string]::IsNullOrWhiteSpace([string] $composed.Display)) {
                        $splat['Name'] = [string] $composed.Display
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string] $publisherBox.Text)) {
                        $splat['Publisher'] = [string] $publisherBox.Text
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string] $versionBox.Text)) {
                        $splat['Version'] = [string] $versionBox.Text
                    }

                    # COPYING THE PAYLOAD TAKES A MOMENT, and an installer folder
                    # is megabytes rather than the gigabytes an OS import moves -
                    # so a wait cursor, not the progress window.
                    $dialog.Cursor = [System.Windows.Input.Cursors]::Wait

                    $made = Import-HDTApplication @splat

                    $dialogHost.ImportedApplicationId = [string] $made.Id
                    $dialog.DialogResult = $true
                } catch {
                    # THE REFUSAL LANDS ON THE PAGE, not in a message box over a
                    # dialog that has already closed.
                    $messageText.Text = [string] $_.Exception.Message
                } finally {
                    $dialog.Cursor = $null
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return [string] $this.ImportedApplicationId
    }

    $service | Add-Member -MemberType NoteProperty -Name ImportedApplicationId -Value ''

    # WHAT AN APPLICATION HAS TO BE INSTALLED AFTER, ticked rather than typed.
    #
    # The list, the ticks and the entries that would close a loop are
    # Get-HDTConsoleDependencyChoice's decision; this binds them and calls one
    # cmdlet on Save. A tick box bound TwoWay is what carries the answer back -
    # the rows are the same objects the list was built from.
    $service | Add-Member -MemberType ScriptMethod -Name ShowApplicationDependency -Value {
        param([string] $Xaml, [string] $Workspace, [string] $Id, [object[]] $Choice,
            [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'ApplicationDependency'))

        $rootText = $dialog.FindName('HDTDependencyRootText')
        $list = $dialog.FindName('HDTDependencyList')
        $emptyText = $dialog.FindName('HDTDependencyEmptyText')
        $commandText = $dialog.FindName('HDTDependencyCommandText')
        $save = $dialog.FindName('HDTDependencySaveButton')

        $rootText.Text = '{0}  -  {1}' -f $Workspace, $Id

        # THE ROWS ARE BOUND, NOT COPIED, so a tick lands on the object this
        # method reads back. Selected has to be settable for that, and a row
        # from Get-HDTConsoleDependencyChoice is a PSCustomObject, which is.
        $row = New-Object -TypeName System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($current in @($Choice)) { $row.Add($current) }

        $list.ItemsSource = $row

        if (@($Choice).Count -eq 0) {
            $list.Visibility = [System.Windows.Visibility]::Collapsed
            $emptyText.Visibility = [System.Windows.Visibility]::Visible
            $save.IsEnabled = $false
        }

        $this.DependencyAnswer = $null
        $dialogHost = $this

        $save.Add_Click({
                $chosen = @(@($row) | Where-Object { [bool] $_.Selected } | ForEach-Object { [string] $_.Id })

                try {
                    # AN EMPTY TICK LIST IS A REAL ANSWER - "this depends on
                    # nothing any more" - and Set-HDTApplication -Dependency @()
                    # is how that is written.
                    [void] (Set-HDTApplication -WorkspaceRoot $Workspace -Id $Id `
                            -Dependency ([string[]] $chosen) -Confirm:$false)

                    $dialogHost.DependencyAnswer = [string[]] $chosen
                    $dialog.DialogResult = $true
                } catch {
                    $commandText.Text = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return $this.DependencyAnswer
    }

    $service | Add-Member -MemberType NoteProperty -Name DependencyAnswer -Value $null

    # HOW AN APPLICATION IS DETECTED, as a type and the boxes that type takes.
    #
    # THE BOXES ARE BUILT HERE BECAUSE THE TYPE DECIDES THEM.
    # Get-HDTConsoleDetectionForm says which keys, what is in them, what to call
    # them and whether they hold a rule that can be written; this makes a
    # TextBox per row and reads them back. Every decision is that command's; the
    # only thing settled here is which control shows what it said.
    $service | Add-Member -MemberType ScriptMethod -Name ShowApplicationDetection -Value {
        param([string] $Xaml, [string] $Workspace, [string] $Id, [object] $Detect,
            [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'ApplicationDetection'))

        $rootText = $dialog.FindName('HDTDetectionRootText')
        $typeBox = $dialog.FindName('HDTDetectionTypeBox')
        $panel = $dialog.FindName('HDTDetectionFieldPanel')
        $messageText = $dialog.FindName('HDTDetectionMessageText')
        $commandText = $dialog.FindName('HDTDetectionCommandText')
        $save = $dialog.FindName('HDTDetectionSaveButton')

        $rootText.Text = '{0}  -  {1}' -f $Workspace, $Id

        # WHAT IS IN THE BOXES RIGHT NOW, keyed by the document key, so a redraw
        # after a type change can be handed back what was typed rather than what
        # the document said.
        $typed = @{}
        $state = @{ Type = ''; Loading = $false }

        $form = Get-HDTConsoleDetectionForm -Detect $Detect

        $typeBox.ItemsSource = @($form.Choice)

        $draw = {
            param([object] $Form)

            $state.Type = [string] $Form.Type

            $panel.Children.Clear()
            $typed.Clear()

            foreach ($one in @($Form.Field)) {
                $row = New-Object -TypeName System.Windows.Controls.Grid

                foreach ($width in @(150, 0, 30)) {
                    $column = New-Object -TypeName System.Windows.Controls.ColumnDefinition

                    if ($width -eq 0) {
                        $column.Width = New-Object -TypeName System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
                    } else {
                        $column.Width = New-Object -TypeName System.Windows.GridLength -ArgumentList $width
                    }

                    [void] $row.ColumnDefinitions.Add($column)
                }

                $label = New-Object -TypeName System.Windows.Controls.TextBlock
                $label.Text = [string] $one.Label

                # WHICH ONE THE RULE CANNOT DO WITHOUT, said on the label rather
                # than only in the refusal - MDT marks them the same way.
                if (-not [bool] $one.Required) { $label.Text = '{0} (optional)' -f [string] $one.Label }

                $label.Style = $dialog.FindResource('HDTFieldLabel')
                [System.Windows.Controls.Grid]::SetColumn($label, 0)

                $box = New-Object -TypeName System.Windows.Controls.TextBox
                $box.Text = [string] $one.Value
                $box.FontFamily = New-Object -TypeName System.Windows.Media.FontFamily -ArgumentList 'Consolas, Courier New'
                [System.Windows.Controls.Grid]::SetColumn($box, 1)

                $typed[[string] $one.Key] = $box

                $dot = New-Object -TypeName System.Windows.Controls.Border
                $dot.Style = $dialog.FindResource('HDTHelpDot')
                $dot.ToolTip = [string] $one.Hint
                [System.Windows.Controls.Grid]::SetColumn($dot, 2)

                $glyph = New-Object -TypeName System.Windows.Controls.TextBlock
                $glyph.Text = '?'
                $glyph.FontWeight = [System.Windows.FontWeights]::Bold
                $glyph.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $glyph.Foreground = $dialog.FindResource('HDTHintTextBrush')
                $dot.Child = $glyph

                [void] $row.Children.Add($label)
                [void] $row.Children.Add($box)
                [void] $row.Children.Add($dot)

                [void] $panel.Children.Add($row)
            }
        }.GetNewClosure()

        # WHAT THE BOXES HOLD, ASKED AGAIN. The form is rebuilt from what is
        # typed rather than from what the document said, so Save writes what is
        # on screen.
        $current = {
            $rule = [System.Collections.Specialized.OrderedDictionary]::new()
            $rule['type'] = [string] $state.Type

            foreach ($key in @($typed.Keys)) { $rule[[string] $key] = [string] $typed[$key].Text }

            return & $call 'Get-HDTConsoleDetectionForm' -Type ([string] $state.Type) -Detect $rule
        }.GetNewClosure()

        $judge = {
            $now = & $current

            $save.IsEnabled = [bool] $now.Complete
            $messageText.Text = [string] $now.Message

            $commandText.Text = "Set-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -Detect {2}" -f
            $Workspace, $Id, [string] $now.CommandText
        }.GetNewClosure()

        $typeBox.Add_SelectionChanged({
                if ($state.Loading) { return }

                $chosen = ''
                if ($null -ne $typeBox.SelectedValue) { $chosen = [string] $typeBox.SelectedValue }

                # THE TYPE CHANGED, SO THE BOXES DO. Values do not survive it: a
                # product code is not a registry key.
                & $draw (& $call 'Get-HDTConsoleDetectionForm' -Type $chosen -Detect $Detect)
                & $judge
            }.GetNewClosure())

        $state.Loading = $true
        $typeBox.SelectedValue = [string] $form.Type
        $state.Loading = $false

        & $draw $form
        & $judge

        $this.DetectionAnswer = $null
        $dialogHost = $this

        $save.Add_Click({
                $now = & $current
                if (-not $now.Complete) { return }

                try {
                    $splat = @{
                        WorkspaceRoot = $Workspace
                        Id            = $Id
                        Confirm       = $false
                    }

                    # NO RULE IS WRITTEN AS AN EMPTY ONE, which is what clears
                    # the key - Set-HDTApplication reads an empty -Detect as
                    # "remove it", and DESIGN 8 reads a removed one as "install
                    # every time".
                    $splat['Detect'] = [System.Collections.Specialized.OrderedDictionary]::new()
                    if ($null -ne $now.Rule) { $splat['Detect'] = $now.Rule }

                    [void] (Set-HDTApplication @splat)

                    $dialogHost.DetectionAnswer = $now.Rule
                    $dialog.DialogResult = $true
                } catch {
                    $messageText.Text = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return $this.DetectionAnswer
    }

    $service | Add-Member -MemberType NoteProperty -Name DetectionAnswer -Value $null

    # WHICH SHARES THE WINDOW ENDED UP WITH. Show-HDTConsole reads it after the
    # window closes and remembers them, the way it already remembers the size.
    $service | Add-Member -MemberType NoteProperty -Name OpenShare -Value ([string[]] @())

    # MDT'S New Deployment Share WIZARD, as one dialog. The same adapter as the
    # others: load markup, fill text from the string table, ask
    # Test-HDTConsoleNewWorkspace on every keystroke, call one cmdlet on Create.
    $service | Add-Member -MemberType ScriptMethod -Name ShowNewWorkspace -Value {
        param([string] $Xaml, [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'NewWorkspace'))

        $pathBox = $dialog.FindName('HDTNewWorkspacePathBox')
        $pathBrowse = $dialog.FindName('HDTNewWorkspacePathBrowseButton')
        $idBox = $dialog.FindName('HDTNewWorkspaceIdBox')
        $nameBox = $dialog.FindName('HDTNewWorkspaceNameBox')
        $shareNameBox = $dialog.FindName('HDTNewWorkspaceShareNameBox')
        $deployRootBox = $dialog.FindName('HDTNewWorkspaceDeployRootBox')
        $messageText = $dialog.FindName('HDTNewWorkspaceMessageText')
        $commandText = $dialog.FindName('HDTNewWorkspaceCommandText')
        $create = $dialog.FindName('HDTNewWorkspaceCreateButton')

        # THE ID IS FILLED IN FROM THE FOLDER UNTIL SOMEBODY TYPES ONE, and from
        # then on it is theirs: the id is carried into every boot image built
        # here, so a box that rewrote itself after a decision would be a box
        # that renamed the share behind them.
        $mine = @{ Id = $false; Writing = $false }

        $idBox.Add_TextChanged({
                if (-not $mine.Writing) { $mine.Id = $true }
            }.GetNewClosure())

        # PUBLISHING NEEDS ELEVATION, AND THE PAGE SAYS SO BEFORE ANYTHING IS
        # TYPED. Without it New-SmbShare fails inside the SmbShare module with
        # an access error naming a CIM class - after the folder has been
        # written, so the share is the only half missing and nothing says which
        # half. Here the technician learns it while the page is still empty.
        $elevated = Test-HDTElevation

        # THE SHARE NAME IS SUGGESTED FROM THE FOLDER, like the id, and stops
        # being suggested the moment somebody types one. The deploy root
        # follows the same rule and for a stronger reason: this machine's name
        # is only USUALLY how clients reach the share - a file server behind a
        # DFS namespace, a CNAME or a host with two NICs is reached by something
        # this dialog cannot work out.
        $mineShare = @{ Typed = $false; Writing = $false }
        $mineRoot = @{ Typed = $false; Writing = $false }

        $shareNameBox.Add_TextChanged({
                if (-not $mineShare.Writing) { $mineShare.Typed = $true }
            }.GetNewClosure())

        $deployRootBox.Add_TextChanged({
                if (-not $mineRoot.Writing) { $mineRoot.Typed = $true }
            }.GetNewClosure())

        $check = {
            $answer = & $call 'Test-HDTConsoleNewWorkspace' -Path ([string] $pathBox.Text) -Id ([string] $idBox.Text)

            if (-not $mine.Id -and -not [string]::IsNullOrWhiteSpace([string] $answer.SuggestedId) -and
                [string] $idBox.Text -ne [string] $answer.SuggestedId) {

                $mine.Writing = $true
                $idBox.Text = [string] $answer.SuggestedId
                $mine.Writing = $false

                $answer = & $call 'Test-HDTConsoleNewWorkspace' -Path ([string] $pathBox.Text) -Id ([string] $idBox.Text)
            }

            # THE SHARE NAME AND THE DEPLOY ROOT IT PRODUCES. Empty share name
            # means nothing is published and the deploy root stays empty, which
            # the document allows.
            $share = Get-HDTWorkspaceShareName -Path ([string] $pathBox.Text) `
                -ShareName ([string] $shareNameBox.Text)

            if (-not $mineShare.Typed -and [string] $shareNameBox.Text -ne [string] $share.ShareName -and
                -not [string]::IsNullOrWhiteSpace([string] $share.ShareName)) {

                $mineShare.Writing = $true
                $shareNameBox.Text = [string] $share.ShareName
                $mineShare.Writing = $false
            }

            if (-not $mineRoot.Typed -and [string] $deployRootBox.Text -ne [string] $share.DeployRoot) {
                $mineRoot.Writing = $true
                $deployRootBox.Text = [string] $share.DeployRoot
                $mineRoot.Writing = $false
            }

            $publishing = (-not [string]::IsNullOrWhiteSpace([string] $shareNameBox.Text))

            $create.IsEnabled = [bool] $answer.CanCreate
            $messageText.Text = [string] $answer.Message

            # THE ELEVATION SENTENCE OUTRANKS THE OTHERS, because it is the one
            # nothing on this page can fix - and it does not disable Create: the
            # folder is still worth writing, and the share can be added later.
            if ($publishing -and -not $elevated) {
                $messageText.Text = 'this console is not running as an administrator, so it cannot publish the share. Create the deployment share here and add the share yourself, or close this and reopen the console as an administrator - right-click, Run as administrator.'
            } elseif ($publishing -and -not [string]::IsNullOrWhiteSpace([string] $share.Message) -and
                [string]::IsNullOrWhiteSpace([string] $answer.Message)) {

                $messageText.Text = [string] $share.Message
                $create.IsEnabled = $false
            }

            $commandText.Text = "New-HDTWorkspace -Path '{0}' -Id '{1}' -DeployRoot '{2}'" -f
            [string] $pathBox.Text, [string] $idBox.Text, [string] $deployRootBox.Text

            if ($publishing) {
                $commandText.Text = "{0}{1}New-HDTWorkspaceShare -Path '{2}' -ShareName '{3}'" -f
                $commandText.Text, [System.Environment]::NewLine,
                [string] $pathBox.Text, [string] $shareNameBox.Text
            }
        }.GetNewClosure()

        $pathBox.Add_TextChanged({ & $check }.GetNewClosure())
        $idBox.Add_TextChanged({ & $check }.GetNewClosure())
        $shareNameBox.Add_TextChanged({ & $check }.GetNewClosure())

        & $check

        # A FOLDER, AND IT DOES NOT HAVE TO EXIST. OpenFileDialog with a
        # placeholder name is the only folder picker WPF has; CheckPathExists is
        # off because creating the folder is what this dialog is for.
        $pathBrowse.Add_Click({
                $picker = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $picker.Title = 'Open the folder the share should live in, and press Open'
                $picker.CheckFileExists = $false
                $picker.CheckPathExists = $false
                $picker.FileName = 'this folder'
                $picker.Filter = 'All files (*.*)|*.*'

                if ($picker.ShowDialog() -ne $true) { return }

                $pathBox.Text = [string] [System.IO.Path]::GetDirectoryName($picker.FileName)
            }.GetNewClosure())

        $this.CreatedWorkspacePath = ''
        $dialogHost = $this

        $create.Add_Click({
                try {
                    $splat = @{
                        Path    = [string] $pathBox.Text
                        Id      = [string] $idBox.Text
                        Confirm = $false
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string] $nameBox.Text)) {
                        $splat['Name'] = [string] $nameBox.Text
                    }

                    # THE BOX IS WHAT GETS WRITTEN, derived or typed. One place
                    # decides the value, so a deploy root somebody corrected is
                    # not quietly replaced by the one the share name implies.
                    if (-not [string]::IsNullOrWhiteSpace([string] $deployRootBox.Text)) {
                        $splat['DeployRoot'] = [string] $deployRootBox.Text
                    }

                    $dialog.Cursor = [System.Windows.Input.Cursors]::Wait

                    # THE FOLDER FIRST, THEN THE SHARE - two commands, because
                    # writing YAML and publishing over SMB are different kinds
                    # of act and the second needs rights the first does not.
                    [void] (New-HDTWorkspace @splat)

                    if (-not [string]::IsNullOrWhiteSpace([string] $shareNameBox.Text) -and $elevated) {
                        [void] (New-HDTWorkspaceShare -Path ([string] $pathBox.Text) `
                                -ShareName ([string] $shareNameBox.Text) -Confirm:$false)
                    }

                    $dialogHost.CreatedWorkspacePath = [string] $pathBox.Text
                    $dialog.DialogResult = $true
                } catch {
                    $messageText.Text = [string] $_.Exception.Message
                } finally {
                    $dialog.Cursor = $null
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return [string] $this.CreatedWorkspacePath
    }

    $service | Add-Member -MemberType NoteProperty -Name CreatedWorkspacePath -Value ''

    $service | Add-Member -MemberType ScriptMethod -Name ShowNewSequence -Value {
        param([string] $Xaml, [string] $Workspace, [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        # The text comes out of Strings\<culture>.psd1, not out of the markup.
        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'NewSequence'))

        $rootText = $dialog.FindName('HDTNewSequenceRootText')
        $idBox = $dialog.FindName('HDTNewSequenceIdBox')
        $nameBox = $dialog.FindName('HDTNewSequenceNameBox')
        $templateBox = $dialog.FindName('HDTNewSequenceTemplateBox')
        $imageBox = $dialog.FindName('HDTNewSequenceImageBox')
        $fullNameBox = $dialog.FindName('HDTNewSequenceFullNameBox')
        $orgBox = $dialog.FindName('HDTNewSequenceOrgBox')
        $passwordBox = $dialog.FindName('HDTNewSequencePasswordBox')
        $passwordHint = $dialog.FindName('HDTNewSequencePasswordHint')
        $messageText = $dialog.FindName('HDTNewSequenceMessageText')
        $commandText = $dialog.FindName('HDTNewSequenceCommandText')
        $create = $dialog.FindName('HDTNewSequenceCreateButton')

        $offer = Get-HDTConsoleNewSequence -Workspace $Workspace

        $rootText.Text = $Workspace

        $templateBox.ItemsSource = $offer.Template
        if (@($offer.Template).Count -gt 0) { $templateBox.SelectedIndex = 0 }

        # AN EMPTY ROW FIRST, because "decide later" is a real answer: the
        # sequence carries the image as a variable either way, and a share with
        # nothing imported yet still needs a sequence to put steps in.
        $imageChoice = New-Object -TypeName System.Collections.ArrayList
        [void] $imageChoice.Add([pscustomobject] @{ Id = ''; Display = '(decide later)' })
        foreach ($one in @($offer.Image)) { [void] $imageChoice.Add($one) }

        $imageBox.ItemsSource = $imageChoice

        # THE FIRST REAL IMAGE, NOT THE EMPTY ROW. MDT's wizard requires an
        # operating system; a page that defaults to "decide later" makes the
        # commonest answer the one nobody chose, and produces a sequence whose
        # image is unset on a share that has one.
        $imageBox.SelectedIndex = 0
        if (@($offer.Image).Count -gt 0) { $imageBox.SelectedIndex = 1 }

        # THE PASSWORD WARNING COMES FROM THE COMMAND, not from this markup, so
        # the page and the variable map cannot say different things about the
        # same value.
        $passwordHint.Text = [string] @($offer.Setting |
                Where-Object { $_.Key -eq 'HDTAdminPassword' })[0].Hint

        # WHETHER THE ANSWERS CAN BE USED, ON EVERY KEYSTROKE. The alternative
        # is a wizard that takes seven answers and refuses on the last press.
        $check = {
            $answer = & $call 'Test-HDTConsoleNewSequence' -Workspace $Workspace `
                -Id ([string] $idBox.Text) -Name ([string] $nameBox.Text)

            $create.IsEnabled = [bool] $answer.CanCreate
            $messageText.Text = [string] $answer.Message

            $commandText.Text = ($offer.CommandFormat -f
                [string] $idBox.Text, [string] $nameBox.Text, [string] $templateBox.SelectedValue)
        }.GetNewClosure()

        $idBox.Add_TextChanged({ & $check }.GetNewClosure())
        $nameBox.Add_TextChanged({ & $check }.GetNewClosure())
        $templateBox.Add_SelectionChanged({ & $check }.GetNewClosure())

        & $check

        $this.NewSequencePath = ''
        $dialogHost = $this

        $create.Add_Click({
                # WHAT WAS TYPED, AND ONLY WHAT WAS TYPED. An empty box writes no
                # variable rather than an empty one: a sequence carrying
                # HDTOrgName: '' looks like a decision somebody made.
                $variable = [ordered] @{}

                if (-not [string]::IsNullOrWhiteSpace([string] $imageBox.SelectedValue)) {
                    $variable['HDTOSImage'] = [string] $imageBox.SelectedValue
                }

                foreach ($pair in @(
                        @{ Key = 'HDTFullName'; Value = [string] $fullNameBox.Text }
                        @{ Key = 'HDTOrgName'; Value = [string] $orgBox.Text }
                        @{ Key = 'HDTAdminPassword'; Value = [string] $passwordBox.Text }
                    )) {

                    if ([string]::IsNullOrWhiteSpace([string] $pair.Value)) { continue }
                    $variable[[string] $pair.Key] = [string] $pair.Value
                }

                try {
                    $made = New-HDTTaskSequence -Workspace $Workspace `
                        -Id ([string] $idBox.Text) -Name ([string] $nameBox.Text) `
                        -Template ([string] $templateBox.SelectedValue) `
                        -Variable $variable -Confirm:$false

                    $dialogHost.NewSequencePath = [string] $made.Path
                    $dialog.DialogResult = $true
                } catch {
                    # THE REFUSAL LANDS ON THE PAGE, not in a message box over a
                    # dialog that has already closed.
                    $messageText.Text = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return [string] $this.NewSequencePath
    }

    $service | Add-Member -MemberType NoteProperty -Name NewSequencePath -Value ''

    # =====================================================================
    # MDT'S Partition Properties DIALOG
    # =====================================================================
    #
    # A modal over the editor, and the only place a volume's eight fields are
    # edited. It decides nothing: the unit list and what each unit composes come
    # from Get-HDTConsolePartitionRow, and what comes back is a hashtable ready
    # to splat at the command the caller chose.
    #
    # OK RUNS NOTHING. The dialog hands values back and closes; the command runs
    # in the editor, where its refusal has a strip to be printed on. A dialog
    # that ran the command itself would have to decide what to do with the
    # failure, and that is a decision in an adapter.
    $service | Add-Member -MemberType ScriptMethod -Name ShowPartitionProperties -Value {
        param(
            [string] $Xaml, [object] $Row, [object[]] $Unit, [object] $Theme, [object] $Owner
        )

        Add-Type -AssemblyName PresentationFramework

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $dialog.Icon = Get-HDTConsoleWindowIcon

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        # The text comes out of Strings\<culture>.psd1, not out of the markup.
        [void] (Set-HDTWindowText -Root $dialog -String (Get-HDTStringTable -Page 'PartitionProperties'))

        $nameBox = $dialog.FindName('HDTVolumeNameBox')
        $typeBox = $dialog.FindName('HDTVolumeTypeBox')
        $sizeBox = $dialog.FindName('HDTVolumeSizeBox')
        $unitBox = $dialog.FindName('HDTVolumeUnitBox')
        $fileSystemBox = $dialog.FindName('HDTVolumeFileSystemBox')
        $variableBox = $dialog.FindName('HDTVolumeVariableBox')
        $quickCheck = $dialog.FindName('HDTVolumeQuickFormatCheck')
        $bootCheck = $dialog.FindName('HDTVolumeBootableCheck')
        $messageText = $dialog.FindName('HDTVolumeMessageText')
        $ok = $dialog.FindName('HDTVolumeOkButton')

        $unitBox.ItemsSource = $Unit
        $unitBox.SelectedIndex = 0

        # THE NUMBER GOES FLAT FOR A UNIT THAT TAKES NONE. "the rest of the
        # disk" is not a quantity, and a live box beside it invites a number
        # that is then dropped without a word.
        $followUnit = {
            $picked = $unitBox.SelectedItem
            if ($null -eq $picked) { return }

            $sizeBox.IsEnabled = [bool] $picked.NeedsAmount
        }.GetNewClosure()

        $unitBox.Add_SelectionChanged({ & $followUnit }.GetNewClosure())

        # NEW STARTS BLANK; EDIT STARTS FULL. Edit writes the whole row back, so
        # everything it will write has to be on screen before anything is
        # changed - which is exactly what filling from the row does.
        $quickCheck.IsChecked = $true

        if ($null -ne $Row) {
            $dialog.Title = 'Partition Properties - {0}' -f $Row.Name

            $nameBox.Text = [string] $Row.Name
            $sizeBox.Text = [string] $Row.Amount
            $variableBox.Text = [string] $Row.Variable
            $quickCheck.IsChecked = [bool] $Row.QuickFormat
            $bootCheck.IsChecked = [bool] $Row.Bootable

            foreach ($entry in @($unitBox.ItemsSource)) {
                if ([string] $entry.Display -eq [string] $Row.Unit) { $unitBox.SelectedItem = $entry }
            }

            foreach ($entry in @($typeBox.Items)) {
                if ([string] $entry.Content -eq [string] $Row.Type) { $typeBox.SelectedItem = $entry }
            }

            $fileSystemBox.SelectedIndex = 0
            foreach ($entry in @($fileSystemBox.Items)) {
                if ([string] $entry.Content -eq [string] $Row.FileSystem) { $fileSystemBox.SelectedItem = $entry }
            }
        }

        & $followUnit

        $this.PartitionAnswer = $null

        # CAPTURED BEFORE THE HANDLER IS BUILT, not after: GetNewClosure takes
        # the value the variable has at that moment, and inside Add_Click $this
        # is the button rather than the host.
        $dialogHost = $this

        $ok.Add_Click({
                $written = [string] $nameBox.Text

                if ([string]::IsNullOrWhiteSpace($written)) {
                    $messageText.Text = 'A volume needs a name - it is how every command refers to this row.'
                    return
                }

                $picked = $unitBox.SelectedItem

                $answer = @{
                    Partition = $written
                    Type      = [string] $typeBox.SelectedItem.Content
                    Size      = ([string] $picked.Format -f [string] $sizeBox.Text)

                    # NAMED EITHER WAY. The engine defaults to quick and to the
                    # first row being bootable, and a dialog with both boxes on
                    # screen has been asked both questions - so it answers them
                    # rather than leaving the file to imply one.
                    QuickFormat = ($quickCheck.IsChecked -eq $true)
                    Bootable    = ($bootCheck.IsChecked -eq $true)
                }

                $chosenFileSystem = [string] $fileSystemBox.SelectedItem.Content
                if ($chosenFileSystem -ne '(default)') { $answer['FileSystem'] = $chosenFileSystem }

                if (-not [string]::IsNullOrWhiteSpace($variableBox.Text)) {
                    $answer['Variable'] = [string] $variableBox.Text
                }

                $dialogHost.PartitionAnswer = $answer
                $dialog.DialogResult = $true
            }.GetNewClosure())

        [void] $dialog.ShowDialog()

        return $this.PartitionAnswer
    }

    $service | Add-Member -MemberType NoteProperty -Name PartitionAnswer -Value $null

    $service | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
        param(
            [string] $Xaml, [string] $Title, [string] $Path,
            [object[]] $Node, [string[]] $Line, [object[]] $Catalog, [object] $Theme,
            [object] $Size, [string] $PartitionXaml, [object] $Editor
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Icon = Get-HDTConsoleWindowIcon

        # The text comes out of Strings\<culture>.psd1, not out of the markup,
        # and before the document's own name and path are written over the
        # banner's placeholders.
        [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'SequenceEditor'))

        $window.Title = $Title

        # The size of the console this was opened from, over the markup's own
        # numbers, and the same corner the console opens in.
        # Resolve-HDTConsoleEditorSize decided all four; this applies them. Left
        # and Top mean nothing without WindowStartupLocation="Manual".
        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height
        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top

        # THE OWNER IS WHAT KEEPS THIS WINDOW ABOVE THE BROWSER. $null when the
        # editor was opened on its own rather than from the browser, which is a
        # legal Owner and the reason no test is needed to choose between them.
        $window.Owner = $this.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $this.Answer = ''

        # THE SHARE'S ROOT, DERIVED FROM THE DOCUMENT'S OWN PATH. The engine
        # mandates <root>\TaskSequences\<id>\sequence.yaml, so three levels up
        # is the root - and the catalog page needs it to list the images this
        # share holds.
        #
        # A PATH THAT IS NOT THAT SHAPE STILL OPENS THE EDITOR. The catalog is
        # then empty and the box shows what the document says, which is what a
        # sequence opened from anywhere else should look like.
        $workspaceRoot = [System.IO.Path]::GetDirectoryName(
            [System.IO.Path]::GetDirectoryName(
                [System.IO.Path]::GetDirectoryName($Path)))

        if ([string]::IsNullOrWhiteSpace($workspaceRoot)) { $workspaceRoot = [System.IO.Path]::GetDirectoryName($Path) }

        # See the Show method above for why the host is captured by name: inside
        # an Add_Click handler $this is the button that raised the event.
        $editorHost = $this

        $titleText = $window.FindName('HDTEditorTitleText')
        $pathText = $window.FindName('HDTEditorPathText')
        $tree = $window.FindName('HDTStepTree')
        $detail = $window.FindName('HDTStepDetail')
        $command = $window.FindName('HDTEditorCommandText')
        $close = $window.FindName('HDTEditorCloseButton')

        $add = $window.FindName('HDTAddButton')
        $remove = $window.FindName('HDTRemoveButton')
        $up = $window.FindName('HDTUpButton')
        $down = $window.FindName('HDTDownButton')
        $copy = $window.FindName('HDTCopyButton')
        $paste = $window.FindName('HDTPasteButton')
        $save = $window.FindName('HDTSaveButton')


        $disableCheck = $window.FindName('HDTDisableCheck')
        $continueCheck = $window.FindName('HDTContinueCheck')
        $conditionText = $window.FindName('HDTConditionText')
        $conditionVariable = $window.FindName('HDTConditionVariableBox')
        $conditionOperator = $window.FindName('HDTConditionOperatorBox')
        $conditionValue = $window.FindName('HDTConditionValueBox')
        $conditionBuild = $window.FindName('HDTConditionBuildButton')
        $conditionClear = $window.FindName('HDTConditionClearButton')

        $variableButton = $window.FindName('HDTVariableButton')
        $variableTab = $window.FindName('HDTVariableTab')
        $variableGrid = $window.FindName('HDTVariableGrid')
        $variableNameBox = $window.FindName('HDTVariableNameBox')
        $variableValueBox = $window.FindName('HDTVariableValueBox')
        $variableSet = $window.FindName('HDTVariableSetButton')
        $variableRemove = $window.FindName('HDTVariableRemoveButton')

        $diskTab = $window.FindName('HDTDiskTab')
        $partitionStyleText = $window.FindName('HDTPartitionStyleText')
        $partitionList = $window.FindName('HDTPartitionList')
        $tabBook = $window.FindName('HDTOptionTab')
        $propertyTab = $window.FindName('HDTPropertyTab')
        $imageTab = $window.FindName('HDTImageTab')
        $imageBox = $window.FindName('HDTImageBox')
        $imageIndexBox = $window.FindName('HDTImageIndexBox')
        $imageTargetBox = $window.FindName('HDTImageTargetBox')
        $imageTimeoutBox = $window.FindName('HDTImageTimeoutBox')
        $validateTab = $window.FindName('HDTValidateTab')
        $validateList = $window.FindName('HDTValidateList')
        $applicationTab = $window.FindName('HDTApplicationTab')
        $applicationList = $window.FindName('HDTApplicationList')
        $applicationVariableRadio = $window.FindName('HDTApplicationVariableRadio')
        $applicationVariableBox = $window.FindName('HDTApplicationVariableBox')
        $applicationFixedRadio = $window.FindName('HDTApplicationFixedRadio')
        $applicationEmptyText = $window.FindName('HDTApplicationEmptyText')
        $applicationNoteText = $window.FindName('HDTApplicationNoteText')
        $commandTab = $window.FindName('HDTCommandTab')
        $commandLineLabel = $window.FindName('HDTCommandLineLabel')
        $commandLineBox = $window.FindName('HDTCommandLineBox')
        $commandFileLabel = $window.FindName('HDTCommandFileLabel')
        $commandFileBox = $window.FindName('HDTCommandFileBox')
        $commandArgumentsLabel = $window.FindName('HDTCommandArgumentsLabel')
        $commandArgumentsBox = $window.FindName('HDTCommandArgumentsBox')
        $commandStartInBox = $window.FindName('HDTCommandStartInBox')
        $commandSuccessBox = $window.FindName('HDTCommandSuccessBox')
        $commandRebootBox = $window.FindName('HDTCommandRebootBox')
        $commandNoteText = $window.FindName('HDTCommandNoteText')
        $stepNameBox = $window.FindName('HDTStepNameBox')
        $diskNumberBox = $window.FindName('HDTDiskNumberBox')
        $diskStyleBox = $window.FindName('HDTDiskStyleBox')
        $diskWipeCheck = $window.FindName('HDTDiskWipeCheck')
        $partitionUp = $window.FindName('HDTPartitionUpButton')
        $partitionDown = $window.FindName('HDTPartitionDownButton')
        $partitionAdd = $window.FindName('HDTPartitionAddButton')
        $partitionEdit = $window.FindName('HDTPartitionEditButton')
        $partitionRemove = $window.FindName('HDTPartitionRemoveButton')

        # THE CONDITION PICKER. Filled once - the variables the engine knows and
        # the four operators it implements do not change while a window is open -
        # and composed by Get-HDTConsoleConditionOption's own format string, so
        # the window joins nothing itself.
        #
        # BUILD WRITES INTO THE BOX; IT DOES NOT SAVE. Apply is still the only
        # thing that writes, which keeps one way to save rather than two that
        # can disagree - and leaves the composed text somewhere an author can
        # read and edit before committing to it.
        $conditionOption = Get-HDTConsoleConditionOption

        $conditionVariable.ItemsSource = $conditionOption.Variable
        $conditionOperator.ItemsSource = $conditionOption.Operator
        $conditionOperator.SelectedIndex = 0

        # THE VALUE LIST FOLLOWS THE VARIABLE. A boolean fact offers True and
        # False; a computer name offers nothing and stays a free box, which is
        # what an empty Suggested means.
        $conditionVariable.Add_SelectionChanged({
                $chosen = $conditionVariable.SelectedItem
                if ($null -eq $chosen) { return }

                $conditionValue.ItemsSource = $chosen.Suggested
            }.GetNewClosure())

        $conditionBuild.Add_Click({
                $token = [string] $conditionVariable.SelectedValue
                $operator = [string] $conditionOperator.SelectedValue

                if ([string]::IsNullOrWhiteSpace($token)) { return }
                if ([string]::IsNullOrWhiteSpace($operator)) { return }

                # Parenthesised on principle: a -f split across lines binds only
                # its first argument INSIDE a method call's argument list, and
                # that cost this session a window that died at its first report.
                # An assignment is not that case, but the habit is cheaper than
                # remembering which case is which.
                $conditionText.Text = ($conditionOption.Format -f
                    $token, $operator, [string] $conditionValue.Text)
            }.GetNewClosure())
        $runInText = $window.FindName('HDTRunInText')

        $titleText.Text = $Title
        $pathText.Text = $Path

        # The document, and the two things about it only the window knows.
        #
        # Quiet is the one flag here that is not about the document: filling the
        # Options tab sets IsChecked, which raises Checked, which would run the
        # handler that writes the file and refill the tab - a loop that ends in
        # a stack overflow rather than in anything an administrator could read.
        # The handlers return early while the tab is being filled.
        $book = [pscustomobject] @{
            Line      = [string[]] @($Line)
            Clipboard = $null
            Dirty     = $false
            Selected  = ''

            # WHICH OF THE SAME-NAMED ROWS IS SELECTED, 1-BASED. The tree is
            # rebuilt after every splice, so the selection is described rather
            # than held - and a name alone stopped describing it the moment a
            # sequence held two steps called 'Tattoo'.
            SelectedOccurrence = 0


            Partition = ''

            # WHAT THE EXIT CODE BOXES WERE FILLED WITH, so Apply can tell an
            # untouched box from a deliberate retype. The engine defaults
            # successCodes to 0 and rebootCodes to 3010, and the page SHOWS
            # those - writing them back on every press would add two keys the
            # author never wrote to a diff with no edit in it (DESIGN 12).
            CommandSuccessShown = ''
            CommandRebootShown = ''

            Image     = ''
            ImageShown = ''
            ImageVariable = ''
            IndexVariable = ''
            Choice    = [string[]] @()

            # THE PROPERTY BOXES, BANKED. Set once the scriptblock exists;
            # handlers written above it reach it through here.
            Bank      = $null

            # THE SHARE'S OPERATING SYSTEMS, read once when the editor opens.
            # See the note beside Get-HDTConsoleImageChoice below.
            Catalog   = $null

            # AND ITS APPLICATIONS, out of the same read, for the page that
            # picks what an InstallApplications step installs.
            AppCatalog = $null
            IndexWritten = ''
            IndexShown = ''
            Quiet     = $false

            # THE LAST STATE, so a handler can echo the command format the
            # view model owns rather than composing a second copy of it.
            State     = $null
        }

        $tree.ItemsSource = $Node

        # TWO FUNCTIONS, AND BOTH ONLY ASSIGN. Every value they put on a control
        # came out of Get-HDTConsoleEditorState; they compute none of them.
        #
        # THEY ARE SEPARATE BECAUSE ASSIGNING ItemsSource RAISES
        # SelectedItemChanged. A single refresh that did both would rebuild the
        # tree, lose the selection, run the selection handler, and refresh
        # again - a loop with no exit, which is exactly what the first version
        # of this did: the window came up, painted once, and hung at
        # "Not Responding" with no error anywhere to read. Reflect never touches
        # the tree; Rebuild is the only thing that does, and it runs only after
        # an edit.
        # ONCE, HERE, RATHER THAN ON EVERY REFRESH BELOW.
        #
        # AND ONE READ FOR BOTH CATALOGUES. The images and the applications come
        # out of the same Get-HDTConsoleWorkspace call: reading the share twice
        # to fill two tabs costs a second of somebody's time for nothing.
        $book.Catalog = @()
        $book.AppCatalog = @()
        try {
            $share = Get-HDTConsoleWorkspace -Path $workspaceRoot -FileSystem (New-HDTFileSystem)

            $book.Catalog = @($share.OperatingSystem)
            $book.AppCatalog = @($share.Application)
        } catch {
            # A share that will not read leaves the lists empty and the editor
            # open - the same bargain Get-HDTConsoleImageChoice makes.
            $book.Catalog = @()
            $book.AppCatalog = @()
        }

        $reflect = {
            # ONE PARSE, HANDED TO ALL FOUR. Each of these view models used to
            # turn the same lines back into a document - about 70ms apiece, on
            # the UI thread, after every edit. Parsing once here is the rest of
            # the fix that started with the catalogue.
            #
            # A DOCUMENT THAT WILL NOT PARSE IS $null, and each of them then
            # falls back to reading the lines itself and reports the failure the
            # way it always did - Get-HDTConsoleEditorState's Error status is
            # what puts the message on the title bar.
            $parsed = $null

            try {
                $parsed = & (Get-Module -Name 'Hephaestus') {
                    param($Body, $Where)

                    Import-HDTSequenceDocument -Path $Where -FileSystem (
                        New-HDTFileSystemFromText -Path $Where `
                            -Text (($Body) -join [System.Environment]::NewLine))
                } $book.Line $Path
            } catch {
                $parsed = $null
            }

            # THE OCCURRENCE TRAVELS HERE TOO, AND THIS IS THE PATH THAT
            # MATTERS. $reflect runs on every selection change; $rebuild only
            # after a splice. A version that passed it in one and not the other
            # would answer correctly right up until somebody clicked a row.
            # A HASHTABLE, BECAUSE TWO OF THESE ARE SWITCHES. -HasClipboard:$x
            # binds against Get-HDTHandlerCall's own block rather than the
            # command, and the value lands positionally - which is the editor
            # refusing to open on "a positional parameter cannot be found that
            # accepts argument 'False'", from a handler, with nothing on screen
            # naming the switch.
            $state = & $call 'Get-HDTConsoleEditorState' @{
                Line               = $book.Line
                Path               = $Path
                SelectedName       = $book.Selected
                SelectedOccurrence = $book.SelectedOccurrence
                Document           = $parsed
                HasClipboard       = ($null -ne $book.Clipboard)
                Dirty              = [bool] $book.Dirty
            }

            $book.State = $state

            $book.Quiet = $true

            # THE VARIABLES TAB. Rebuilt every refresh: the tab edits the
            # block, so a grid still showing what the document said before
            # the last Set would be a grid that lies.
            $variableGrid.ItemsSource = $state.Variable

            # THE WHOLE LIST, KEPT, so the filter has something to widen back
            # to. The box's own ItemsSource is whatever the last keystroke
            # narrowed it to.
            $book.Choice = [string[]] @($state.VariableChoice)
            if (@($variableNameBox.ItemsSource).Count -eq 0) {
                $variableNameBox.ItemsSource = $book.Choice
            }

            $remove.IsEnabled = $state.CanRemove
            $up.IsEnabled = $state.CanMoveUp
            $down.IsEnabled = $state.CanMoveDown
            $copy.IsEnabled = $state.CanCopy
            $paste.IsEnabled = $state.CanPaste
            $save.IsEnabled = $state.CanSave

            $conditionClear.IsEnabled = $state.CanRemove
            $disableCheck.IsEnabled = $state.CanRemove
            $continueCheck.IsEnabled = $state.CanRemove

            $option = $state.Option

            $disableCheck.IsChecked = [bool] ($option -and $option.Flag[0].Checked)
            $continueCheck.IsChecked = [bool] ($option -and @($option.Flag).Count -gt 1 -and $option.Flag[1].Checked)
            $conditionText.Text = [string] ($option | ForEach-Object { $_.Condition })
            $runInText.Text = [string] ($option | ForEach-Object { $_.RunInText })

            $window.Title = '{0} - {1}' -f $Title, $state.StatusText

            # THE DISK TAB, WHICH MOST STEPS DO NOT HAVE. Get-HDTConsolePartitionRow
            # decides both whether it belongs on screen and everything on it; this
            # assigns. The selection is put back by name because the row objects
            # are rebuilt every time.
            $view = & $call 'Get-HDTConsolePartitionRow' -Line $book.Line -Path $Path -Name $book.Selected -Document $parsed

            $diskTab.Visibility = [System.Windows.Visibility]::Collapsed
            if ($view.IsDiskStep) { $diskTab.Visibility = [System.Windows.Visibility]::Visible }

            # THE OPERATING SYSTEM PAGE, on the same rule as the disk one: MDT's
            # Install Operating System dialog IS that step's properties page.
            # THE CATALOGUE IS HANDED IN, READ ONCE. Reading the share's whole
            # operating system list costs about half a second, and this runs on
            # every edit - which froze the window for roughly a second per click
            # and made the Save button look like it was lagging behind.
            #
            # It belongs to the share, not to a keystroke: closing and reopening
            # the editor picks up an image imported meanwhile, which is the same
            # bargain the Windows PE window makes with the ADK component list.
            $imageChoice = & $call 'Get-HDTConsoleImageChoice' -Line $book.Line -Path $Path `
                -Name $book.Selected -Workspace $workspaceRoot -Catalog $book.Catalog -Document $parsed

            $imageTab.Visibility = [System.Windows.Visibility]::Collapsed

            if ($imageChoice.IsImageStep) {
                $imageTab.Visibility = [System.Windows.Visibility]::Visible

                $imageBox.ItemsSource = $imageChoice.Image
                $imageBox.SelectedValue = $imageChoice.Selected

                # THE EDITIONS, AND THE ONE IN FORCE - SELECTED, so the box
                # reads '1  -  Windows 11 Enterprise LTSC' the way it does after
                # somebody picks from the list. Setting the text alone showed a
                # bare '1' until the list was opened, which made the same
                # setting look like two different things.
                #
                # THE TEXT IS THE FALLBACK, because the box is editable and an
                # index written as a variable, or naming an edition this image
                # does not have, still has to be shown as it stands.
                $imageIndexBox.ItemsSource = $imageChoice.Edition

                $matched = @($imageChoice.Edition |
                        Where-Object { [string] $_.Index -eq [string] $imageChoice.Index })

                if (@($matched).Count -gt 0) {
                    $imageIndexBox.SelectedItem = $matched[0]
                } else {
                    $imageIndexBox.SelectedItem = $null
                    $imageIndexBox.Text = [string] $imageChoice.Index
                }
                # THE VOLUMES SOMETHING PUBLISHES, with their percent signs on.
                # Text rather than SelectedValue because the box is editable: a
                # drive letter is legal and has to be typeable.
                $imageTargetBox.ItemsSource = $imageChoice.Destination
                $imageTargetBox.Text = [string] $imageChoice.Target
                $imageTimeoutBox.Text = [string] $imageChoice.TimeoutMinutes


                # WHAT APPLY WOULD WRITE IF NOBODY TOUCHES THE LIST - the
                # author's own text. Changing the selection replaces it; leaving
                # it alone keeps the variable the sequence was built on.
                $book.Image = [string] $imageChoice.Written
                $book.ImageVariable = [string] $imageChoice.ImageVariable
                $book.IndexVariable = [string] $imageChoice.IndexVariable

                # AND WHAT THE BOX WAS SET TO, so the handler can tell "nobody
                # touched it" from "somebody picked the same thing". $imageChoice
                # is local to this refresh; a closure built before it existed
                # would compare against $null and rewrite the file every time.
                $book.ImageShown = [string] $imageChoice.Selected

                # The same for the index: what the box was set to, so Apply can
                # tell an untouched box from a deliberate choice and leave a
                # variable where it stands.
                $book.IndexWritten = [string] $imageChoice.IndexWritten
                $book.IndexShown = [string] $imageChoice.Index
            }


            # THE VALIDATION PAGE, on the same rule as the disk one. MDT's
            # Validate dialog IS that step's properties page, so the generic tab
            # goes with it.
            $validate = & $call 'Get-HDTConsoleValidateCheck' -Line $book.Line -Path $Path -Name $book.Selected -Document $parsed

            $validateTab.Visibility = [System.Windows.Visibility]::Collapsed
            if ($validate.IsValidateStep) {
                $validateTab.Visibility = [System.Windows.Visibility]::Visible
                $validateList.ItemsSource = $validate.Check
            }


            # THE APPLICATIONS PAGE, on the same rule as the other two: MDT's
            # Install Application dialog IS that step's properties page.
            #
            # THE CATALOGUE IS HANDED IN, READ ONCE - see $book.AppCatalog above.
            $application = & $call 'Get-HDTConsoleApplicationChoice' -Line $book.Line -Path $Path `
                -Name $book.Selected -Workspace $workspaceRoot -Catalog $book.AppCatalog -Document $parsed

            $applicationTab.Visibility = [System.Windows.Visibility]::Collapsed

            if ($application.IsApplicationStep) {
                $applicationTab.Visibility = [System.Windows.Visibility]::Visible

                $applicationList.ItemsSource = $application.Application

                # WHICH OF MDT'S TWO ANSWERS THIS STEP IS. Quiet is already true
                # here, so setting IsChecked does not run the handlers that write
                # it back - which would splice the document on every refresh.
                $applicationVariableRadio.IsChecked = [bool] $application.FromVariable
                $applicationFixedRadio.IsChecked = -not [bool] $application.FromVariable

                $applicationVariableBox.Text = [string] $application.Variable
                $applicationNoteText.Text = [string] $application.Note

                $applicationEmptyText.Visibility = [System.Windows.Visibility]::Collapsed
                if (-not $application.HasCatalog) {
                    $applicationEmptyText.Visibility = [System.Windows.Visibility]::Visible
                }
            }


            # RUN COMMAND LINE, on the same rule as the four above: MDT's dialog
            # for this step IS its properties page. What it replaces was two rows
            # on the generic sheet, one of which - the exit codes - could be read
            # and not changed, while Start in could not be reached at all.
            $commandPage = & $call 'Get-HDTConsoleCommandLine' -Line $book.Line -Path $Path `
                -Name $book.Selected -Document $parsed

            $commandTab.Visibility = [System.Windows.Visibility]::Collapsed

            if ($commandPage.IsCommandLineStep) {
                $commandTab.Visibility = [System.Windows.Visibility]::Visible

                # WHICH FORM THIS STEP IS. Collapsed rather than disabled, and
                # in both directions: an empty File box on a step that runs a
                # shell line is a setting that looks unset, and so is an empty
                # Command line box on a step that names a file.
                $shell = [System.Windows.Visibility]::Visible
                $direct = [System.Windows.Visibility]::Collapsed

                if ($commandPage.UsesFile) {
                    $shell = [System.Windows.Visibility]::Collapsed
                    $direct = [System.Windows.Visibility]::Visible
                }

                $commandLineLabel.Visibility = $shell
                $commandLineBox.Visibility = $shell
                $commandFileLabel.Visibility = $direct
                $commandFileBox.Visibility = $direct
                $commandArgumentsLabel.Visibility = $direct
                $commandArgumentsBox.Visibility = $direct

                $commandLineBox.Text = [string] $commandPage.CommandLine
                $commandFileBox.Text = [string] $commandPage.File
                $commandArgumentsBox.Text = [string] $commandPage.Arguments
                $commandStartInBox.Text = [string] $commandPage.WorkingDirectory
                $commandSuccessBox.Text = [string] $commandPage.SuccessCode
                $commandRebootBox.Text = [string] $commandPage.RebootCode

                # See $book.CommandSuccessShown: what the boxes were SET to, so
                # a press that touched neither leaves the document alone.
                $book.CommandSuccessShown = [string] $commandPage.SuccessCode
                $book.CommandRebootShown = [string] $commandPage.RebootCode

                $commandNoteText.Text = [string] $commandPage.Note
                $commandNoteText.Visibility = [System.Windows.Visibility]::Collapsed

                if ($commandPage.HasNote) {
                    $commandNoteText.Visibility = [System.Windows.Visibility]::Visible
                }
            }


            # AND THE GENERIC TAB GOES WHEN A DEDICATED PAGE ARRIVES. With the
            # disk keys on their own page and the name above the tabs, what was
            # left on Properties for this step was eight rows of facts and
            # nothing to do about any of them.
            #
            # Properties stays for every other step type: most have no page of
            # their own, and it is the only editor they get.
            $propertyTab.Visibility = [System.Windows.Visibility]::Visible
            if ($view.IsDiskStep -or $validate.IsValidateStep -or $imageChoice.IsImageStep -or
                $application.IsApplicationStep -or $commandPage.IsCommandLineStep) {
                $propertyTab.Visibility = [System.Windows.Visibility]::Collapsed
            }

            # A COLLAPSED TAB STAYS SELECTED, AND WPF GOES ON DRAWING IT. Hiding
            # the tab hides its header and nothing else - so selecting a Validate
            # step after a DiskPartition one left the Disk page on screen, over a
            # step that has no disk. The selection has to be moved off a tab that
            # is no longer there.
            if ($tabBook.SelectedItem.Visibility -ne [System.Windows.Visibility]::Visible) {
                $tabBook.SelectedItem = @($tabBook.Items |
                        Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible })[0]
            }

            $stepNameBox.Text = [string] $book.Selected
            $stepNameBox.IsEnabled = $state.CanRemove

            $partitionStyleText.Text = $view.Summary
            $partitionList.ItemsSource = $view.Row

            # THE TOP OF THE PAGE, from the document rather than from what was
            # last typed into it. Quiet is already true here, so assigning these
            # does not run the handlers that write them back.
            $diskNumberBox.Text = [string] $view.DiskNumber
            $diskWipeCheck.IsChecked = [bool] $view.Wipe

            if ($null -eq $diskStyleBox.ItemsSource) { $diskStyleBox.ItemsSource = $view.StyleOption }

            $diskStyleBox.SelectedItem = @($view.StyleOption |
                    Where-Object { $_ -eq [string] $view.Style })[0]

            if ($null -eq $diskStyleBox.SelectedItem) { $diskStyleBox.SelectedIndex = 0 }

            $partitionList.SelectedItem = @($view.Row | Where-Object { $_.Name -eq $book.Partition })[0]

            # AT THE ENDS THE ARROWS ARE OFF rather than pressed for nothing.
            # Move-HDTStepPartition returns the document unchanged there, so this
            # is presentation, not the rule.
            $at = -1
            if ($null -ne $partitionList.SelectedItem) { $at = [int] $partitionList.SelectedItem.Order }

            # A ROW THAT CAME FROM A NAMED LAYOUT IS NOT IN THE DOCUMENT, so
            # nothing that edits the document may act on it. Editing one would
            # have to write a table into the step, silently converting it from
            # "the standard layout, whatever that becomes" into a frozen copy of
            # today's - a decision to make deliberately, not by pressing Edit.
            $ownRow = ($at -gt 0 -and -not $partitionList.SelectedItem.FromLayout)

            $partitionUp.IsEnabled = ($ownRow -and $at -gt 1)
            $partitionDown.IsEnabled = ($ownRow -and $at -lt @($view.Row).Count)
            $partitionRemove.IsEnabled = ($ownRow -and @($view.Row).Count -gt 1)
            $partitionEdit.IsEnabled = $ownRow

            # New needs a table to add to. A step that names a layout has none,
            # and swapping one for the other is a decision to make in the
            # Properties tab rather than as a side effect of pressing New.
            $partitionAdd.IsEnabled = $view.HasTable

            $book.Quiet = $false
        }.GetNewClosure()

        # AFTER AN EDIT, AND ONLY THEN. The tree is rebuilt from the spliced
        # lines rather than patched, so what is on screen is what the ENGINE
        # reads back - and the selection is restored by name, because the row
        # object that was selected no longer exists.
        $rebuild = {
            $state = & $call 'Get-HDTConsoleEditorState' -Line $book.Line -Path $Path `
                -SelectedName $book.Selected -SelectedOccurrence $book.SelectedOccurrence

            # PUBLISHED, BECAUSE THE TOOLBAR ACTS ON IT. Up and Down no longer
            # swap siblings - they move the row to where MoveUpTarget and
            # MoveDownTarget say, and those are computed here rather than in a
            # click handler.
            $book.State = $state

            $book.Quiet = $true
            $tree.ItemsSource = $state.Root
            $book.Quiet = $false

            & $reflect
        }.GetNewClosure()


        # -- the Variables tab ---------------------------------------------
        #
        # THE BLOCK THE NEW SEQUENCE WINDOW FILLS, and until this existed
        # nothing could change it: an administrator who mistyped the
        # administrator password re-created the sequence.
        #
        # IT EDITS THE SAME $book.Line AS EVERY OTHER TAB, so Save is still one
        # write and the dirty flag still means what it says. Set-HDTSequenceVariable
        # returns lines and touches nothing.
        # THE TOOLBAR IS THE WAY IN. The tab's own header is collapsed: a tab
        # about the SEQUENCE among tabs about the SELECTED STEP is what hid it,
        # and the toolbar is where sequence-level actions already live.
        $variableButton.Add_Click({
                $tabBook.SelectedItem = $variableTab
            }.GetNewClosure())


        # TYPE TO NARROW. WPF's own TextSearch only matches a PREFIX and jumps
        # the selection rather than shortening the list, which is no use for
        # names that all begin HDT - so the filter is done here, on Contains,
        # and IsTextSearchEnabled is off in the markup to stop the two fighting.
        #
        # THE TEXT IS NEVER REWRITTEN BY THIS. Assigning ItemsSource while
        # somebody is typing would move the caret to the end of whatever WPF
        # decided to select; the box keeps what was typed and only the list
        # under it changes.
        $filterVariable = {
            $typed = [string] $variableNameBox.Text

            $all = @($book.Choice)
            if (@($all).Count -eq 0) { return }

            if ([string]::IsNullOrWhiteSpace($typed)) {
                $variableNameBox.ItemsSource = $all
                return
            }

            $matched = @($all | Where-Object { $_ -like ('*{0}*' -f $typed) })

            # NOTHING MATCHING LEAVES THE WHOLE LIST, not an empty drop-down. A
            # name of this sequence's own is legitimate, and a list that
            # vanished as it was typed would read as a refusal.
            if (@($matched).Count -eq 0) { $matched = $all }

            $variableNameBox.ItemsSource = $matched
            $variableNameBox.IsDropDownOpen = $true
        }.GetNewClosure()

        # THE EDITABLE PART OF A ComboBox IS A TextBox INSIDE ITS TEMPLATE, and
        # it does not exist until the control has been rendered - so the handler
        # is attached to the class event rather than to a control that is not
        # there yet.
        [void] $variableNameBox.AddHandler(
            [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
            [System.Windows.Controls.TextChangedEventHandler] { & $filterVariable }.GetNewClosure())

        # THE GRID FILLS THE BOXES. Clicking a row and pressing Set is how a
        # value is changed; typing the name again would be a way to mistype it.
        $variableGrid.Add_SelectionChanged({
                $chosen = $variableGrid.SelectedItem
                if ($null -eq $chosen) { return }

                $variableNameBox.Text = [string] $chosen.Name
                $variableValueBox.Text = [string] $chosen.Value
            }.GetNewClosure())

        $variableSet.Add_Click({
                $name = ([string] $variableNameBox.Text).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { return }

                try {
                    $book.Line = @(Set-HDTSequenceVariable -Line $book.Line -Name $name `
                            -Value ([string] $variableValueBox.Text) -Confirm:$false)
                } catch {
                    # THE REFUSAL IS THE ANSWER. A name that is not an HDT
                    # variable, or an engine-owned one, is refused by the command
                    # with a sentence saying why - and the window shows that
                    # rather than a stack trace or nothing at all.
                    $commandText.Text = [string] $_.Exception.Message
                    return
                }

                $book.Dirty = $true
                & $rebuild

                $commandText.Text = ([string] $book.State.VariableCommandFormat -f
                    $name, ([string] $variableValueBox.Text))
            }.GetNewClosure())

        $variableRemove.Add_Click({
                $name = ([string] $variableNameBox.Text).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { return }

                try {
                    $book.Line = @(Set-HDTSequenceVariable -Line $book.Line -Name $name -Remove -Confirm:$false)
                } catch {
                    $commandText.Text = [string] $_.Exception.Message
                    return
                }

                $book.Dirty = $true
                $variableNameBox.Text = ''
                $variableValueBox.Text = ''
                & $rebuild

                $commandText.Text = ([string] $book.State.VariableRemoveCommandFormat -f $name)
            }.GetNewClosure())

        # THE ADD MENU, BUILT FROM THE CATALOG AND NOTHING ELSE. A category
        # becomes a submenu, an entry becomes an item carrying its own YAML in
        # Tag - so the handler splices what the catalog decided and chooses
        # nothing itself.
        $menu = $add.ContextMenu

        foreach ($category in $Catalog) {
            $parent = $menu

            if ($category.Category -ne 'New') {
                $submenu = New-Object -TypeName System.Windows.Controls.MenuItem
                $submenu.Header = [string] $category.Category
                [void] $menu.Items.Add($submenu)
                $parent = $submenu
            }

            foreach ($entry in @($category.Item)) {
                $item = New-Object -TypeName System.Windows.Controls.MenuItem
                $item.Header = [string] $entry.Text
                $item.Tag = $entry

                # THE ITEM CARRIES ITS OWN ENTRY IN Tag, and the handler reads it
                # off the control that raised the event rather than closing over
                # the loop variable - a closure over $entry would capture the
                # LAST one for every item in the menu.
                #
                # $menuItem, not $sender: $sender is an automatic variable in
                # PowerShell and assigning to it in a param block is a warning
                # the analyzer raises and a side effect nobody wants.
                $item.Add_Click({
                        param($menuItem)

                        $chosen = $menuItem.Tag
                        $book.Line = @(Add-HDTStep -Line $book.Line -After $book.Selected -Block $chosen.Block)
                        $book.Dirty = $true
                        $command.Text = [string] $chosen.Command

                        & $rebuild
                    }.GetNewClosure())

                [void] $parent.Items.Add($item)
            }
        }

        $add.Add_Click({
                $menu.PlacementTarget = $add
                $menu.IsOpen = $true
            }.GetNewClosure())

        # -Occurrence ON EVERY ONE OF THESE, and it is the whole fix. The
        # selection is a ROW; the name alone stopped describing it the moment a
        # sequence held two steps called the same thing, and Up and Down were
        # moving whichever the resolver found first rather than the one somebody
        # had clicked.
        $remove.Add_Click({
                $book.Line = @(Remove-HDTStep -Line $book.Line -Name $book.Selected `
                        -Occurrence $book.SelectedOccurrence -Confirm:$false)
                $book.Dirty = $true
                $book.Selected = ''
                $book.SelectedOccurrence = 0
                & $rebuild
            }.GetNewClosure())

        # UP AND DOWN WALK THE LIST ON SCREEN, NOT A GROUP'S SIBLINGS.
        # Get-HDTStepNeighbourTarget says which row to land beside and which
        # side of it; this decides nothing, which is the point - a WPF handler
        # is the one place in this repository nothing can test.
        $up.Add_Click({
                $to = $book.State.MoveUpTarget
                if ($null -eq $to) { return }

                $book.Line = @(Move-HDTStep -Line $book.Line -Name $book.Selected `
                        -Occurrence $book.SelectedOccurrence `
                        -Target $to.Target -TargetOccurrence $to.TargetOccurrence -Position $to.Position)
                $book.Dirty = $true

                # THE ORDINAL IS NOT ADJUSTED HERE, AND GUESSING IT WOULD BE A
                # WORSE BUG THAN THE ONE THIS FIXES. A move swaps the row with a
                # sibling; the ordinal changes only if that sibling SHARES the
                # name, and this handler cannot see which sibling it was without
                # a second copy of Move-HDTStep's own logic. So the move is
                # correct - it acted on the selected row - and the selection
                # afterwards follows the name, which on duplicates may land on
                # the first of them. Stable row identity is what fixes that
                # properly, and drag and drop needs it anyway.
                & $rebuild
            }.GetNewClosure())

        $down.Add_Click({
                $to = $book.State.MoveDownTarget
                if ($null -eq $to) { return }

                $book.Line = @(Move-HDTStep -Line $book.Line -Name $book.Selected `
                        -Occurrence $book.SelectedOccurrence `
                        -Target $to.Target -TargetOccurrence $to.TargetOccurrence -Position $to.Position)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $copy.Add_Click({
                $book.Clipboard = @(Copy-HDTStep -Line $book.Line -Name $book.Selected `
                        -Occurrence $book.SelectedOccurrence)
                & $rebuild
            }.GetNewClosure())

        $paste.Add_Click({
                $book.Line = @(Add-HDTStep -Line $book.Line -After $book.Selected -Block $book.Clipboard)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        # THE ONLY PRESS THAT TOUCHES THE SHARE. Save-HDTSequenceDocument checks
        # the result through the engine's own reader before it writes.
        $save.Add_Click({
                # WHAT IS IN THE BOXES IS PART OF WHAT IS BEING SAVED. Without
                # this, Save wrote the document as it was before the last thing
                # anybody typed - which is the failure a separate Apply button
                # was avoiding by making them press twice.
                #
                # THROUGH THE BOOK, because $bankProperties is created three
                # hundred lines below this handler and GetNewClosure captures by
                # VALUE - a closure taken here would have captured $null.
                if ($null -ne $book.Bank) { & $book.Bank }

                [void] (Save-HDTSequenceDocument -Path $Path -Line $book.Line -FileSystem (New-HDTFileSystem) -Confirm:$false)
                $book.Dirty = $false
                & $rebuild
            }.GetNewClosure())

        $disableCheck.Add_Click({
                if ($book.Quiet) { return }

                $book.Line = @(Set-HDTStepFlag -Line $book.Line -Name $book.Selected `
                        -Flag Disabled -Value ([bool] $disableCheck.IsChecked))
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $continueCheck.Add_Click({
                if ($book.Quiet) { return }

                $book.Line = @(Set-HDTStepFlag -Line $book.Line -Name $book.Selected `
                        -Flag ContinueOnError -Value ([bool] $continueCheck.IsChecked))
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        # THE PROPERTIES TAB, WHICH IS SEVERAL BOXES AND ONE PRESS. The rows are
        # the edit buffer - Text is bound TwoWay - so Apply asks
        # Get-HDTConsoleStepChange which of them were typed into and splices
        # exactly those. A rename comes back last, so the earlier changes still
        # find the step by the name it had when the tab was filled.
        # THE PROPERTY BOXES ARE BANKED AT THE TWO MOMENTS THEY HAVE TO BE, and
        # there is no Apply button any more.
        #
        # WHY THERE WAS ONE. The rows are an edit buffer - Text is bound TwoWay -
        # so something has to decide when typing becomes a splice.
        # Get-HDTConsoleStepChange answers WHICH rows were typed into; the
        # question was only WHEN to ask it.
        #
        # THE ANSWER IS: before Save writes, and before the pane is refilled for
        # another step. One toolbar Save is what an administrator expects to
        # commit a window, and a second commit button on one tab of five taught
        # that the other four did not need one.
        #
        # THE RENAME COMES BACK LAST, exactly as it did before: earlier changes
        # still find the step by the name it had when the tab was filled.
        $bankProperties = {
                $subject = $book.Selected
                if ([string]::IsNullOrWhiteSpace($subject)) { return }

                foreach ($one in @(& $call 'Get-HDTConsoleStepChange' -Field $detail.ItemsSource -Name $subject)) {
                    # A LIST ROW TAKES THE OTHER CMDLET. Set-HDTStepProperty
                    # quotes what it is given, so Install Roles would get
                    # features: 'Web-Server, DNS' - one feature with a comma in
                    # its name - and refuse it at the machine. The ROW said
                    # which it is; this only obeys.
                    if ($one.IsList) {
                        $book.Line = @(Set-HDTStepPropertyList -Line $book.Line -Name $subject `
                                -Property $one.Property -Item ([string[]] @($one.Item)) -Confirm:$false)
                    } else {
                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                                -Property $one.Property -Value $one.Value)
                    }

                    $command.Text = [string] $one.Command
                    $book.Dirty = $true

                    # What it answers to from here on. Only a rename moves it,
                    # and the change says so - the window does not carry its own
                    # idea of which properties are names.
                    $subject = [string] $one.NameAfter
                }

                $book.Selected = $subject
            }.GetNewClosure()

        $conditionClear.Add_Click({
                $book.Line = @(Set-HDTStepCondition -Line $book.Line -Name $book.Selected -Condition '')
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        # =================================================================
        # THE DISK TAB
        # =================================================================
        #
        # MDT's Format and Partition Disk dialog. Five buttons, five commands,
        # and nothing on this tab decides anything: which row is where came from
        # Get-HDTConsolePartitionRow, and what each press does is one call.

        # SELECTING A ROW IS ALL THIS PAGE DOES ON ITS OWN. Every value a volume
        # has is edited in the Partition Properties dialog, which is where MDT
        # puts them and the only place eight fields and two checkboxes read as
        # the thing being edited rather than as filters over the list.
        $partitionList.Add_SelectionChanged({
                # Reflect assigns SelectedItem, which raises this.
                if ($book.Quiet) { return }

                $chosen = $partitionList.SelectedItem
                if ($null -eq $chosen) { return }

                $book.Partition = [string] $chosen.Name
                $command.Text = [string] $chosen.RemoveCommand

                & $reflect
            }.GetNewClosure())

        # A FAILED EDIT IS SHOWN, NOT SWALLOWED. Every one of these refuses
        # something - a size the engine cannot read, the last row, a second boot
        # partition - and a button that did nothing without saying why would
        # leave the person pressing it to guess which refusal they hit.
        $partitionAttempt = {
            param([scriptblock] $Attempt, [string] $Echo, [bool] $Rebuild = $true)

            # WHAT THE DOCUMENT SAID BEFORE. Every page on this window now
            # commits by itself - there is no Apply button anywhere - so these
            # writes run on leaving a box and on leaving a step, not only when
            # somebody asked for one. Marking the window dirty unconditionally
            # would light Save up for walking through a sequence and reading it,
            # and then write a file with no edit in it.
            $before = [string[]] @($book.Line)

            try {
                & $Attempt

                $changed = (@($book.Line).Count -ne @($before).Count)

                if (-not $changed) {
                    for ($i = 0; $i -lt @($before).Count; $i++) {
                        if ([string] $book.Line[$i] -ne [string] $before[$i]) {
                            $changed = $true
                            break
                        }
                    }
                }

                if (-not $changed) { return }

                $book.Dirty = $true
                $command.Text = $Echo

                # NOT WHILE THE PANE IS BEING REFILLED. Banking runs from inside
                # the selection change, and rebuilding the tree there would
                # replace the rows under the handler that is walking them.
                if ($Rebuild) { & $rebuild }
            } catch {
                $command.Text = [string] $_.Exception.Message
            }
        }.GetNewClosure()

        # THE DIALOG, AND WHAT COMES BACK FROM IT. It returns a hashtable ready
        # to splat at Add-HDTStepPartition or Set-HDTStepPartition, or $null if
        # it was cancelled - so the two handlers below differ only in which
        # command they call.
        $partitionDialog = {
            param([object] $Row)

            $view = & $call 'Get-HDTConsolePartitionRow' -Line $book.Line -Path $Path -Name $book.Selected

            $dialog = $editorHost.ShowPartitionProperties($PartitionXaml, $Row, $view.Unit, $Theme, $window)
            if ($null -eq $dialog) { return $null }

            return $dialog
        }.GetNewClosure()

        $partitionAdd.Add_Click({
                $answer = & $partitionDialog $null
                if ($null -eq $answer) { return }

                $written = [string] $answer['Partition']

                & $partitionAttempt {
                    $book.Line = @(Add-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            @answer -Confirm:$false)

                    $book.Partition = $written
                } ("Add-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}'" -f $book.Selected, $written)
            }.GetNewClosure())

        # EDIT IS ITS OWN COMMAND BECAUSE DELETE AND ADD AGAIN WOULD MOVE THE
        # ROW to the bottom of the table, and the table's order is the order on
        # the disk - a change to the disk rather than to the volume.
        $partitionEdit.Add_Click({
                $chosen = $partitionList.SelectedItem
                if ($null -eq $chosen) { return }

                $answer = & $partitionDialog $chosen
                if ($null -eq $answer) { return }

                $subject = [string] $chosen.Name
                $written = [string] $answer['Partition']

                # The dialog always returns a name; on Edit it is -NewName, and
                # only when it is actually a new one.
                [void] $answer.Remove('Partition')
                [void] $answer.Remove('First')

                if ($written -ne $subject) { $answer['NewName'] = $written }

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject @answer -Confirm:$false)

                    $book.Partition = $written
                } ("Set-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}'" -f $book.Selected, $subject)
            }.GetNewClosure())

        $partitionRemove.Add_Click({
                if ([string]::IsNullOrWhiteSpace($book.Partition)) { return }
                $subject = [string] $book.Partition

                & $partitionAttempt {
                    $book.Line = @(Remove-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject -Confirm:$false)

                    $book.Partition = ''
                } ("Remove-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}'" -f $book.Selected, $subject)
            }.GetNewClosure())

        $partitionUp.Add_Click({
                if ([string]::IsNullOrWhiteSpace($book.Partition)) { return }
                $subject = [string] $book.Partition

                & $partitionAttempt {
                    $book.Line = @(Move-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject -Direction Up -Confirm:$false)
                } ("Move-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}' -Direction Up" -f $book.Selected, $subject)
            }.GetNewClosure())

        $partitionDown.Add_Click({
                if ([string]::IsNullOrWhiteSpace($book.Partition)) { return }
                $subject = [string] $book.Partition

                & $partitionAttempt {
                    $book.Line = @(Move-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject -Direction Down -Confirm:$false)
                } ("Move-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}' -Direction Down" -f $book.Selected, $subject)
            }.GetNewClosure())

        # THE TOP OF THE PAGE WRITES THE STEP'S OWN KEYS, through the same
        # Set-HDTStepProperty every other property box uses. Disk number and
        # disk type are one decision with the table below them, which is why
        # they are on this page and not on Properties.
        $imageBox.Add_SelectionChanged({
                if ($book.Quiet) { return }

                $picked = $imageBox.SelectedItem
                if ($null -eq $picked) { return }

                $imageIndexBox.ItemsSource = $picked.Edition

                # A DIFFERENT IMAGE'S INDEX MEANS NOTHING. Its editions are
                # numbered from one like everybody else's, so carrying the old
                # number across is how a Server sequence ends up applying
                # whatever Windows 11 calls index 2.
                #
                # SELECTED, NOT TYPED, for the same reason the initial fill is:
                # setting the text alone leaves a bare '1' in a box that shows
                # '1  -  Windows Server 2025 Standard' the moment the list is
                # opened, so the same setting reads as two different things.
                $imageIndexBox.SelectedItem = $null
                $imageIndexBox.Text = ''

                if (@($picked.Edition).Count -gt 0) {
                    $imageIndexBox.SelectedItem = @($picked.Edition)[0]
                }
            }.GetNewClosure())

        # THE OPERATING SYSTEM PAGE WRITES ON ONE PRESS, for the reason the
        # validation page does: four boxes written on every keystroke would
        # splice the document four times while somebody types a number.
        # THE OPERATING SYSTEM PAGE COMMITS ITSELF TOO - see $commandWrite for
        # why there is no button.
        # THE CONDITION COMMITS ON LEAVING THE BOX, not on a button. Build
        # writes an expression INTO the box and always did; Apply was a second
        # name for finishing with it, and this window now has exactly one way to
        # finish with a box everywhere else.
        #
        # NOT ON EVERY KEYSTROKE: an expression is typed a character at a time
        # and half of one is not a condition, so splicing per key would rebuild
        # the tree under the cursor and write nonsense in between.
        $conditionWrite = {
                param([bool] $Rebuild = $true)

                if ([string]::IsNullOrWhiteSpace([string] $book.Selected)) { return }

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepCondition -Line $book.Line -Name $book.Selected `
                            -Condition ([string] $conditionText.Text) -Confirm:$false)
                } ("Set-HDTStepCondition -Line `$line -Name '{0}' -Condition '{1}'" -f
                    $book.Selected, [string] $conditionText.Text) $Rebuild
            }.GetNewClosure()

        $conditionText.Add_LostFocus({
                if ($book.Quiet) { return }
                & $conditionWrite $true
            }.GetNewClosure())

        $imageWrite = {
                param([bool] $Rebuild = $true)

                if ($imageTab.Visibility -ne [System.Windows.Visibility]::Visible) { return }
                if ([string]::IsNullOrWhiteSpace([string] $book.Selected)) { return }

                # WHAT THIS PRESS WRITES, decided away from the window: whether
                # the image box was really changed, whether the new choice
                # belongs in the variables block or in the step, and which of
                # the two commands to echo. Eight branches turning on the fact
                # that THE BOX SHOWS WHAT THE STEP RESOLVES TO, not what it
                # says - so writing back what the box holds would replace
                # '%HDTOSImage%' with today's answer, on a press meant for the
                # time limit. tests/unit/ConsoleImageWrite.Tests.ps1 covers it.
                #
                # The index box is read here rather than in the command because
                # only WPF knows the difference between the selected row and the
                # label it displays.
                $indexSelected = ''
                if ($null -ne $imageIndexBox.SelectedItem) {
                    $indexSelected = [string] $imageIndexBox.SelectedItem.Index
                }

                $write = & $call 'Get-HDTConsoleImageWrite' `
                    -Step ([string] $book.Selected) `
                    -Image ([string] $book.Image) `
                    -ImageShown ([string] $book.ImageShown) `
                    -ImageVariable ([string] $book.ImageVariable) `
                    -Chosen ([string] $imageBox.SelectedValue) `
                    -IndexTyped ([string] $imageIndexBox.Text) `
                    -IndexSelected $indexSelected `
                    -IndexShown ([string] $book.IndexShown) `
                    -IndexWritten ([string] $book.IndexWritten) `
                    -Target ([string] $imageTargetBox.Text) `
                    -TimeoutMinutes ([string] $imageTimeoutBox.Text)

                if ($write.VariableName -ne '') {
                    $book.Line = @(Set-HDTSequenceVariable -Line $book.Line `
                            -Name ([string] $write.VariableName) `
                            -Value ([string] $write.VariableValue) -Confirm:$false)
                }

                & $partitionAttempt {
                    foreach ($one in @($write.Property)) {
                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                                -Property ([string] $one.Key) -Value ([string] $one.Value) -Confirm:$false)
                    }
                } ([string] $write.Command) $Rebuild
            }.GetNewClosure()

        # PICKING FROM A LIST IS THE EDIT - there is nothing more to confirm.
        # Guarded on Quiet because filling the box raises SelectionChanged too,
        # and that would splice the document on every refresh.
        foreach ($picker in @($imageBox, $imageIndexBox)) {
            $picker.Add_SelectionChanged({
                    if ($book.Quiet) { return }
                    & $imageWrite $true
                }.GetNewClosure())
        }

        foreach ($box in @($imageTargetBox, $imageTimeoutBox)) {
            $box.Add_LostFocus({
                    if ($book.Quiet) { return }
                    & $imageWrite $true
                }.GetNewClosure())
        }

        # RUN COMMAND LINE, WRITTEN IN ONE PRESS. Same shape as the image page:
        # Apply splices, Revert is the refresh that throws the boxes away.
        # THE COMMAND PAGE WRITES WHEN A BOX IS LEFT, and once more when the
        # step changes or the window is saved. There is no Apply button here or
        # anywhere else on this window: the toolbar Save is what commits it, and
        # a second commit button on one tab of six taught that the others did
        # not need one.
        $commandWrite = {
                param([bool] $Rebuild = $true)

                $subject = [string] $book.Selected
                if ([string]::IsNullOrWhiteSpace($subject)) { return }
                if ($commandTab.Visibility -ne [System.Windows.Visibility]::Visible) { return }

                & $partitionAttempt {
                    # THE FORM THE DOCUMENT IS IN, NOT THE ONE THE PAGE PREFERS.
                    # The direct-exec boxes are on screen only when the step
                    # already names a file, so writing 'command' from a hidden
                    # box would replace a step somebody wrote deliberately with
                    # an empty one.
                    if ($commandFileBox.Visibility -eq [System.Windows.Visibility]::Visible) {
                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                                -Property 'file' -Value ([string] $commandFileBox.Text) -Confirm:$false)

                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                                -Property 'arguments' -Value ([string] $commandArgumentsBox.Text) -Confirm:$false)
                    } else {
                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                                -Property 'command' -Value ([string] $commandLineBox.Text) -Confirm:$false)
                    }

                    # START IN, AND AN EMPTY BOX REMOVES IT. Set-HDTStepProperty
                    # treats blank as a removal, which is right here: there is no
                    # default working directory to fall back to, so an empty key
                    # and no key mean the same thing to the engine.
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                            -Property 'workingDirectory' -Value ([string] $commandStartInBox.Text) -Confirm:$false)

                    # THE CODES, ONLY IF SOMEBODY TOUCHED THEM. The boxes show
                    # the engine's defaults for a step that names none, so
                    # writing them unconditionally would add two keys to a
                    # document whose author deliberately left them out.
                    $codes = @(
                        @{ Key = 'successCodes'; Text = [string] $commandSuccessBox.Text; Shown = [string] $book.CommandSuccessShown }
                        @{ Key = 'rebootCodes'; Text = [string] $commandRebootBox.Text; Shown = [string] $book.CommandRebootShown }
                    )

                    foreach ($one in $codes) {
                        if ([string] $one.Text -eq [string] $one.Shown) { continue }

                        $book.Line = @(Set-HDTStepPropertyList -Line $book.Line -Name $subject `
                                -Property ([string] $one.Key) `
                                -Item ([string[]] @([string] $one.Text -split ',')) -Confirm:$false)
                    }
                } (
                    "Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'workingDirectory' -Value '{1}'" -f
                    $subject, [string] $commandStartInBox.Text) $Rebuild
            }.GetNewClosure()

        # ONE HANDLER PER BOX, ON LEAVING IT. Writing on every keystroke would
        # splice the document once per character and rebuild the tree under
        # somebody's hands, which is the rule the Validation page's number boxes
        # already follow.
        foreach ($box in @($commandLineBox, $commandFileBox, $commandArgumentsBox,
                $commandStartInBox, $commandSuccessBox, $commandRebootBox)) {

            $box.Add_LostFocus({
                    if ($book.Quiet) { return }
                    & $commandWrite $true
                }.GetNewClosure())
        }

        # THE WHOLE PAGE, WRITTEN IN ONE SPLICE. Every check is written, ticked
        # or not, because unticking one is as much an edit as ticking it.
        #
        # UNTICKED REMOVES THE KEY rather than writing a zero: 'minRamMB: 0' is a
        # bound of nothing that still reads as a declared bound, and there would
        # then be no way to say "I do not care about memory".
        # EVERY PAGE THAT HOLDS TYPING, BANKED AT THE TWO MOMENTS IT MATTERS:
        # before Save writes, and before the pane is refilled for another step.
        # The Properties rows were the only ones banked while the other pages
        # had Apply buttons to make the point; with the buttons gone, anything
        # still sitting in a box has to be committed here or it is lost the
        # moment somebody clicks the next step - silently, which is worse than
        # the button was.
        #
        # NO REBUILD FROM HERE. This runs from inside the selection change, and
        # rebuilding the tree would replace the rows under the handler walking
        # them. $partitionAttempt writes nothing when nothing changed, so
        # banking a page nobody touched costs a comparison.
        $book.Bank = {
                & $bankProperties
                & $imageWrite $false
                & $commandWrite $false
                & $conditionWrite $false
            }.GetNewClosure()

        $validateWrite = {
            $written = New-Object -TypeName System.Collections.ArrayList

            foreach ($check in @($validateList.ItemsSource)) {
                $key = [string] $check.Key

                if ($check.Enabled -ne $true) {
                    [void] $written.Add(@{ Key = $key; Value = '' })
                    continue
                }

                # A SWITCH CARRIES NO VALUE, so ticking it writes true - the
                # word the engine reads - rather than an empty string that
                # would read as absent.
                $value = [string] $check.Value
                if (-not $check.HasValue) { $value = 'true' }

                [void] $written.Add(@{ Key = $key; Value = $value })
            }

            & $partitionAttempt {
                foreach ($one in $written) {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                            -Property ([string] $one.Key) -Value ([string] $one.Value) -Confirm:$false)
                }
            } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property '<each check>' -Value '<value>'" -f $book.Selected)
        }.GetNewClosure()

        # A TICK HERE WRITES, THE SAME AS EVERY OTHER TICK IN THIS WINDOW.
        # Wipe the disk first and Disable this step both write the moment they
        # are clicked; a validation tick did not, and waited for Apply checks.
        # One control, two rules, and the tab that had the second one read as a
        # tab where nothing works: ticked a check, Save stayed grey, closed the
        # window, lost the edit.
        #
        # ONE HANDLER ON THE LIST, not one per row: the rows are made by a
        # DataTemplate and remade on every selection, so a handler attached to
        # each would need attaching again every time. Click bubbles from the
        # CheckBox, and a value box is not a ToggleButton so typing does not
        # come through here.
        $validateList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::ClickEvent,
            [System.Windows.RoutedEventHandler] {
                if ($book.Quiet) { return }
                & $validateWrite
            }.GetNewClosure())

        # AND A TYPED NUMBER WRITES WHEN THE BOX IS LEFT, which is what the step
        # name box and the console's detail pane already do. Writing on every
        # keystroke would splice the document six times while somebody types a
        # number, and each splice rebuilds the tree under their hands.
        $validateList.AddHandler([System.Windows.Controls.TextBox]::LostFocusEvent,
            [System.Windows.RoutedEventHandler] {
                if ($book.Quiet) { return }
                & $validateWrite
            }.GetNewClosure())

        # NO Apply checks AND NO Revert. This page already wrote on every tick
        # and on leaving every number box - the button was the same splice said
        # a second time, and a window with six tabs and two commit buttons on
        # two of them teaches that the other four do not save.

        # -- the Applications tab ------------------------------------------
        #
        # ONE KEY IS WRITTEN, `selection`, and which of MDT's two answers the
        # page is on decides what goes in it: the variable the step reads, or
        # the ids that are ticked.
        #
        # A COMMA-SEPARATED SCALAR, NOT A YAML LIST. Both are one list to the
        # step's own reader, and a scalar is what Set-HDTStepProperty splices -
        # writing a block sequence would leave its item lines behind the next
        # time this rewrote the key.
        $applicationWrite = {
            $value = ''

            if ($applicationVariableRadio.IsChecked -eq $true) {
                $typed = ([string] $applicationVariableBox.Text).Trim()

                # AN EMPTY BOX IS THE VARIABLE THE STEP FALLS BACK TO, rather
                # than a step that installs nothing: clearing a name is not a
                # decision to deploy no software.
                if ([string]::IsNullOrWhiteSpace($typed)) { $typed = 'HDTApplications' }

                $value = '%{0}%' -f ($typed -replace '%', '')
            } else {
                $value = (@(@($applicationList.ItemsSource) |
                            Where-Object { $_.Selected -eq $true } |
                            ForEach-Object { [string] $_.Id }) -join ', ')
            }

            & $partitionAttempt {
                $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                        -Property 'selection' -Value $value -Confirm:$false)
            } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'selection' -Value '{1}'" -f
                $book.Selected, $value)
        }.GetNewClosure()

        # A TICK WRITES, the same as every tick on the Validation page, and for
        # the reason found there: a tab where the tick did nothing until Apply
        # read as a tab where nothing works.
        #
        # ONE HANDLER ON THE LIST, not one per row - the rows are made by a
        # DataTemplate and remade on every selection.
        $applicationList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::ClickEvent,
            [System.Windows.RoutedEventHandler] {
                if ($book.Quiet) { return }
                & $applicationWrite
            }.GetNewClosure())

        # CHOOSING THE VARIABLE WRITES IT, because that is an unambiguous edit:
        # the step goes back to reading %HDTApplications%.
        $applicationVariableRadio.Add_Checked({
                if ($book.Quiet) { return }
                & $applicationWrite
            }.GetNewClosure())

        # CHOOSING THE LIST WRITES NOTHING YET. Nothing is ticked at that moment,
        # so writing would clear the key - which the engine reads as the variable
        # again, and the radio would snap back under somebody's hand. The first
        # tick is the edit.
        $applicationVariableBox.Add_LostFocus({
                if ($book.Quiet) { return }
                if ($applicationVariableRadio.IsChecked -ne $true) { return }

                & $applicationWrite
            }.GetNewClosure())

        # NO Apply AND NO Revert, for the reason on the Validation page: a tick
        # here is already the edit.

        # RENAMING IS A SPLICE LIKE ANY OTHER, and it has to update what the
        # window then refers to the step by - otherwise the next press acts on a
        # name the document no longer has.
        $stepNameBox.Add_LostFocus({
                if ($book.Quiet) { return }

                $typed = [string] $stepNameBox.Text
                if ([string]::IsNullOrWhiteSpace($typed)) { return }
                if ($typed -eq [string] $book.Selected) { return }

                $was = [string] $book.Selected

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $was `
                            -Property 'name' -Value $typed -Confirm:$false)

                    $book.Selected = $typed
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'name' -Value '{1}'" -f $was, $typed)
            }.GetNewClosure())

        $diskNumberBox.Add_LostFocus({
                if ($book.Quiet) { return }

                $typed = [string] $diskNumberBox.Text

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                            -Property 'diskNumber' -Value $typed -Confirm:$false)
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'diskNumber' -Value '{1}'" -f $book.Selected, $typed)
            }.GetNewClosure())

        $diskStyleBox.Add_SelectionChanged({
                if ($book.Quiet) { return }

                $picked = [string] $diskStyleBox.SelectedItem
                if ([string]::IsNullOrWhiteSpace($picked)) { return }

                # FOLLOWING THE FIRMWARE IS THE ABSENCE OF THE KEY, which is why
                # it is an empty value rather than a word written into the file:
                # 'style: follows the firmware' is not something the engine reads.
                $value = $picked
                if ($picked -eq 'follows the firmware') { $value = '' }

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                            -Property 'style' -Value $value -Confirm:$false)
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'style' -Value '{1}'" -f $book.Selected, $value)
            }.GetNewClosure())

        $diskWipeCheck.Add_Click({
                if ($book.Quiet) { return }

                $value = 'false'
                if ($diskWipeCheck.IsChecked -eq $true) { $value = 'true' }

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                            -Property 'wipe' -Value $value -Confirm:$false)
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'wipe' -Value '{1}'" -f $book.Selected, $value)
            }.GetNewClosure())

        # THE SELECTION IS REMEMBERED BY NAME, not by row. A splice rebuilds the
        # tree from scratch, so the object that was selected no longer exists -
        # and a name is what every editing cmdlet takes anyway.
        $tree.Add_SelectedItemChanged({
                $selected = $tree.SelectedItem
                if ($null -eq $selected) { return }

                # BANK THE LAST STEP'S BOXES BEFORE THE PANE IS REFILLED.
                # Without this, clicking another step throws away what was typed
                # into this one - silently, which is worse than the extra button
                # that used to be here.
                if ($null -ne $book.Bank -and -not $book.Quiet) { & $book.Bank }

                $detail.ItemsSource = $selected.Field
                $command.Text = [string] $selected.Command
                $book.Selected = [string] $selected.Name

                # WHICH ROW, NOT JUST WHICH NAME. A sequence with two steps
                # called 'Tattoo' - which MDT allows - used to answer Remove with
                # "the one to act on is ambiguous", because everything the tree
                # knew about the selection was thrown away here except a string.
                $book.SelectedOccurrence = 1
                if ($null -ne $selected.PSObject.Properties['Occurrence']) {
                    $book.SelectedOccurrence = [int] $selected.Occurrence
                }

                # Reflect, NEVER rebuild: rebuilding assigns ItemsSource, which
                # raises this event again.
                & $reflect
            }.GetNewClosure())

        $window.Add_ContentRendered({
                $first = $tree.ItemContainerGenerator.ContainerFromIndex(0)
                if ($null -ne $first) { $first.IsSelected = $true }
            }.GetNewClosure())

        $close.Add_Click({
                $editorHost.Answer = 'Close'
                $window.Close()
            }.GetNewClosure())

        # THE WAY OUT ASKS FIRST, WHICHEVER WAY OUT IT IS. Closing is on
        # Closing rather than on the Close button because the title-bar X never
        # runs a button's handler - which is how the editor came to discard
        # every splice in silence while its own title said "unsaved changes".
        #
        # CLOSING IS STILL ONE OF THE ANSWERS. An editor that refused to close
        # until the document was saved would be worse than one that discarded
        # it: somebody who has made a mess of a sequence needs to leave without
        # writing it, and that is exactly when they are least able to fix it
        # first.
        #
        # WHAT IS ASKED AND WHAT THE ANSWER MEANS ARE BOTH DECIDED IN COMMANDS.
        # This shows a dialog and acts on two booleans; which button writes to a
        # deployment share is not an opinion an untested adapter should hold.
        $window.Add_Closing({
                param($closingWindow, $closing)

                $prompt = & $call 'Get-HDTConsoleClosePrompt' @{ DocumentPath = $Path; Dirty = [bool] $book.Dirty }

                if (-not $prompt.Ask) { return }

                # Cast rather than dynamic member access: the command names the
                # button set and the icon as strings, and a cast is what turns a
                # name into the enum without this line knowing the list.
                $answer = [System.Windows.MessageBox]::Show($window, $prompt.Message, $prompt.Title,
                    ([System.Windows.MessageBoxButton] $prompt.Button),
                    ([System.Windows.MessageBoxImage] $prompt.Icon))

                $decision = & $call 'Resolve-HDTConsoleCloseAnswer' -Answer ([string] $answer)

                if ($decision.Cancel) {
                    $closing.Cancel = $true
                    return
                }

                if ($decision.Save) {
                    [void] (Save-HDTSequenceDocument -Path $Path -Line $book.Line `
                            -FileSystem (New-HDTFileSystem) -Confirm:$false)
                    $book.Dirty = $false
                }
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # =====================================================================
    # THE WINDOWS PE WINDOW
    # =====================================================================
    #
    # Four tabs over one YAML block, and every control on it runs a command that
    # already existed before this method did. What is ticked, what is listed,
    # what each row would invoke and what the totals read as were all decided by
    # Get-HDTConsoleBootImageSetting; this assigns them by name and wires the presses.
    #
    # THE COMPONENT LIST'S ItemsSource IS ASSIGNED EXACTLY ONCE, and that is the
    # trap this window has that the editor does not. Assigning it builds a
    # CheckBox per row and sets IsChecked from the model, which raises Checked -
    # which is the handler that edits the document. Reassigning it after every
    # tick would re-raise Checked for every ticked row, edit the document again,
    # and reassign again. The ticks mutate the bound objects in place, so there
    # is nothing to rebuild; only the total is recomputed.
    #
    # AND THE GUARD IS STATE, NOT TIMING. A quiet flag lowered after the
    # assignment - even from a Background dispatcher callback - does not work
    # here: a TabControl DOES NOT REALISE AN UNSELECTED TAB, so the Features
    # checkboxes are built the first time an administrator clicks that tab,
    # arbitrarily later, and every one of them raises Checked as it takes its
    # bound value. Add-HDTBootImageComponent refuses a duplicate outright, so
    # the window died on that click. Comparing against what the document
    # actually declares cannot be out-waited.

    $service | Add-Member -MemberType ScriptMethod -Name ShowBootImage -Value {
        param(
            [string] $Xaml, [string] $Path, [string[]] $Line,
            [object[]] $Component, [object[]] $DriverGroup, [object] $Theme, [object] $Size,
            [object[]] $TimeZone = @()
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
        # Get-HDTHandlerCall. Declared here so every closure below captures it.
        $call = Get-HDTHandlerCall

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Icon = Get-HDTConsoleWindowIcon

        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height
        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top
        $window.Owner = $this.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $this.Answer = ''
        $imageHost = $this

        # Which editor the ? panel writes into; set when a ? is clicked.
        $imageHost | Add-Member -MemberType NoteProperty -Name 'RuleHelpTarget' -Value $null -Force

        $titleText = $window.FindName('HDTBootImageTitleText')
        $pathText = $window.FindName('HDTBootImagePathText')

        # -- the ? on the Rules and Bootstrap tabs -----------------------------
        #
        # WHAT MAY BE WRITTEN IN A RULE, IN THE WINDOW THAT EDITS RULES. The
        # vocabulary is forty variable names, the MDT names they came from and
        # MDT's #Left(...)# expressions, and none of it was on screen - so the
        # only way to find out was DESIGN.md, on another machine, while this
        # window is open over a share.
        #
        # ONE PANEL FOR BOTH BUTTONS, because bootstrap-rules.yaml is written in
        # the same language as rules.yaml. Two would be two to keep in step.
        #
        # NOTHING HERE KNOWS WHAT A VARIABLE IS. Get-HDTConsoleRuleHelp derives
        # every row from Get-HDTVariableMap and hands back a flat list; this
        # assigns it once and opens a popup.
        $ruleHelpPopup = $window.FindName('HDTRuleHelpPopup')
        $ruleHelpList = $window.FindName('HDTRuleHelpList')
        $ruleHelpClose = $window.FindName('HDTRuleHelpCloseButton')
        $rulesHelpButton = $window.FindName('HDTRulesHelpButton')
        $bootstrapHelpButton = $window.FindName('HDTBootstrapHelpButton')

        if ($null -ne $ruleHelpList) {
            # ONCE, NOT PER PRESS. The list is derived from a map that cannot
            # change while this window is open, and rebuilding it on every press
            # would lose the reader's scroll position.
            $ruleHelpList.ItemsSource = @((Get-HDTConsoleRuleHelp).Line)
        }

        # WHICH EDITOR A DOUBLE-CLICK WRITES INTO. One panel serves both tabs, so
        # it has to remember which ? opened it - writing a variable into the
        # other tab's box would be worse than not writing it at all.
        $ruleHelpTarget = $null

        $openRuleHelp = {
            param($raiser, $mouse)

            $ruleHelpTarget = $window.FindName('HDTRulesBox')

            if ($null -ne $raiser -and [string] $raiser.Name -eq 'HDTBootstrapHelpButton') {
                $ruleHelpTarget = $window.FindName('HDTBootstrapRulesBox')
            }

            $imageHost.RuleHelpTarget = $ruleHelpTarget

            if ($null -ne $ruleHelpPopup) { $ruleHelpPopup.IsOpen = $true }
        }.GetNewClosure()

        # AND WHAT IT WRITES IS THE ROW'S OWN Insert, decided in
        # Get-HDTConsoleRuleHelp and tested there. This inserts at the caret,
        # replaces a selection if there is one, and closes - somebody clicked a
        # thing to use it, and a panel left open covers the line they changed.
        if ($null -ne $ruleHelpList) {
            $ruleHelpList.Add_MouseDoubleClick({
                    $chosen = $ruleHelpList.SelectedItem

                    if ($null -eq $chosen) { return }
                    if ([string]::IsNullOrEmpty([string] $chosen.Insert)) { return }

                    $box = $imageHost.RuleHelpTarget

                    if ($null -eq $box) { return }

                    $at = [int] $box.SelectionStart
                    $box.SelectedText = [string] $chosen.Insert
                    $box.SelectionStart = $at + ([string] $chosen.Insert).Length
                    $box.SelectionLength = 0

                    if ($null -ne $ruleHelpPopup) { $ruleHelpPopup.IsOpen = $false }

                    [void] $box.Focus()
                }.GetNewClosure())
        }

        # A BORDER, NOT A BUTTON - HDTHelpDot is what every other window in this
        # console uses for a ?, so it takes a mouse event rather than a Click.
        if ($null -ne $rulesHelpButton) { $rulesHelpButton.Add_MouseLeftButtonUp($openRuleHelp) }
        if ($null -ne $bootstrapHelpButton) { $bootstrapHelpButton.Add_MouseLeftButtonUp($openRuleHelp) }

        if ($null -ne $ruleHelpClose) {
            $ruleHelpClose.Add_Click({
                    if ($null -ne $ruleHelpPopup) { $ruleHelpPopup.IsOpen = $false }
                }.GetNewClosure())
        }

        $nameBox = $window.FindName('HDTBootImageNameBox')
        $architectureBox = $window.FindName('HDTBootImageArchitectureBox')
        $languageBox = $window.FindName('HDTBootImageLanguageBox')
        $scratchBox = $window.FindName('HDTBootImageScratchBox')
        $unattendBox = $window.FindName('HDTBootImageUnattendBox')
        $unattendBrowse = $window.FindName('HDTBootImageUnattendBrowseButton')
        $unattendTemplate = $window.FindName('HDTBootImageUnattendTemplateButton')
        $unattendOpen = $window.FindName('HDTBootImageUnattendOpenButton')
        $backgroundBox = $window.FindName('HDTBootImageBackgroundBox')
        $promptForKeyCheck = $window.FindName('HDTBootImagePromptForKeyCheck')

        # THE TEXT COMES OUT OF A FILE, NOT OUT OF THE MARKUP. Every label,
        # hint and button caption on this window is a key in Strings\<culture>.psd1,
        # so a site can translate it or reword it without editing a window - and
        # a string cannot exist twice and drift.
        [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'BootImage'))
        $backgroundBrowse = $window.FindName('HDTBootImageBackgroundBrowseButton')
        $timeZoneBox = $window.FindName('HDTBootImageTimeZoneBox')
        $timeZoneHint = $window.FindName('HDTBootImageTimeZoneHintText')

        $componentList = $window.FindName('HDTComponentList')
        $componentSize = $window.FindName('HDTComponentSizeText')

        $certificateList = $window.FindName('HDTCertificateList')
        $certificateBox = $window.FindName('HDTCertificateBox')
        $certificateSummary = $window.FindName('HDTCertificateSummaryText')
        $certificateBrowse = $window.FindName('HDTCertificateBrowseButton')
        $certificateAdd = $window.FindName('HDTCertificateAddButton')
        $certificateRemove = $window.FindName('HDTCertificateRemoveButton')
        $clientCertificateBox = $window.FindName('HDTClientCertificateBox')
        $clientCertificateBrowse = $window.FindName('HDTClientCertificateBrowseButton')
        $clientCertificatePassword = $window.FindName('HDTClientCertificatePasswordButton')
        $clientCertificateWarning = $window.FindName('HDTClientCertificateWarningText')

        $driverBox = $window.FindName('HDTDriverGroupBox')

        $contentList = $window.FindName('HDTContentList')
        $contentSource = $window.FindName('HDTContentSourceBox')
        $contentBrowse = $window.FindName('HDTContentBrowseButton')
        $contentDestination = $window.FindName('HDTContentDestinationBox')
        $contentAdd = $window.FindName('HDTContentAddButton')
        $contentRemove = $window.FindName('HDTContentRemoveButton')

        $startList = $window.FindName('HDTStartCommandList')
        $startBox = $window.FindName('HDTStartCommandBox')
        $startFirst = $window.FindName('HDTStartCommandFirstCheck')
        $startAdd = $window.FindName('HDTStartCommandAddButton')
        $startRemove = $window.FindName('HDTStartCommandRemoveButton')
        $startUp = $window.FindName('HDTStartCommandUpButton')
        $startDown = $window.FindName('HDTStartCommandDownButton')

        $commandText = $window.FindName('HDTBootImageCommandText')
        $update = $window.FindName('HDTBootImageUpdateButton')
        $save = $window.FindName('HDTBootImageSaveButton')
        $close = $window.FindName('HDTBootImageCloseButton')
        # THE BOOTSTRAP TAB IS THE RULES FILE NOW. The five fields that used to
        # sit above it - share name, deploy root, sign-in account, log level,
        # workspace id - were a second answer to the question the rules below
        # answer, and the account among them is a key the rules may now set.
        # See HDTBootImage.xaml for the whole reasoning.

        # THE RULES TAB - MDT's CustomSettings.ini, in the place MDT put it and
        # as the text MDT made it. It is a SEPARATE FILE from the one this
        # window otherwise edits, so it has its own read, its own Save and its
        # own dirty state; the workspace Save at the bottom does not touch it.
        $rulesBox = $window.FindName('HDTRulesBox')
        $rulesSummaryText = $window.FindName('HDTRulesSummaryText')
        $rulesProblemText = $window.FindName('HDTRulesProblemText')
        $rulesReloadButton = $window.FindName('HDTRulesReloadButton')
        $rulesSaveButton = $window.FindName('HDTRulesSaveButton')

        $rulesPath = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath 'rules.yaml'

        $bootstrapRulesBox = $window.FindName('HDTBootstrapRulesBox')
        $bootstrapRulesSummaryText = $window.FindName('HDTBootstrapRulesSummaryText')
        $bootstrapRulesProblemText = $window.FindName('HDTBootstrapRulesProblemText')
        $bootstrapRulesReloadButton = $window.FindName('HDTBootstrapRulesReloadButton')
        $bootstrapRulesSaveButton = $window.FindName('HDTBootstrapRulesSaveButton')

        # BESIDE workspace.yaml, LIKE rules.yaml. Update-HDTBootImage injects it
        # into the image from here; a share that never writes one behaves as it
        # always did.
        $bootstrapRulesPath = Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath 'bootstrap-rules.yaml'


        $book = [pscustomobject] @{
            Line  = [string[]] @($Line)
            Dirty = $false
            View  = $null
        }

        # THE QUERY, AND ONLY ASSIGNMENT AFTER IT. Every value put on a control
        # below came out of Get-HDTConsoleBootImageSetting; this computes none of them.
        $ask = {
            # WHETHER A PASSWORD EXISTS, NOT WHAT IT IS. The view model takes a
            # boolean on purpose: an object a window binds to must not hold a
            # private key's password.
            $stored = Test-HDTBootImageCertificatePassword `
                -WorkspaceRoot (Split-Path -Path $Path -Parent)

            $book.View = Get-HDTConsoleBootImageSetting -Line $book.Line -Path $Path `
                -Component $Component -DriverGroup $DriverGroup `
                -HasCertificatePassword ([bool] $stored) -TimeZone $TimeZone
            return $book.View
        }

        $fillBoxes = {
            $view = & $ask

            $titleText.Text = [string] $view.Title
            $pathText.Text = [string] $view.DocumentPath

            $nameBox.Text = [string] $view.General.Name
            $languageBox.Text = [string] $view.General.Language
            $unattendBox.Text = [string] $view.General.Unattend
            $backgroundBox.Text = [string] $view.General.Background

            # A CheckBox TAKES A BOOLEAN, and the view model hands one over
            # rather than the string every other field here carries.
            $promptForKeyCheck.IsChecked = [bool] $view.General.PromptForKey
            $clientCertificateBox.Text = [string] $view.ClientCertificate.Path
            $clientCertificateWarning.Text = [string] $view.ClientCertificate.Warning
            $architectureBox.SelectedValue = [string] $view.General.Architecture
            $scratchBox.SelectedValue = [string] $view.General.ScratchSpaceMB

            # THE LIST IS REBUILT EVERY TIME, and the selection is assigned
            # after it: SelectedValue means nothing until the item carrying that
            # value exists. Assigning ItemsSource on a ComboBox raises no event
            # that edits anything, so unlike the component list this is safe to
            # do repeatedly.
            $driverBox.ItemsSource = $view.Driver.Choice
            $driverBox.SelectedValue = [string] $view.Driver.Group

            # SAME ORDER AS THE DRIVER LIST, and for the same reason:
            # SelectedValue means nothing until the item carrying that value
            # exists.
            $timeZoneBox.ItemsSource = $view.TimeZone.Choice
            $timeZoneBox.SelectedValue = [string] $view.TimeZone.Id
            $timeZoneHint.Text = [string] $view.TimeZone.Hint

            $componentSize.Text = [string] $view.SelectedSizeText
            # THE BOOTSTRAP TAB. Every one of these came out of the view model,
            # including the three sentences: this method computes none of them.

            # AFTER THE ITEMS EXIST, like the driver and time zone boxes above -
            # SelectedValue means nothing until an item carries that value. This
            # one's items are in the markup, so they always do.

        }

        # THE TWO LISTS THAT MAY BE REBUILT. Neither carries a control that
        # raises an event when it is created, so reassigning them is safe - it
        # is only the component list's checkboxes that would loop.
        $fillLists = {
            $view = & $ask

            $contentList.ItemsSource = $view.Content
            $startList.ItemsSource = $view.StartCommand
            # THE LIST IS WHAT IS ALREADY TRUSTED and the box below it is what
            # Add would add - two controls, because one doing both hid the
            # result of every press behind a click.
            $certificateList.ItemsSource = $view.Certificate
            $certificateSummary.Text = [string] $view.CertificateSummaryText
            $clientCertificateWarning.Text = [string] $view.ClientCertificate.Warning
            $componentSize.Text = [string] $view.SelectedSizeText
        }

        & $fillBoxes
        & $fillLists

        $componentList.ItemsSource = $book.View.Component

        # -- the Features tab, tick and untick -------------------------------

        $componentList.AddHandler(
            [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
            [System.Windows.RoutedEventHandler] {
                param($raiser, $raised)

                $row = $raised.OriginalSource.DataContext
                if ($null -eq $row) { return }

                # ALREADY THERE MEANS WPF RAISED THIS, NOT A PERSON. See the
                # block comment above: the Features tab's checkboxes are built
                # the first time it is clicked, and each one raises Checked as
                # it takes its bound value. Add-HDTBootImageComponent refuses a
                # duplicate outright, so without this the window dies on the
                # first click of that tab.
                if ($book.View.DeclaredName -contains [string] $row.Name) { return }

                # A LOCKED ROW IS NOT THE DOCUMENT'S TO NAME. The six components
                # the engine applies to every image are shown ticked and cannot
                # be unticked, and the document does not list them - so they pass
                # the test above and would be written into optionalComponents by
                # the very click that first draws them. That is how a share that
                # named nothing ended up naming ten, freezing today's defaults
                # into a file that is meant to inherit tomorrow's.
                if (-not $row.CanChange) { return }

                $book.Line = @(Add-HDTBootImageComponent -Line $book.Line -Name ([string] $row.Name) -Confirm:$false)
                $book.Dirty = $true
                $commandText.Text = [string] $row.AddCommand

                $componentSize.Text = [string] (& $ask).SelectedSizeText
            }.GetNewClosure())

        $componentList.AddHandler(
            [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
            [System.Windows.RoutedEventHandler] {
                param($raiser, $raised)

                $row = $raised.OriginalSource.DataContext
                if ($null -eq $row) { return }

                # NOT THERE MEANS THERE IS NOTHING TO REMOVE - the mirror of the
                # Checked guard, and it also covers the six components the engine
                # applies to every image, which are ticked without the document
                # ever naming them.
                if ($book.View.DeclaredName -notcontains [string] $row.Name) { return }

                $book.Line = @(Remove-HDTBootImageComponent -Line $book.Line -Name ([string] $row.Name) -Confirm:$false)
                $book.Dirty = $true
                $commandText.Text = [string] $row.RemoveCommand

                $componentSize.Text = [string] (& $ask).SelectedSizeText
            }.GetNewClosure())

        # -- the Customisations tab ------------------------------------------

        $contentAdd.Add_Click({
                if ([string]::IsNullOrWhiteSpace($contentSource.Text)) { return }
                if ([string]::IsNullOrWhiteSpace($contentDestination.Text)) { return }

                $book.Line = @(Add-HDTBootImageContent -Line $book.Line `
                        -Source ([string] $contentSource.Text) `
                        -Destination ([string] $contentDestination.Text) -Confirm:$false)
                $book.Dirty = $true

                $commandText.Text = $book.View.AddContentCommandFormat -f
                    [string] $contentSource.Text, [string] $contentDestination.Text

                $contentSource.Text = ''
                $contentDestination.Text = ''

                & $fillLists
            }.GetNewClosure())

        $contentRemove.Add_Click({
                $row = $contentList.SelectedItem
                if ($null -eq $row) { return }

                $book.Line = @(Remove-HDTBootImageContent -Line $book.Line `
                        -Destination ([string] $row.Destination) -Confirm:$false)
                $book.Dirty = $true
                $commandText.Text = [string] $row.RemoveCommand

                & $fillLists
            }.GetNewClosure())

        $startAdd.Add_Click({
                if ([string]::IsNullOrWhiteSpace($startBox.Text)) { return }

                $startSplat = @{
                    Line    = $book.Line
                    Command = [string] $startBox.Text
                    Confirm = $false
                }

                $format = $book.View.AddStartCommandFormat

                if ($startFirst.IsChecked) {
                    $startSplat['First'] = $true
                    $format = $book.View.AddStartCommandFirstFormat
                }

                $book.Line = @(Add-HDTBootImageStartCommand @startSplat)
                $book.Dirty = $true
                $commandText.Text = $format -f [string] $startBox.Text

                $startBox.Text = ''

                & $fillLists
            }.GetNewClosure())

        # THE SELECTION FOLLOWS THE ROW, NOT THE INDEX. A move rebuilds the list
        # from the spliced document, so the object that was selected no longer
        # exists - and reselecting by index would leave the highlight where the
        # row USED to be, which is the one thing that makes an arrow unusable:
        # a second press would move a different row.
        $move = {
            param([string] $Direction)

            $row = $startList.SelectedItem
            if ($null -eq $row) { return }

            $moved = [string] $row.Text

            $book.Line = @(Move-HDTBootImageStartCommand -Line $book.Line `
                    -Command $moved -Direction $Direction -Confirm:$false)
            $book.Dirty = $true
            $commandText.Text = "Move-HDTBootImageStartCommand -Line `$line -Command '{0}' -Direction {1}" -f
                $moved, $Direction

            & $fillLists

            $startList.SelectedItem = @($startList.ItemsSource | Where-Object { $_.Text -eq $moved })[0]
        }

        $startUp.Add_Click({ & $move 'Up' }.GetNewClosure())
        $startDown.Add_Click({ & $move 'Down' }.GetNewClosure())

        $startRemove.Add_Click({
                $row = $startList.SelectedItem
                if ($null -eq $row) { return }

                $book.Line = @(Remove-HDTBootImageStartCommand -Line $book.Line `
                        -Command ([string] $row.Text) -Confirm:$false)
                $book.Dirty = $true
                $commandText.Text = [string] $row.RemoveCommand

                & $fillLists
            }.GetNewClosure())

        # A FILE ON THE SHARE IS NAMED RELATIVE TO IT. A picker hands back
        # C:\HDTLab\Share\Certs\ca.cer, and storing that in workspace.yaml puts
        # ONE BUILD HOST'S DRIVE LETTER in a document every build host reads -
        # the same rule New-HDTBootImageUnattend states for the answer file.
        # A file kept elsewhere stays rooted, because it is elsewhere.
        $relativeToShare = {
            param([string] $Chosen)

            $root = [string] $book.View.WorkspaceRoot
            if ([string]::IsNullOrWhiteSpace($root)) { return $Chosen }

            $prefix = $root.TrimEnd('\') + '\'
            if (-not $Chosen.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $Chosen }

            return $Chosen.Substring($prefix.Length)
        }.GetNewClosure()

        # -- the Certificates tab --------------------------------------------
        #
        # THE TOP HALF EDITS THE DOCUMENT AS IT IS PRESSED, like the content and
        # start command lists, because it is a list. The bottom half is one
        # value and is read at Save, like the answer file and the background.

        $certificateAdd.Add_Click({
                $typed = [string] $certificateBox.Text
                if ([string]::IsNullOrWhiteSpace($typed)) { return }

                try {
                    $book.Line = @(Add-HDTBootImageCertificate -Line $book.Line -Path $typed -Confirm:$false)
                    $book.Dirty = $true
                    $commandText.Text = $book.View.AddCertificateCommandFormat -f $typed
                    $certificateBox.Text = ''

                    & $fillLists
                } catch {
                    # THE REFUSAL IS THE ANSWER. A .pfx in this list, or the same
                    # certificate twice, is refused by the command with a
                    # sentence saying why - and that sentence is better than
                    # anything this window could invent.
                    $commandText.Text = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        $certificateRemove.Add_Click({
                # THE ROW SELECTED IN THE LIST, not the text in the box below it:
                # the box holds what is being added, which is a different
                # question from what is being taken away.
                $row = $certificateList.SelectedItem
                if ($null -eq $row) { return }

                $book.Line = @(Remove-HDTBootImageCertificate -Line $book.Line `
                        -Path ([string] $row.Path) -Confirm:$false)
                $book.Dirty = $true
                $commandText.Text = [string] $row.RemoveCommand

                & $fillLists
            }.GetNewClosure())

        # THE PASSWORD IS WRITTEN THE MOMENT IT IS TYPED, and not at Save, and
        # that is deliberate: it goes to a different file from everything else
        # on this window - Control\certificate-password.json, not workspace.yaml -
        # so Save has nothing to do with it and holding it until then would mean
        # holding a password in a window's memory for as long as it is open.
        $clientCertificatePassword.Add_Click({
                Add-Type -AssemblyName PresentationFramework

                # A .pfx PASSWORD IS TYPED, NOT BROWSED TO. There is no file
                # picker for it and no command that can discover it; the box is
                # a PasswordBox on a small dialog because that is the only
                # control in WPF that does not put it on screen.
                $prompt = New-Object -TypeName System.Windows.Window
                $prompt.Icon = & $call 'Get-HDTConsoleWindowIcon'
                $prompt.Title = 'Certificate password'
                $prompt.Width = 420
                $prompt.SizeToContent = [System.Windows.SizeToContent]::Height
                $prompt.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
                $prompt.Owner = $window
                $prompt.ResizeMode = [System.Windows.ResizeMode]::NoResize

                $panel = New-Object -TypeName System.Windows.Controls.StackPanel
                $panel.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 16

                $label = New-Object -TypeName System.Windows.Controls.TextBlock
                $label.Text = 'The password the .pfx was exported with. It is stored obfuscated, not encrypted - the boot image carries enough to reverse it.'
                $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $label.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 0, 0, 0, 10

                $entry = New-Object -TypeName System.Windows.Controls.PasswordBox
                $entry.Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 0, 0, 0, 12

                $accept = New-Object -TypeName System.Windows.Controls.Button
                $accept.Content = 'Store'
                $accept.IsDefault = $true
                $accept.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
                $accept.Padding = New-Object -TypeName System.Windows.Thickness -ArgumentList 14, 6, 14, 6
                $accept.Add_Click({ $prompt.DialogResult = $true }.GetNewClosure())

                [void] $panel.Children.Add($label)
                [void] $panel.Children.Add($entry)
                [void] $panel.Children.Add($accept)

                $prompt.Content = $panel
                $entry.Focus()

                if ($prompt.ShowDialog() -ne $true) { return }

                $root = [string] $book.View.WorkspaceRoot

                try {
                    Set-HDTBootImageCertificatePassword -WorkspaceRoot $root `
                        -Password $entry.SecurePassword -Confirm:$false

                    $commandText.Text = $book.View.ClientCertificate.PasswordCommandFormat -f $root
                } catch {
                    $commandText.Text = [string] $_.Exception.Message
                }

                # THE WARNING GOES AWAY BECAUSE THE FACT CHANGED, and it is
                # re-asked rather than cleared: this window does not decide
                # whether a password exists, the Control folder does.
                & $fillLists
            }.GetNewClosure())

        # -- Browse, which fills a box and nothing else ----------------------
        #
        # THE FILE PICKER IS NOT A DECISION, it is a keyboard. Neither of these
        # edits the document; they put a path in a box that another press acts
        # on, which is why an untested adapter is allowed to own them.

        $unattendBrowse.Add_Click({
                $dialog = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $dialog.Title = 'Choose the WinPE answer file'
                $dialog.Filter = 'Answer files (*.xml)|*.xml|All files (*.*)|*.*'

                if ($dialog.ShowDialog($window)) { $unattendBox.Text = $dialog.FileName }
            }.GetNewClosure())

        # -- the answer file itself, written and opened ----------------------
        #
        # BROWSE ASSUMES THE FILE EXISTS. On a share that never had one there is
        # nothing to browse to, and what an administrator has to do instead is
        # write a windowsPE document from Microsoft's schema by hand. This puts
        # the one the module ships on the share and names it in the box; Save is
        # still what writes workspace.yaml.
        #
        # A FILE ALREADY THERE IS NAMED, NOT REPLACED. New-HDTBootImageUnattend
        # refuses it, and the refusal is the right answer to show - somebody's
        # firewall setting may be in that file - but the name still belongs in
        # the box, which is what the press meant.
        $unattendTemplate.Add_Click({
                $root = [string] $book.View.WorkspaceRoot

                try {
                    $made = New-HDTBootImageUnattend -Workspace $root -Confirm:$false
                    $unattendBox.Text = [string] $made.Relative
                    $commandText.Text = $book.View.General.UnattendTemplateCommandFormat -f $root
                } catch {
                    $unattendBox.Text = 'Unattend-PE.xml'
                    $commandText.Text = [string] $_.Exception.Message
                }
            }.GetNewClosure())

        # OPEN, BECAUSE EVERYTHING ELSE wpeinit READS IS EDITED IN THAT FILE.
        # EnableFirewall, EnableNetwork, LogPath, PageFile and Restart have no
        # page here and should not: they are wpeinit's list, not HDT's.
        #
        # RELATIVE IS READ FROM THE SHARE, ROOTED IS TAKEN AS WRITTEN, which is
        # Update-HDTBootImage's rule for this same value - and the box, not the
        # document, because the box is what a press a moment ago changed.
        $unattendOpen.Add_Click({
                $typed = [string] $unattendBox.Text
                if ([string]::IsNullOrWhiteSpace($typed)) { return }

                $target = $typed
                if (-not [System.IO.Path]::IsPathRooted($typed)) {
                    $target = [System.IO.Path]::Combine([string] $book.View.WorkspaceRoot, $typed)
                }

                if (-not (Test-Path -LiteralPath $target)) {
                    $commandText.Text = "there is no answer file at '{0}'. Use template writes one." -f $target
                    return
                }

                # NOTEPAD, NOT THE SHELL'S ASSOCIATION. Launching the file was
                # tried first and this build host opens .xml in Edge - a page
                # you can read and cannot change, which is the one thing this
                # button is for. The association for .xml is a browser on most
                # machines that have ever opened an RSS feed; notepad is on
                # every one of them and it edits.
                [void] (Start-Process -FilePath 'notepad.exe' -ArgumentList $target)
            }.GetNewClosure())

        # FILTERED BY WHAT EACH HALF OF THAT TAB ACCEPTS, which is the one place
        # a file picker can stop the mistake the page is most likely to see: a
        # .pfx in the trusted-root list, or a .cer as the machine's identity.
        # Both commands refuse it too; the dialog tries not to offer it.
        # BROWSE ADDS WHAT IT PICKS, and takes more than one file. This row is a
        # LIST behind a single box, so a Browse that only filled the box meant
        # browsing twice replaced the first answer with the second - and a chain
        # is a root AND a subordinate, which is two files nearly every time.
        #
        # THE TYPED PATH STILL NEEDS Add. A path spelled by hand is the other way
        # into this row and the button that commits it has not moved.
        $certificateBrowse.Add_Click({
                $dialog = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $dialog.Title = 'Choose the certificate authorities to trust'
                $dialog.Filter = 'Certificates (*.cer;*.crt;*.der)|*.cer;*.crt;*.der|All files (*.*)|*.*'
                $dialog.Multiselect = $true

                if (-not $dialog.ShowDialog($window)) { return }

                $ran = New-Object -TypeName System.Collections.ArrayList

                foreach ($chosen in @($dialog.FileNames)) {
                    $named = & $relativeToShare ([string] $chosen)

                    try {
                        $book.Line = @(Add-HDTBootImageCertificate -Line $book.Line -Path $named -Confirm:$false)
                        $book.Dirty = $true
                        [void] $ran.Add($book.View.AddCertificateCommandFormat -f $named)
                    } catch {
                        [void] $ran.Add([string] $_.Exception.Message)
                    }
                }

                $commandText.Text = (@($ran) -join [System.Environment]::NewLine)
                & $fillLists
            }.GetNewClosure())

        $clientCertificateBrowse.Add_Click({
                $dialog = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $dialog.Title = "Choose this machine's certificate"
                $dialog.Filter = 'Certificates with a private key (*.pfx)|*.pfx'

                # ONE FILE AND ONE BOX, so this half fills the box as before -
                # Save is what writes it, like the answer file and the background.
                if ($dialog.ShowDialog($window)) {
                    $clientCertificateBox.Text = & $relativeToShare ([string] $dialog.FileName)
                }
            }.GetNewClosure())

        # FILTERED TO JPEG, because WinPE reads \Windows\System32\winpe.jpg and
        # nothing else. Set-HDTBootImageBackground refuses any other format; the
        # dialog's job is to not offer one in the first place.
        $backgroundBrowse.Add_Click({
                $dialog = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $dialog.Title = 'Choose the WinPE background'
                $dialog.Filter = 'JPEG images (*.jpg;*.jpeg)|*.jpg;*.jpeg'

                if ($dialog.ShowDialog($window)) { $backgroundBox.Text = $dialog.FileName }
            }.GetNewClosure())

        # A FOLDER, NOT A FILE, because extraContent's commonest source is a
        # tool's whole directory - BGInfo, a VNC server - and a file picker
        # cannot return one.
        #
        # SHELL COM RATHER THAN System.Windows.Forms.FolderBrowserDialog, and a
        # contract test is what says so: System.Windows.Forms is not guaranteed
        # by WinPE-NetFx, so a reference to it anywhere in this module is a
        # window that works on a developer machine and fails in WinPE. This
        # window never runs there - but the rule is file-blind on purpose, and
        # arguing the exception is how the next one gets written into a file
        # that does.
        $contentBrowse.Add_Click({
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.BrowseForFolder(0, 'Choose the folder to copy into the boot image', 0)

                if ($null -ne $folder) { $contentSource.Text = [string] $folder.Self.Path }
            }.GetNewClosure())

        # -- Save, which is where the General and Drivers boxes are read -----
        #
        # THOSE TWO TABS HAVE NO APPLY. Every tab edits the same in-memory
        # document and Save writes it, which is where MDT's properties dialog
        # puts Apply too.
        #
        # AN EMPTY BOX IS A CLEAR, and that is the one decision here. The
        # alternative was a Clear button beside a box you can already empty -
        # two ways to do one thing, which disagree the first time somebody
        # empties the box and presses Save expecting Clear's behaviour.

        # -- the two rule editors ------------------------------------------
        #
        # ONE EDITOR, WIRED TWICE. rules.yaml on the Rules tab and
        # bootstrap-rules.yaml on the Bootstrap tab are the same grammar in the
        # same control; the only difference is the vocabulary
        # Get-HDTConsoleRuleSetting judges them by. Two copies of this would be
        # one copy to get wrong, and the one that rots is always the second.
        #
        # NEITHER IS PART OF THE WORKSPACE Save. They are their own files, saved
        # by their own buttons, so an administrator who edits rules and presses
        # the wrong Save has lost nothing.
        #
        # THE PARAMETERS ARE WHAT THE CLOSURES CAPTURE. GetNewClosure copies by
        # VALUE at the moment the handler is made, and these are locals of this
        # invocation - which is exactly why the two tabs cannot end up sharing a
        # control or a path.
        $wireRuleTab = {
            param($Box, $Summary, $Problem, $Save, $Reload, $RulePath, $IsBootstrap)

            # ITS OWN DOOR, BECAUSE GetNewClosure CAPTURES THE LOCAL SCOPE ONLY.
            # The $call declared in ShowBootImage is a parent scope from in here:
            # this block can read it, but the handlers made below cannot capture
            # it, and a keystroke in the rules box would find nothing behind the
            # & - which is the boot image window refusing to open at all.
            $call = Get-HDTHandlerCall

            # WHAT THE ENGINE WOULD SAY, SAID NOW. Assert-HDTRuleLine is the gate
            # Add-HDTRule passes through and, for the bootstrap file, the one
            # Update-HDTBootImage will apply when it injects it - so a document
            # that would fail at three in the morning fails here, at the desk.
            $judge = {
                $typed = @([string] $Box.Text -split "`r?`n")
                $judged = & $call 'Get-HDTConsoleRuleSetting' @{ Line = $typed; Path = $RulePath; Bootstrap = [bool] $IsBootstrap }

                $Summary.Text = [string] $judged.SummaryText
                $Problem.Text = [string] $judged.Problem

                if ([string]::IsNullOrWhiteSpace([string] $judged.Problem)) {
                    $Problem.Visibility = [System.Windows.Visibility]::Collapsed
                } else {
                    $Problem.Visibility = [System.Windows.Visibility]::Visible
                }

                $Save.IsEnabled = [bool] $judged.IsValid
            }.GetNewClosure()

            $fill = {
                $fileSystem = New-HDTFileSystem

                $ruleLine = @()
                if ($fileSystem.TestPath($RulePath)) {
                    $ruleLine = @([string] $fileSystem.ReadAllText($RulePath) -split "`r?`n")
                }

                $Box.Text = [string] (& $call 'Get-HDTConsoleRuleSetting' @{ Line = $ruleLine; Path = $RulePath; Bootstrap = [bool] $IsBootstrap }).Text
            }.GetNewClosure()

            $Box.Add_TextChanged({ & $judge }.GetNewClosure())

            $Reload.Add_Click({
                    & $fill
                    & $judge
                }.GetNewClosure())

            $Save.Add_Click({
                    $typed = @([string] $Box.Text -split "`r?`n")
                    $judged = & $call 'Get-HDTConsoleRuleSetting' @{ Line = $typed; Path = $RulePath; Bootstrap = [bool] $IsBootstrap }

                    # BELT AND BRACES. The button is dark while the document will
                    # not do, but a keyboard default or an automation could still
                    # reach this, and a corrupt rules file on the share is a
                    # deployment that fails on a bench at midnight.
                    if (-not $judged.IsValid) {
                        & $judge
                        return
                    }

                    [void] (Save-HDTRuleDocument -Path $RulePath -Line $typed `
                            -FileSystem (New-HDTFileSystem) -Confirm:$false)

                    & $fill
                    & $judge

                    $commandText.Text = [string] $judged.SaveCommand
                }.GetNewClosure())

            return [pscustomobject] @{ Fill = $fill; Judge = $judge }
        }

        $rulesTab = & $wireRuleTab $rulesBox $rulesSummaryText $rulesProblemText `
            $rulesSaveButton $rulesReloadButton $rulesPath $false

        $bootstrapRulesTab = & $wireRuleTab $bootstrapRulesBox $bootstrapRulesSummaryText `
            $bootstrapRulesProblemText $bootstrapRulesSaveButton $bootstrapRulesReloadButton `
            $bootstrapRulesPath $true

        # FILLED NOW, not with the boxes three hundred lines above: these
        # scriptblocks are made here, and one called before it is assigned is
        # $null under StrictMode.
        & $rulesTab.Fill
        & $rulesTab.Judge
        & $bootstrapRulesTab.Fill
        & $bootstrapRulesTab.Judge

        # -- Save, which writes workspace.yaml and nothing else --------------
        #
        # THE SHARE CREDENTIAL IS NOT HERE, and no control on this window sets
        # it. Setting it writes two things - credential.username into
        # workspace.yaml and a protected secret into
        # Control\share-credential.json - and a box writing one would leave a
        # share declaring an account no secret exists for, which is a build that
        # refuses. Set-HDTShareCredential does both halves.
        #
        $save.Add_Click({
                # WHAT THIS PRESS WRITES, decided away from the window.
                # Fourteen branches used to live in this handler - "an empty
                # property box is a question nobody answered, an empty document
                # box is an instruction to clear the key" - and none of them
                # could be tested from here.
                # tests/unit/ConsoleBootImageEdit.Tests.ps1 covers them now.
                $edit = & $call 'Get-HDTConsoleBootImageEdit' `
                    -BootImageName ([string] $nameBox.Text) `
                    -Architecture ([string] $architectureBox.SelectedValue) `
                    -Language ([string] $languageBox.Text) `
                    -ScratchSpaceMB ([string] $scratchBox.SelectedValue) `
                    -PromptForKey ([bool] $promptForKeyCheck.IsChecked) `
                    -Unattend ([string] $unattendBox.Text) `
                    -Background ([string] $backgroundBox.Text) `
                    -TimeZone ([string] $timeZoneBox.SelectedValue) `
                    -ClientCertificate ([string] $clientCertificateBox.Text) `
                    -Driver ([string] $driverBox.SelectedValue)

                $propertySplat = @{ Line = $book.Line; Confirm = $false }
                foreach ($key in @($edit.Property.Keys)) { $propertySplat[$key] = $edit.Property[$key] }

                $book.Line = @(Set-HDTWorkspaceProperty @propertySplat)

                # THE PARAMETER TRAVELS WITH THE VALUE, because three of these
                # commands take -Path and two take -Name.
                foreach ($one in @($edit.Edit)) {
                    if ($one.Clear) {
                        $book.Line = @(& $one.Command -Line $book.Line -Clear -Confirm:$false)
                        continue
                    }

                    $valueSplat = @{ $one.Parameter = $one.Value }
                    $book.Line = @(& $one.Command -Line $book.Line @valueSplat -Confirm:$false)
                }

                [void] (Save-HDTWorkspaceDocument -Path $Path -Line $book.Line `
                        -FileSystem (New-HDTFileSystem) -Confirm:$false)

                $book.Dirty = $false

                & $fillBoxes
                & $fillLists

                # EVERY COMMAND SAVE RAN, NOT JUST THE LAST ONE. One press is
                # seven invocations, and echoing only the write hid the six that
                # decided what was written - which is exactly the surface
                # DESIGN 12 says this box exists to teach. Composed from the
                # REFRESHED view, so what it shows is what the file now says
                # rather than what was typed at it; saving normalises, and the
                # two can legitimately disagree.
                #
                # tests/unit/ConsoleBootImageSaveCommand.Tests.ps1 holds the
                # fourteen branches this used to make here.
                $ran = @(& $call 'Get-HDTConsoleBootImageSaveCommand' -View $book.View -Path $Path)

                $commandText.Text = ($ran -join [System.Environment]::NewLine)
            }.GetNewClosure())

        # -- Update, which is minutes rather than milliseconds ---------------
        #
        # IT SAVES FIRST. Update-HDTBootImage reads workspace.yaml from disk, so
        # building without saving would build the image the file describes and
        # not the one on the screen - the worst possible outcome, because it
        # succeeds.
        #
        # AND IT HANDS OVER TO A PROGRESS WINDOW rather than running here. An
        # earlier version ran the build on the dispatcher: this window greyed
        # out for two and a half minutes, which reads as one that has hung, and
        # a killed build strands a mounted image that needs dism /cleanup-wim.
        # ShowBuildProgress runs it in its own runspace and shows every step.

        $update.Add_Click({
                $save.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                            -ArgumentList ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))

                $root = Split-Path -Parent $Path
                $commandText.Text = "Update-HDTBootImage -WorkspaceRoot '{0}'" -f $root

                [void] (Show-HDTBuildProgressWindow -WorkspaceRoot $root -ConsoleHost $imageHost `
                        -Screen (New-HDTConsoleScreen))

                # The build wrote a manifest and possibly a warning; what this
                # window shows came out of the document, which the build did not
                # touch. Re-asking costs nothing and keeps the two honest.
                & $fillBoxes
                & $fillLists
            }.GetNewClosure())

        $close.Add_Click({
                $imageHost.Answer = 'Close'
                $window.Close()
            }.GetNewClosure())

        # THE WAY OUT ASKS FIRST, WHICHEVER WAY OUT IT IS - the title-bar X
        # never runs a button's handler, which is how the editor came to discard
        # every splice in silence. Both windows ask the same command what to
        # say and what the answer means.
        $window.Add_Closing({
                param($closingWindow, $closing)

                $prompt = & $call 'Get-HDTConsoleClosePrompt' @{ DocumentPath = $Path; Dirty = [bool] $book.Dirty }

                if (-not $prompt.Ask) { return }

                $answer = [System.Windows.MessageBox]::Show($window, $prompt.Message, $prompt.Title,
                    ([System.Windows.MessageBoxButton] $prompt.Button),
                    ([System.Windows.MessageBoxImage] $prompt.Icon))

                $decision = & $call 'Resolve-HDTConsoleCloseAnswer' -Answer ([string] $answer)

                if ($decision.Cancel) {
                    $closing.Cancel = $true
                    return
                }

                if ($decision.Save) {
                    [void] (Save-HDTWorkspaceDocument -Path $Path -Line $book.Line `
                            -FileSystem (New-HDTFileSystem) -Confirm:$false)
                    $book.Dirty = $false
                }
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # =====================================================================
    # THE BUILD PROGRESS WINDOW
    # =====================================================================
    #
    # Update-HDTBootImage IS SEVENTEEN STEPS AND ABOUT TWO AND A HALF MINUTES,
    # and it used to run on the dispatcher: the window that started it greyed
    # out for the whole build. That reads as a window which has hung, so it gets
    # killed - and a killed build leaves a MOUNTED IMAGE behind that needs
    # dism /cleanup-wim before anything can build again. The freeze was not a
    # cosmetic problem; it was a way to break the lab.
    #
    # THE QUEUE CROSSES THE THREAD BOUNDARY, NOT THE SINK. A PSCustomObject's
    # ScriptMethods are scriptblocks bound to the runspace that created them,
    # so handing the sink to the build's runspace would be asking one runspace
    # to invoke another's code. The sink is CREATED INSIDE the build runspace
    # instead, around a synchronized Queue made here - so the only thing shared
    # is a thread-safe collection, which is what one is for.
    #
    # THE TIMER OWNS THE UI AND THE RUNSPACE OWNS THE BUILD. Nothing on the
    # dispatcher waits on the build, so the window stays responsive whatever the
    # build is doing - including hanging.

    $service | Add-Member -MemberType ScriptMethod -Name ShowBuildProgress -Value {
        param(
            [string] $Xaml, [string] $WorkspaceRoot, [string] $ModulePath,
            [object] $Theme, [object] $Size
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Icon = Get-HDTConsoleWindowIcon

        # The text comes out of Strings\<culture>.psd1, not out of the markup,
        # and before the first report replaces the starting step.
        [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'BuildProgress'))

        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top
        $window.Owner = $this.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $titleText = $window.FindName('HDTBuildTitleText')
        $pathText = $window.FindName('HDTBuildPathText')
        $stepText = $window.FindName('HDTBuildStepText')
        $detailText = $window.FindName('HDTBuildDetailText')
        $countText = $window.FindName('HDTBuildCountText')
        $elapsedText = $window.FindName('HDTBuildElapsedText')
        $bar = $window.FindName('HDTBuildBar')
        $log = $window.FindName('HDTBuildLog')
        $close = $window.FindName('HDTBuildCloseButton')

        $titleText.Text = 'Updating Boot Image'
        $pathText.Text = $WorkspaceRoot

        $line = New-Object -TypeName System.Collections.ObjectModel.ObservableCollection[string]
        $log.ItemsSource = $line

        $queue = [System.Collections.Queue]::Synchronized((New-Object -TypeName System.Collections.Queue))

        # THE BUILD, IN ITS OWN RUNSPACE. The module is imported by path rather
        # than by name: a console started from a working copy is not running the
        # module that Import-Module Hephaestus would find.
        $shell = [powershell]::Create()

        [void] $shell.AddScript({
                param($ModulePath, $WorkspaceRoot, $Queue)

                Import-Module -Name $ModulePath -Force -ErrorAction Stop

                # CREATED HERE, on this side of the boundary. See the block
                # comment above: a sink made in the window's runspace would carry
                # scriptblocks this one cannot invoke.
                $progress = New-HDTBuildProgress -Queue $Queue

                Update-HDTBootImage -WorkspaceRoot $WorkspaceRoot -Progress $progress -Confirm:$false
            })

        [void] $shell.AddArgument($ModulePath)
        [void] $shell.AddArgument($WorkspaceRoot)
        [void] $shell.AddArgument($queue)

        $handle = $shell.BeginInvoke()
        $startedAt = [datetime]::UtcNow

        $book = [pscustomobject] @{
            Finished  = $false
            Succeeded = $false

            # WHEN THE CURRENT STEP STARTED. Mount and commit are ONE DISM call
            # each - the adapter gets no sub-progress to pass on - so the only
            # honest way to show that a ninety-second step is working is to say
            # how long it has been working. A line that changes every second is
            # not stuck; a line that does not is indistinguishable from one.
            StepAt    = [datetime]::UtcNow
            StepText  = ''
        }

        $timer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)

        $drain = {
                $elapsed = [datetime]::UtcNow - $startedAt

                if (-not $book.Finished) {
                    # BOTH CLOCKS, because they answer different questions: the
                    # total says how long to wait, and the per-step says whether
                    # anything is happening at all.
                    $onStep = [datetime]::UtcNow - $book.StepAt

                    $elapsedText.Text = 'elapsed {0:mm\:ss}   -   {1:N0}s on "{2}"' -f
                        $elapsed, $onStep.TotalSeconds, $book.StepText
                }

                # DEQUEUED DIRECTLY, not through the sink: the sink belongs to
                # the other runspace, and the queue is the only thing shared.
                while ($queue.Count -gt 0) {
                    $report = $queue.Dequeue()

                    if ($report.IsComplete) {
                        $book.Finished = $true
                        $book.Succeeded = [bool] $report.Succeeded

                        $stepText.Text = 'Finished'
                        $bar.Value = $bar.Maximum

                        if ($report.Succeeded) {
                            $detailText.Text = [string] $report.Detail
                            [void] $line.Add(('{0:mm\:ss}  done - {1}' -f $elapsed, $report.Detail))
                        } else {
                            $stepText.Text = 'Failed'
                            $stepText.Foreground = $window.Resources['HDTErrorBrush']
                            $detailText.Text = [string] $report.Detail
                            [void] $line.Add(('{0:mm\:ss}  FAILED - {1}' -f $elapsed, $report.Detail))
                        }

                        $elapsedText.Text = 'took {0:mm\:ss}' -f $elapsed
                        $close.IsEnabled = $true
                        continue
                    }

                    $stepText.Text = [string] $report.Title
                    $detailText.Text = [string] $report.Detail
                    $countText.Text = 'step {0} of {1}' -f $report.Step, $report.Total
                    $bar.Maximum = [double] $report.Total
                    $bar.Value = [double] $report.Step

                    # THE PER-STEP CLOCK RESTARTS ON A NEW STEP NUMBER, not on
                    # every report: step 8 reports once per component, and a
                    # clock reset by each of those would never show that the
                    # step as a whole has been running for a minute.
                    if ($book.StepText -ne [string] $report.Title) {
                        $book.StepAt = [datetime]::UtcNow
                        $book.StepText = [string] $report.Title
                    }

                    # THE PARENTHESES AROUND EVERY -f IN THIS METHOD ARE
                    # LOAD-BEARING, and the reason is the comma. Inside a .NET
                    # method call, a comma separates ARGUMENTS - so
                    #
                    #     $line.Add('{0} {1}' -f $a, $b)
                    #
                    # parses as Add(('{0} {1}' -f $a), $b): the format string
                    # gets one argument, {1} has nothing to fill it, and it
                    # throws "Index (zero based) must be greater than or equal
                    # to zero and less than the size of the argument list".
                    #
                    # It parses cleanly, it reads correctly, and it throws at
                    # run time only - which killed this window at its first
                    # report, and again at its last.
                    # THE DETAIL IS ON THE LOG LINE, NOT ONLY IN THE LABEL.
                    # Step 8 reports once per cab, and a line carrying the title
                    # alone printed "Applying the optional components" nineteen
                    # times - which says the build is moving and refuses to say
                    # what it is moving through. The name of the cab is the
                    # whole value of reporting per component, and it is also
                    # what tells somebody WHICH one was being applied if the
                    # build dies inside that step.
                    $row = '{0:mm\:ss}  {1,2}/{2}  {3}' -f
                        $elapsed, $report.Step, $report.Total, $report.Title

                    if (-not [string]::IsNullOrWhiteSpace([string] $report.Detail)) {
                        $row = '{0}  -  {1}' -f $row, [string] $report.Detail
                    }

                    [void] $line.Add($row)

                    # The newest line is the one being looked at.
                    $log.ScrollIntoView($line[$line.Count - 1])
                }

                if (-not $handle.IsCompleted) { return }

                # DRAINED ONE LAST TIME, AND THAT IS NOT BELT AND BRACES. The
                # completion report is enqueued by the build a moment before its
                # runspace finishes, so a tick that drains and THEN sees
                # IsCompleted has already missed it - and the window below would
                # declare a successful build "ended without saying why". It
                # happened on the first real run.
                while ($queue.Count -gt 0) {
                    $final = $queue.Dequeue()

                    if (-not $final.IsComplete) { continue }

                    $book.Finished = $true
                    $book.Succeeded = [bool] $final.Succeeded

                    $stepText.Text = 'Finished'
                    $bar.Value = $bar.Maximum
                    $detailText.Text = [string] $final.Detail

                    if ($final.Succeeded) {
                        [void] $line.Add(('{0:mm\:ss}  done - {1}' -f $elapsed, $final.Detail))
                    } else {
                        $stepText.Text = 'Failed'
                        $stepText.Foreground = $window.Resources['HDTErrorBrush']
                        [void] $line.Add(('{0:mm\:ss}  FAILED - {1}' -f $elapsed, $final.Detail))
                    }

                    $elapsedText.Text = 'took {0:mm\:ss}' -f $elapsed
                    $close.IsEnabled = $true
                }

                $timer.Stop()

                # A BUILD THAT DIED WITHOUT REPORTING. Update-HDTBootImage
                # reports its own failure, but a runspace can also fail before
                # the command runs at all - a module that will not import, for
                # instance - and that error exists only in this stream.
                if (-not $book.Finished) {
                    $failure = 'the build ended without saying why'

                    # EndInvoke IS WHAT RAISES THE RUNSPACE'S TERMINATING ERROR.
                    # A build that threw outside its own try - the ISO step is
                    # outside it - reports nothing and leaves Streams.Error
                    # empty, and the window then said "ended without saying why"
                    # about a failure PowerShell was holding all along.
                    try {
                        [void] $shell.EndInvoke($handle)
                    } catch {
                        $failure = [string] $_.Exception.Message
                    }

                    if ($failure -eq 'the build ended without saying why' -and
                        @($shell.Streams.Error).Count -gt 0) {

                        $failure = [string] $shell.Streams.Error[0].Exception.Message
                    }

                    $stepText.Text = 'Failed'
                    $stepText.Foreground = $window.Resources['HDTErrorBrush']
                    $detailText.Text = $failure
                    [void] $line.Add(('{0:mm\:ss}  FAILED - {1}' -f $elapsed, $failure))

                    $book.Finished = $true
                    $close.IsEnabled = $true
                }

                $shell.Dispose()
        }

        # A TICK THAT THROWS TAKES THE DIALOG WITH IT. An exception out of a
        # DispatcherTimer handler unwinds through ShowDialog, so a mistake in
        # the drain above does not produce a wrong label - it produces a window
        # that vanishes mid-build with the runspace still holding a mount. The
        # handler says what went wrong ON THE WINDOW and stops ticking, which
        # leaves the build running and visibly reported rather than gone.
        $timer.Add_Tick({
                try {
                    & $drain
                } catch {
                    [void] $line.Add(('the progress window itself failed at line {0}: {1} | {2}' -f
                            $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message,
                            ([string] $_.InvocationInfo.Line).Trim()))
                    $stepText.Text = 'The build is still running - this window stopped following it'
                    $book.Finished = $true
                    $close.IsEnabled = $true
                    $timer.Stop()
                }
            }.GetNewClosure())

        $timer.Start()

        $close.Add_Click({ $window.Close() }.GetNewClosure())

        # CLOSING IS REFUSED WHILE IT BUILDS, and the X is refused with it - a
        # window that let itself be closed over a running mount would leave the
        # runspace holding it with nothing on screen to say so.
        $window.Add_Closing({
                param($closingWindow, $closing)

                if (-not $book.Finished) { $closing.Cancel = $true }
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [bool] $book.Succeeded
    }

    return $service
}
