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
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Show is where a window appears, and it is a method.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'ThemeName is read inside an Add_MouseDoubleClick handler built with GetNewClosure(); the analyzer does not follow a captured variable into a closure and reports it unused.')]
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
            [string] $ThemeName = 'Light', [int] $RefreshSecond = 10, [string] $NewSequenceXaml = '')

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

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
            }.GetNewClosure())

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
                    [void] (Show-HDTBootImageWindow -Path ([string] $selected.Subject) -Theme $ThemeName `
                            -ConsoleHost $consoleHost `
                            -OwnerWidth ([int] $window.ActualWidth) -OwnerHeight ([int] $window.ActualHeight))
                    return
                }

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
                [void] (Show-HDTSequenceEditor -Sequence $selected.Subject -Theme $ThemeName `
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
                # THE TREE, NOT THE COLLECTION THIS METHOD WAS HANDED. Creating
                # a task sequence rebuilds the rows, and a timer still holding
                # the originals refreshes rows that are no longer on screen.
                foreach ($root in @($tree.ItemsSource)) {
                    foreach ($share in @($root.Children)) {
                        $at = -1

                        for ($i = 0; $i -lt $share.Children.Count; $i++) {
                            if ($share.Children[$i].Kind -eq 'MonitorCategory') { $at = $i }
                        }

                        if ($at -lt 0) { continue }

                        $share.Children[$at] = Get-HDTConsoleMonitorNode `
                            -Path $share.Children[$at].HeaderRoot `
                            -Header ([pscustomobject] @{
                                Title      = $share.Children[$at].HeaderTitle
                                Root       = $share.Children[$at].HeaderRoot
                                DeployRoot = $share.Children[$at].HeaderDeployRoot
                            })
                    }
                }
            }.GetNewClosure())

        # Selecting the root raises SelectedItemChanged, which is what fills the
        # two panes and the banner; the window is never shown blank.
        $window.Add_ContentRendered({
                $first = $tree.ItemContainerGenerator.ContainerFromIndex(0)
                $first.IsSelected = $true

                $refresh.Start()
            }.GetNewClosure())

        # A timer left running holds a reference to a window that has gone.
        $window.Add_Closed({ $refresh.Stop() }.GetNewClosure())

        # MDT'S New Task Sequence. It creates into the share the tree is showing
        # - the selected row carries its own root, and two shares in one window
        # commonly hold sequences with the same id, so "the selected one" is the
        # only answer that cannot write to the wrong share.
        #
        # NO MARKUP, NO BUTTON. A button that cannot open its window is one a
        # technician presses to find out nothing happens.
        $newSequence = $window.FindName('HDTNewSequenceMenuItem')

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

                        $wanted = ($null -ne $chosen -and
                            [string] $chosen.Kind -eq 'Category' -and
                            [string] $chosen.Name -eq 'TaskSequences')

                        if (-not $wanted) { $opening.Handled = $true }
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
                        #
                        # THE SAME TWO CALLS Show-HDTConsole MAKES, over the
                        # same roots: a share is read and its rows are built.
                        $shareRoot = New-Object -TypeName System.Collections.ArrayList

                        foreach ($root in @($tree.ItemsSource)) {
                            foreach ($share in @($root.Children)) {
                                $one = [string] $share.HeaderRoot
                                if (-not [string]::IsNullOrWhiteSpace($one)) { [void] $shareRoot.Add($one) }
                            }
                        }

                        $rebuiltShare = New-Object -TypeName System.Collections.ArrayList

                        foreach ($one in @($shareRoot)) {
                            try {
                                [void] $rebuiltShare.Add((Get-HDTConsoleWorkspace -Path $one))
                            } catch {
                                [void] $rebuiltShare.Add((New-HDTConsoleShareFailure -Path $one `
                                            -Message ([string] $_.Exception.Message)))
                            }
                        }

                        # THE DEPTH-0 ROWS, NOT EVERY ROW. Get-HDTConsoleTreeNode
                        # returns the tree flat and WPF builds the branches from
                        # each row's Children, so handing it everything draws
                        # every node twice - once under its parent and once at
                        # the top.
                        $rebuiltNode = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($rebuiltShare)))

                        $tree.ItemsSource = @($rebuiltNode | Where-Object { $_.Depth -eq 0 })

                        $command.Text = "New-HDTTaskSequence -Workspace '{0}'" -f $where
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
    $service | Add-Member -MemberType ScriptMethod -Name ShowNewSequence -Value {
        param([string] $Xaml, [string] $Workspace, [object] $Theme, [object] $Owner)

        Add-Type -AssemblyName PresentationFramework

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

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
            $answer = Test-HDTConsoleNewSequence -Workspace $Workspace `
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

        $dialog.Owner = $Owner

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

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
            [object] $Size, [string] $PartitionXaml
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

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

        $propertyApply = $window.FindName('HDTPropertyApplyButton')
        $propertyRevert = $window.FindName('HDTPropertyRevertButton')

        $disableCheck = $window.FindName('HDTDisableCheck')
        $continueCheck = $window.FindName('HDTContinueCheck')
        $conditionText = $window.FindName('HDTConditionText')
        $conditionVariable = $window.FindName('HDTConditionVariableBox')
        $conditionOperator = $window.FindName('HDTConditionOperatorBox')
        $conditionValue = $window.FindName('HDTConditionValueBox')
        $conditionBuild = $window.FindName('HDTConditionBuildButton')
        $conditionApply = $window.FindName('HDTConditionApplyButton')
        $conditionClear = $window.FindName('HDTConditionClearButton')

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
        $imageApply = $window.FindName('HDTImageApplyButton')
        $imageRevert = $window.FindName('HDTImageRevertButton')
        $validateTab = $window.FindName('HDTValidateTab')
        $validateList = $window.FindName('HDTValidateList')
        $validateApply = $window.FindName('HDTValidateApplyButton')
        $validateRevert = $window.FindName('HDTValidateRevertButton')
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
            Partition = ''
            Image     = ''
            ImageShown = ''
            IndexWritten = ''
            IndexShown = ''
            Quiet     = $false
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
        $reflect = {
            $state = Get-HDTConsoleEditorState -Line $book.Line -Path $Path `
                -SelectedName $book.Selected `
                -HasClipboard:($null -ne $book.Clipboard) -Dirty:$book.Dirty

            $book.Quiet = $true

            $remove.IsEnabled = $state.CanRemove
            $up.IsEnabled = $state.CanMoveUp
            $down.IsEnabled = $state.CanMoveDown
            $copy.IsEnabled = $state.CanCopy
            $paste.IsEnabled = $state.CanPaste
            $save.IsEnabled = $state.CanSave

            $conditionApply.IsEnabled = $state.CanRemove
            $conditionClear.IsEnabled = $state.CanRemove
            $disableCheck.IsEnabled = $state.CanRemove
            $continueCheck.IsEnabled = $state.CanRemove
            $propertyApply.IsEnabled = $state.CanRemove
            $propertyRevert.IsEnabled = $state.CanRemove

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
            $view = Get-HDTConsolePartitionRow -Line $book.Line -Path $Path -Name $book.Selected

            $diskTab.Visibility = [System.Windows.Visibility]::Collapsed
            if ($view.IsDiskStep) { $diskTab.Visibility = [System.Windows.Visibility]::Visible }

            # THE OPERATING SYSTEM PAGE, on the same rule as the disk one: MDT's
            # Install Operating System dialog IS that step's properties page.
            $imageChoice = Get-HDTConsoleImageChoice -Line $book.Line -Path $Path `
                -Name $book.Selected -Workspace $workspaceRoot

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

            $imageApply.IsEnabled = $imageChoice.IsImageStep
            $imageRevert.IsEnabled = $imageChoice.IsImageStep

            # THE VALIDATION PAGE, on the same rule as the disk one. MDT's
            # Validate dialog IS that step's properties page, so the generic tab
            # goes with it.
            $validate = Get-HDTConsoleValidateCheck -Line $book.Line -Path $Path -Name $book.Selected

            $validateTab.Visibility = [System.Windows.Visibility]::Collapsed
            if ($validate.IsValidateStep) {
                $validateTab.Visibility = [System.Windows.Visibility]::Visible
                $validateList.ItemsSource = $validate.Check
            }

            $validateApply.IsEnabled = $validate.IsValidateStep
            $validateRevert.IsEnabled = $validate.IsValidateStep

            # AND THE GENERIC TAB GOES WHEN A DEDICATED PAGE ARRIVES. With the
            # disk keys on their own page and the name above the tabs, what was
            # left on Properties for this step was eight rows of facts and
            # nothing to do about any of them.
            #
            # Properties stays for every other step type: most have no page of
            # their own, and it is the only editor they get.
            $propertyTab.Visibility = [System.Windows.Visibility]::Visible
            if ($view.IsDiskStep -or $validate.IsValidateStep -or $imageChoice.IsImageStep) {
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
            $state = Get-HDTConsoleEditorState -Line $book.Line -Path $Path -SelectedName $book.Selected

            $book.Quiet = $true
            $tree.ItemsSource = $state.Root
            $book.Quiet = $false

            & $reflect
        }.GetNewClosure()

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

        $remove.Add_Click({
                $book.Line = @(Remove-HDTStep -Line $book.Line -Name $book.Selected -Confirm:$false)
                $book.Dirty = $true
                $book.Selected = ''
                & $rebuild
            }.GetNewClosure())

        $up.Add_Click({
                $book.Line = @(Move-HDTStep -Line $book.Line -Name $book.Selected -Direction Up)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $down.Add_Click({
                $book.Line = @(Move-HDTStep -Line $book.Line -Name $book.Selected -Direction Down)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $copy.Add_Click({
                $book.Clipboard = @(Copy-HDTStep -Line $book.Line -Name $book.Selected)
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
        $propertyApply.Add_Click({
                $subject = $book.Selected

                foreach ($one in @(Get-HDTConsoleStepChange -Field $detail.ItemsSource -Name $subject)) {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $subject `
                            -Property $one.Property -Value $one.Value)

                    $command.Text = [string] $one.Command
                    $book.Dirty = $true

                    # What it answers to from here on. Only a rename moves it,
                    # and the change says so - the window does not carry its own
                    # idea of which properties are names.
                    $subject = [string] $one.NameAfter
                }

                $book.Selected = $subject
                & $rebuild
            }.GetNewClosure())

        # REVERT IS A REBUILD, because the rows are rebuilt from the lines and
        # the lines are what has not been typed into.
        $propertyRevert.Add_Click({
                & $rebuild
            }.GetNewClosure())

        $conditionApply.Add_Click({
                $book.Line = @(Set-HDTStepCondition -Line $book.Line -Name $book.Selected `
                        -Condition ([string] $conditionText.Text))
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

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
            param([scriptblock] $Attempt, [string] $Echo)

            try {
                & $Attempt
                $book.Dirty = $true
                $command.Text = $Echo
                & $rebuild
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

            $view = Get-HDTConsolePartitionRow -Line $book.Line -Path $Path -Name $book.Selected

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
        $imageApply.Add_Click({
                # UNCHANGED MEANS UNCHANGED. The box shows the image a variable
                # resolves to, so writing what the box holds would replace
                # '%HDTOSImage%' with today's answer - silently, on a press
                # meant for the time limit.
                $image = [string] $book.Image
                if ([string] $imageBox.SelectedValue -ne [string] $book.ImageShown) {
                    $image = [string] $imageBox.SelectedValue
                }

                $written = @(
                    @{ Key = 'os'; Value = $image }
                    @{ Key = 'index'; Value = $(
                            # WHAT THE FILE GETS IS THE NUMBER, never the label.
                            # A selected editable ComboBox reports its Display as
                            # Text - '1  -  Windows 11 Enterprise LTSC' - and
                            # that is not an index.
                            $typed = [string] $imageIndexBox.Text
                            if ($null -ne $imageIndexBox.SelectedItem) {
                                $typed = [string] $imageIndexBox.SelectedItem.Index
                            }

                            if ($typed -eq [string] $book.IndexShown) {
                                [string] $book.IndexWritten
                            } else { $typed }) }
                    @{ Key = 'target'; Value = [string] $imageTargetBox.Text }
                    @{ Key = 'timeoutMinutes'; Value = [string] $imageTimeoutBox.Text }
                )

                & $partitionAttempt {
                    foreach ($one in $written) {
                        $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $book.Selected `
                                -Property ([string] $one.Key) -Value ([string] $one.Value) -Confirm:$false)
                    }
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'os' -Value '{1}'" -f
                    $book.Selected, [string] $imageBox.SelectedValue)
            }.GetNewClosure())

        $imageRevert.Add_Click({ & $reflect }.GetNewClosure())

        # THE VALIDATION PAGE WRITES ON ONE PRESS, which is MDT's OK. Writing on
        # every keystroke would splice the document six times while somebody
        # types a number, and each splice rebuilds the tree under their hands.
        #
        # UNTICKED REMOVES THE KEY rather than writing a zero: 'minRamMB: 0' is a
        # bound of nothing that still reads as a declared bound, and there would
        # then be no way to say "I do not care about memory".
        $validateApply.Add_Click({
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
            }.GetNewClosure())

        $validateRevert.Add_Click({
                # THE DOCUMENT IS THE TRUTH, so reverting is re-reading it. The
                # rows are rebuilt from the file rather than remembered, which
                # is the same reason the tree is.
                & $reflect
            }.GetNewClosure())

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

                $detail.ItemsSource = $selected.Field
                $command.Text = [string] $selected.Command
                $book.Selected = [string] $selected.Name

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

                $prompt = Get-HDTConsoleClosePrompt -DocumentPath $Path -Dirty:$book.Dirty

                if (-not $prompt.Ask) { return }

                # Cast rather than dynamic member access: the command names the
                # button set and the icon as strings, and a cast is what turns a
                # name into the enum without this line knowing the list.
                $answer = [System.Windows.MessageBox]::Show($window, $prompt.Message, $prompt.Title,
                    ([System.Windows.MessageBoxButton] $prompt.Button),
                    ([System.Windows.MessageBoxImage] $prompt.Icon))

                $decision = Resolve-HDTConsoleCloseAnswer -Answer ([string] $answer)

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
            [string] $ThemeName, [object[]] $TimeZone = @()
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

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

        $titleText = $window.FindName('HDTBootImageTitleText')
        $pathText = $window.FindName('HDTBootImagePathText')

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

        $save.Add_Click({
                $propertySplat = @{ Line = $book.Line; Confirm = $false }

                if (-not [string]::IsNullOrWhiteSpace($nameBox.Text)) {
                    $propertySplat['BootImageName'] = [string] $nameBox.Text
                }
                if (-not [string]::IsNullOrWhiteSpace($architectureBox.SelectedValue)) {
                    $propertySplat['Architecture'] = [string] $architectureBox.SelectedValue
                }
                if (-not [string]::IsNullOrWhiteSpace($languageBox.Text)) {
                    $propertySplat['Language'] = [string] $languageBox.Text
                }
                if (-not [string]::IsNullOrWhiteSpace($scratchBox.SelectedValue)) {
                    $propertySplat['ScratchSpaceMB'] = [int] $scratchBox.SelectedValue
                }

                # WRITTEN WHICHEVER WAY IT IS SET, unlike the boxes above, which
                # are skipped when empty. A tick box has no empty: unticked is
                # an answer, and 'promptForKey: false' in the document is what
                # tells the next reader somebody decided rather than never
                # looked.
                $propertySplat['PromptForKey'] = [bool] $promptForKeyCheck.IsChecked

                $book.Line = @(Set-HDTWorkspaceProperty @propertySplat)

                if ([string]::IsNullOrWhiteSpace($unattendBox.Text)) {
                    $book.Line = @(Set-HDTBootImageUnattend -Line $book.Line -Clear -Confirm:$false)
                } else {
                    $book.Line = @(Set-HDTBootImageUnattend -Line $book.Line `
                            -Path ([string] $unattendBox.Text) -Confirm:$false)
                }

                if ([string]::IsNullOrWhiteSpace($backgroundBox.Text)) {
                    $book.Line = @(Set-HDTBootImageBackground -Line $book.Line -Clear -Confirm:$false)
                } else {
                    $book.Line = @(Set-HDTBootImageBackground -Line $book.Line `
                            -Path ([string] $backgroundBox.Text) -Confirm:$false)
                }

                if ([string]::IsNullOrWhiteSpace($timeZoneBox.SelectedValue)) {
                    $book.Line = @(Set-HDTBootImageTimeZone -Line $book.Line -Clear -Confirm:$false)
                } else {
                    $book.Line = @(Set-HDTBootImageTimeZone -Line $book.Line `
                            -Name ([string] $timeZoneBox.SelectedValue) -Confirm:$false)
                }

                if ([string]::IsNullOrWhiteSpace($clientCertificateBox.Text)) {
                    $book.Line = @(Set-HDTBootImageClientCertificate -Line $book.Line -Clear -Confirm:$false)
                } else {
                    $book.Line = @(Set-HDTBootImageClientCertificate -Line $book.Line `
                            -Path ([string] $clientCertificateBox.Text) -Confirm:$false)
                }

                if ([string]::IsNullOrWhiteSpace($driverBox.SelectedValue)) {
                    $book.Line = @(Set-HDTBootImageDriver -Line $book.Line -Clear -Confirm:$false)
                } else {
                    $book.Line = @(Set-HDTBootImageDriver -Line $book.Line `
                            -Name ([string] $driverBox.SelectedValue) -Confirm:$false)
                }

                [void] (Save-HDTWorkspaceDocument -Path $Path -Line $book.Line `
                        -FileSystem (New-HDTFileSystem) -Confirm:$false)

                $book.Dirty = $false

                & $fillBoxes
                & $fillLists

                # EVERY COMMAND SAVE RAN, NOT JUST THE LAST ONE. One press is
                # four invocations, and echoing only the write hid the three
                # that decided what was written - which is exactly the surface
                # DESIGN 12 says this box exists to teach. Composed from the
                # refreshed view, so what it shows is what the file now says.
                $ran = New-Object -TypeName System.Collections.ArrayList

                [void] $ran.Add([string] $book.View.General.Command)

                if ([string]::IsNullOrWhiteSpace($book.View.General.Unattend)) {
                    [void] $ran.Add([string] $book.View.General.UnattendClearCommand)
                } else {
                    [void] $ran.Add($book.View.General.UnattendCommandFormat -f
                        [string] $book.View.General.Unattend)
                }

                if ([string]::IsNullOrWhiteSpace($book.View.General.Background)) {
                    [void] $ran.Add([string] $book.View.General.BackgroundClearCommand)
                } else {
                    [void] $ran.Add($book.View.General.BackgroundCommandFormat -f
                        [string] $book.View.General.Background)
                }

                if ([string]::IsNullOrWhiteSpace($book.View.TimeZone.Id)) {
                    [void] $ran.Add([string] $book.View.TimeZone.ClearCommand)
                } else {
                    [void] $ran.Add($book.View.TimeZone.ApplyCommandFormat -f [string] $book.View.TimeZone.Id)
                }

                if ([string]::IsNullOrWhiteSpace($book.View.ClientCertificate.Path)) {
                    [void] $ran.Add([string] $book.View.ClientCertificate.ClearCommand)
                } else {
                    [void] $ran.Add($book.View.ClientCertificate.ApplyCommandFormat -f
                        [string] $book.View.ClientCertificate.Path)
                }

                if ([string]::IsNullOrWhiteSpace($book.View.Driver.Group)) {
                    [void] $ran.Add([string] $book.View.Driver.ClearCommand)
                } else {
                    [void] $ran.Add($book.View.Driver.ApplyCommandFormat -f [string] $book.View.Driver.Group)
                }

                [void] $ran.Add("Save-HDTWorkspaceDocument -Line `$line -Path '{0}'" -f $Path)

                $commandText.Text = (@($ran) -join [System.Environment]::NewLine)
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
                        -Theme $ThemeName -Screen (New-HDTConsoleScreen))

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

                $prompt = Get-HDTConsoleClosePrompt -DocumentPath $Path -Dirty:$book.Dirty

                if (-not $prompt.Ask) { return }

                $answer = [System.Windows.MessageBox]::Show($window, $prompt.Message, $prompt.Title,
                    ([System.Windows.MessageBoxButton] $prompt.Button),
                    ([System.Windows.MessageBoxImage] $prompt.Icon))

                $decision = Resolve-HDTConsoleCloseAnswer -Answer ([string] $answer)

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
