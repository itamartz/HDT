function New-HDTConsoleHost {
    <#
        .SYNOPSIS
            The real IConsoleHost: loads the console XAML with XamlReader and
            shows the window.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY
            BRANCH-FREE. CLAUDE.md rule 1's only exception to TDD is a thin
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
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        # THE PALETTE ARRIVES TWICE, AS BRUSHES AND AS ITS NAME. The brushes
        # paint this window; the name is what Show-HDTSequenceEditor takes, so
        # an editor opened by a double-click comes up in the palette the console
        # is already wearing. The name cannot be recovered from the brushes, and
        # a key added to the hashtable would be fed to the BrushConverter below
        # along with the colours.
        param([string] $Xaml, [string] $Title, [object[]] $Node, [object] $Theme, [object] $Size,
            [string] $ThemeName = 'Light')

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $window.Title = $Title

        # The size the console was last left at, over the markup's first-run
        # numbers. Get-HDTConsoleSetting decided these; this applies them.
        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height

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

                [void] (Show-HDTSequenceEditor -Sequence $selected.Subject -Theme $ThemeName)
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
                foreach ($root in @($Node)) {
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
    $service | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
        param(
            [string] $Xaml, [string] $Title, [string] $Path,
            [object[]] $Node, [string[]] $Line, [object[]] $Catalog, [object] $Theme
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        $window.Title = $Title

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $this.Answer = ''

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
        $conditionApply = $window.FindName('HDTConditionApplyButton')
        $conditionClear = $window.FindName('HDTConditionClearButton')
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
                        $book.Line = @(Add-HDTConsoleStep -Line $book.Line -After $book.Selected -Block $chosen.Block)
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
                $book.Line = @(Remove-HDTConsoleStep -Line $book.Line -Name $book.Selected -Confirm:$false)
                $book.Dirty = $true
                $book.Selected = ''
                & $rebuild
            }.GetNewClosure())

        $up.Add_Click({
                $book.Line = @(Move-HDTConsoleStep -Line $book.Line -Name $book.Selected -Direction Up)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $down.Add_Click({
                $book.Line = @(Move-HDTConsoleStep -Line $book.Line -Name $book.Selected -Direction Down)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $copy.Add_Click({
                $book.Clipboard = @(Copy-HDTConsoleStep -Line $book.Line -Name $book.Selected)
                & $rebuild
            }.GetNewClosure())

        $paste.Add_Click({
                $book.Line = @(Add-HDTConsoleStep -Line $book.Line -After $book.Selected -Block $book.Clipboard)
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        # THE ONLY PRESS THAT TOUCHES THE SHARE. Save-HDTConsoleSequence checks
        # the result through the engine's own reader before it writes.
        $save.Add_Click({
                [void] (Save-HDTConsoleSequence -Path $Path -Line $book.Line -FileSystem (New-HDTFileSystem) -Confirm:$false)
                $book.Dirty = $false
                & $rebuild
            }.GetNewClosure())

        $disableCheck.Add_Click({
                if ($book.Quiet) { return }

                $book.Line = @(Set-HDTConsoleStepFlag -Line $book.Line -Name $book.Selected `
                        -Flag Disabled -Value ([bool] $disableCheck.IsChecked))
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $continueCheck.Add_Click({
                if ($book.Quiet) { return }

                $book.Line = @(Set-HDTConsoleStepFlag -Line $book.Line -Name $book.Selected `
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
                    $book.Line = @(Set-HDTConsoleStepProperty -Line $book.Line -Name $subject `
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
                $book.Line = @(Set-HDTConsoleStepCondition -Line $book.Line -Name $book.Selected `
                        -Condition ([string] $conditionText.Text))
                $book.Dirty = $true
                & $rebuild
            }.GetNewClosure())

        $conditionClear.Add_Click({
                $book.Line = @(Set-HDTConsoleStepCondition -Line $book.Line -Name $book.Selected -Condition '')
                $book.Dirty = $true
                & $rebuild
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
                    [void] (Save-HDTConsoleSequence -Path $Path -Line $book.Line `
                            -FileSystem (New-HDTFileSystem) -Confirm:$false)
                    $book.Dirty = $false
                }
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}
