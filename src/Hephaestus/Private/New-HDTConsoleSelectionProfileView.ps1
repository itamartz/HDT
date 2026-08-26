function New-HDTConsoleSelectionProfileView {
    <#
        .SYNOPSIS
            Builds the Selection Profiles window and wires every control on it,
            without showing it.

        .DESCRIPTION
            Deployment Workbench's Advanced Configuration \ Selection Profiles: a
            list of profiles beside a tick box tree of the share.

            IT BUILDS AND RETURNS; IT DOES NOT SHOW. ShowDialog is the caller's,
            which is what makes every handler on this window reachable from
            Pester - see New-HDTConsoleView for why the split exists at all.

            EVERY DECISION IS Get-HDTConsoleSelectionProfileSetting's. What is
            ticked, which buttons are live, what each one would run: this
            attaches handlers and moves strings onto controls, and asks that for
            everything else.

            THE DOCUMENT IS HELD AS LINES AND SPLICED, never re-serialised, so
            the comments an administrator wrote about their fleet survive a New,
            a Rename, a Delete and a Save. $book carries those lines between
            handlers because a closure captures a variable's VALUE and every
            handler has to see the edit the last one made.

            SAVE IS TWO INVOCATIONS AND THE BOX SHOWS BOTH: the splice, then
            Save-HDTSelectionProfileDocument. Nothing on this window writes to
            the share except that second one.

            A HANDLER REACHES A PRIVATE HELPER THROUGH $call. A closure resolves
            commands in the session state it was rebound to - the console's - so
            a private function named directly is "not recognized". See
            Get-HDTHandlerCall.

        .PARAMETER ConsoleHost
            The console host. Its Window owns this one; its Answer carries what
            happened back.

        .PARAMETER Xaml
            HDTSelectionProfile.xaml, as text.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Line
            Control\selection-profiles.yaml as lines. Empty for a share that has
            no document yet, which is the ordinary first run.

        .PARAMETER SelectionProfile
            What Get-HDTSelectionProfile returned for this share.

        .PARAMETER Folder
            What Get-HDTShareContentFolder returned for this share.

        .PARAMETER Theme
            The palette, as brushes.

        .PARAMETER Size
            Where and how big to open.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built, wired, and not shown.

        .EXAMPLE
            New-HDTConsoleSelectionProfileView -ConsoleHost $service -Xaml $xaml -Root 'C:\HDTLab\Share'

        .EXAMPLE
            $window = New-HDTConsoleSelectionProfileView -ConsoleHost $service -Xaml $xaml -Root $root
            [void] $window.ShowDialog()

        .LINK
            Get-HDTConsoleSelectionProfileSetting
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a window object and shows nothing; ShowDialog is the caller''s.')]
    [CmdletBinding()]
    [OutputType([System.Windows.Window])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ConsoleHost,

        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Xaml,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter()] [AllowNull()] [string[]] $Line = @(),
        [Parameter()] [AllowNull()] [object[]] $SelectionProfile = @(),
        [Parameter()] [AllowNull()] [object[]] $Folder = @(),
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Size = $null,

        # THE ONE HANDLER ON THIS WINDOW THAT WRITES, AND IT WRITES THROUGH
        # THIS. Without it, pressing Save in a test would put a file on the
        # tester's disk - so the Save handler is the one thing about this window
        # nothing could assert.
        [Parameter()] [AllowNull()] [object] $FileSystem = $null
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $call = Get-HDTHandlerCall

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    $writer = $FileSystem

    $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $window.Icon = Get-HDTConsoleWindowIcon

    if ($null -ne $Size) {
        $window.Width = [double] $Size.Width
        $window.Height = [double] $Size.Height
        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top
    }

    $window.Owner = $ConsoleHost.Window

    if ($null -ne $Theme) {
        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }
    }

    $ConsoleHost.Answer = ''
    $profileHost = $ConsoleHost

    [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page 'SelectionProfile'))

    # -- the controls ---------------------------------------------------------

    $titleText = $window.FindName('HDTSelectionProfileTitleText')
    $pathText = $window.FindName('HDTSelectionProfilePathText')
    $list = $window.FindName('HDTSelectionProfileList')
    $nameBox = $window.FindName('HDTSelectionProfileNameBox')
    $idText = $window.FindName('HDTSelectionProfileIdText')
    $newButton = $window.FindName('HDTSelectionProfileNewButton')
    $renameButton = $window.FindName('HDTSelectionProfileRenameButton')
    $deleteButton = $window.FindName('HDTSelectionProfileDeleteButton')
    $includeLabel = $window.FindName('HDTSelectionProfileIncludeLabel')
    $tree = $window.FindName('HDTSelectionProfileTree')
    $summaryText = $window.FindName('HDTSelectionProfileSummaryText')
    $commandText = $window.FindName('HDTSelectionProfileCommandText')
    $saveButton = $window.FindName('HDTSelectionProfileSaveButton')
    $closeButton = $window.FindName('HDTSelectionProfileCloseButton')

    # WHAT EVERY HANDLER SHARES. A closure captures a variable's value, so the
    # lines have to live on an object all of them reach the same instance of.
    $book = [pscustomobject] @{
        Line       = [string[]] @($Line)
        Profile    = [object[]] @($SelectionProfile)
        SelectedId = ''
        View       = $null
        Saved      = $false

        # THE RE-ENTRANCY GUARD, AND IT IS NOT OPTIONAL. $refresh assigns
        # ItemsSource and then SelectedItem, and BOTH raise SelectionChanged -
        # whose handler calls $refresh. Without this the first draw recurses
        # until PowerShell gives up with "call depth overflow", which is what
        # opening the window found and no test of the view model could.
        Filling    = $false
    }

    $documentPath = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'selection-profiles.yaml'

    # -- reading the document back after every edit ---------------------------
    #
    # THE PROFILES ARE RE-READ FROM THE LINES, not patched in memory. One parser
    # decides what this window shows and what the next build injects, so a
    # splice that produced something surprising is seen HERE rather than at 3am.
    $reread = {
        $parsed = @()

        try {
            $parsed = @(& $call 'Get-HDTSelectionProfileFromLine' -Line $book.Line -Path $documentPath)
        } catch {
            # A document the parser refuses leaves the list as it was and says
            # so on the command line, which is the only place on this window
            # that can carry a sentence nobody has to dismiss.
            $commandText.Text = '# the document could not be read: {0}' -f [string] $_.Exception.Message
            return
        }

        $book.Profile = [object[]] @($parsed)
    }.GetNewClosure()

    $refresh = {
        $book.View = & $call 'Get-HDTConsoleSelectionProfileSetting' -Root $Root `
            -SelectionProfile $book.Profile -Folder $Folder -SelectedId $book.SelectedId

        $view = $book.View

        # See $book.Filling: the two assignments below both raise
        # SelectionChanged, and its handler calls this.
        $book.Filling = $true

        $titleText.Text = [string] $view.Title
        $pathText.Text = [string] $view.DocumentPath
        $includeLabel.Text = [string] $view.IncludeLabel
        $summaryText.Text = [string] $view.Summary

        # THE LIST IS REBUILT AND THE SELECTION PUT BACK AFTER IT, because
        # SelectedValue means nothing until the item carrying it exists.
        try {
            $list.ItemsSource = $view.Profile
            $list.SelectedItem = @($view.Profile | Where-Object { $_.Id -eq $book.SelectedId }) |
                Select-Object -First 1
        } finally {
            # IN A finally, so a binding failure cannot leave the window with
            # its selection handler switched off for the rest of the session.
            $book.Filling = $false
        }

        # ROOTS ONLY. WPF builds the branches from each row's Children, so
        # handing it a flat list draws every node twice.
        $tree.ItemsSource = [object[]] @($view.Tree)

        # A BUILT-IN GOES GREY RATHER THAN REFUSING AFTER THE CLICK.
        $renameButton.IsEnabled = [bool] $view.CanEdit
        $deleteButton.IsEnabled = [bool] $view.CanEdit
        $saveButton.IsEnabled = [bool] $view.CanEdit
    }.GetNewClosure()

    # A TICK HAS TO REACH THE WHOLE BRANCH, or the tree lies about the build.
    #
    # The box was bound straight to the node's State with nothing behind it, so
    # ticking 'Drivers\WinPE' set that one box and left Dell and HP blank
    # underneath it - while Save included the whole branch, because an include
    # means the folder and everything under it. What was on screen and what
    # would be injected were two different profiles.
    #
    # ONE HANDLER ON THE TREE, NOT ONE PER BOX. The boxes are made by a
    # HierarchicalDataTemplate and remade whenever the tree is rebuilt, so a
    # handler attached to each would have to be attached again every time.
    # Checked and Unchecked are routed and bubble; OriginalSource is the box.
    #
    # THE INCLUDE LIST IS READ BACK FROM THE TREE, decided by
    # Set-HDTConsoleSelectionProfileTick, and the tree rebuilt from the answer -
    # so the ticks a person sees are always the ticks the builder computes from
    # a document, and never a second opinion drawn by a handler.
    $onTick = {
        # THE NAMES MATTER. $Args collides with PowerShell's own automatic
        # variable, so a parameter called that is not the event arguments and
        # every read off it is a property that is not there - which StrictMode
        # turns into a terminating error INSIDE a WPF handler, where it does
        # nothing and says nothing. This window's other routed handlers already
        # use $raiser and a typed second parameter; so does this one.
        param([object] $raiser, [System.Windows.RoutedEventArgs] $ticked)

        # See $book.Filling: rebinding ItemsSource raises Checked for every row
        # that comes back ticked, and each would rebuild the tree again.
        if ($book.Filling) { return }

        $box = $ticked.OriginalSource -as [System.Windows.Controls.CheckBox]
        if ($null -eq $box) { return }

        $node = $box.DataContext
        if ($null -eq $node) { return }
        if ($null -eq $node.PSObject.Properties['Path']) { return }

        $wanted = ($box.IsChecked -eq $true)

        # READ AFTER THE CLICK, WHICH IS SAFE: the include list is the SHALLOWEST
        # ticked folders, and this node's own new state is the only one that has
        # moved. Unticking a child of a ticked parent still reads the parent,
        # which is exactly what the tick command needs in order to expand it.
        $include = @(& $call 'Get-HDTConsoleSelectionProfileInclude' `
                -Tree ([object[]] @($tree.ItemsSource)))

        $next = @(& $call 'Set-HDTConsoleSelectionProfileTick' -Folder ([object[]] @($Folder)) `
                -Include ([string[]] @($include)) -Path ([string] $node.Path) -State $wanted)

        # THE GUARD HAS TO OUTLIVE THIS METHOD, and a try/finally does not.
        #
        # Assigning ItemsSource does not build the boxes: WPF generates the
        # containers during the NEXT layout pass, and each box that comes back
        # ticked raises Checked then - long after a finally would have cleared
        # the flag. So every rebuild started another one, and the window died of
        # it. Clearing at ContextIdle puts the flag down after the containers
        # exist, which is the moment the re-entrant ticks have finished.
        $book.Filling = $true

        try {
            $tree.ItemsSource = [object[]] @(& $call 'Get-HDTConsoleSelectionProfileTree' `
                    -Folder ([object[]] @($Folder)) -Include ([string[]] @($next)))
        } catch {
            $book.Filling = $false
            throw
        }

        [void] $tree.Dispatcher.BeginInvoke(
            [action] { $book.Filling = $false }.GetNewClosure(),
            [System.Windows.Threading.DispatcherPriority]::ContextIdle)
    }.GetNewClosure()

    $tree.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
        [System.Windows.RoutedEventHandler] $onTick)

    $tree.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
        [System.Windows.RoutedEventHandler] $onTick)

    # THE ID, AS IT IS TYPED. workspace.yaml references it, so somebody who has
    # to write one into a document by hand has to be able to read it here.
    $showId = {
        $typed = [string] $nameBox.Text

        # THE SELECTED PROFILE'S OWN ID, WHENEVER THAT IS WHAT THE BOX SAYS. An
        # id is derived from a name ONCE, when the profile is created, and never
        # again - renaming leaves it alone, because workspace.yaml and every
        # sequence step reference it. Deriving one from the name on screen and
        # showing that would print 'boot-critical-dell-and-hp' beside a profile
        # whose id is 'boot-critical', which is a value an administrator could
        # copy into a document that would then match nothing.
        $chosen = @($book.Profile | Where-Object { $_.Id -eq $book.SelectedId }) | Select-Object -First 1

        if (($null -ne $chosen) -and ($typed -eq [string] $chosen.Name)) {
            $idText.Text = 'id: {0}' -f [string] $chosen.Id
            return
        }

        $id = & $call 'ConvertTo-HDTSelectionProfileId' -Name $typed

        if ([string]::IsNullOrEmpty($id)) {
            $idText.Text = 'Type a name. New derives the id documents reference from it.'
        } else {
            $idText.Text = 'New would use id: {0}' -f $id
        }
    }.GetNewClosure()

    $nameBox.Add_TextChanged({ & $showId }.GetNewClosure())

    $list.Add_SelectionChanged({
            if ($book.Filling) { return }

            $chosen = $list.SelectedItem
            if ($null -eq $chosen) { return }

            $book.SelectedId = [string] $chosen.Id
            $nameBox.Text = [string] $chosen.Name

            & $refresh
            & $showId
        }.GetNewClosure())

    # -- the buttons ----------------------------------------------------------

    $newButton.Add_Click({
            $name = [string] $nameBox.Text
            $id = & $call 'ConvertTo-HDTSelectionProfileId' -Name $name

            if ([string]::IsNullOrEmpty($id)) {
                $commandText.Text = '# type a name for the new profile first.'
                return
            }

            # A HASHTABLE, NOT -Confirm:$false. The colon form is parsed against
            # the DOOR scriptblock, which has no -Confirm, so the switch never
            # reaches the command - and the command then calls ShouldProcess on
            # a runtime that has not been told, which throws "Object reference
            # not set" from inside a button handler. Get-HDTHandlerCall says so;
            # this is the one form that carries a switch.
            try {
                $book.Line = [string[]] @(& $call 'New-HDTSelectionProfile' @{
                        Line = $book.Line; Id = $id; Name = $name
                        Root = $Root; FileSystem = $writer; Confirm = $false
                    })
            } catch {
                $commandText.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $commandText.Text = ([string] $book.View.NewCommandFormat -f $id, $name)
            $book.SelectedId = $id

            & $reread
            & $refresh
        }.GetNewClosure())

    $renameButton.Add_Click({
            $name = [string] $nameBox.Text

            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrEmpty($book.SelectedId)) { return }

            try {
                $book.Line = [string[]] @(& $call 'Set-HDTSelectionProfile' @{
                        Line = $book.Line; Id = $book.SelectedId; Name = $name; Confirm = $false
                    })
            } catch {
                $commandText.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $commandText.Text = ([string] $book.View.RenameCommandFormat -f $book.SelectedId, $name)

            & $reread
            & $refresh
        }.GetNewClosure())

    $deleteButton.Add_Click({
            if ([string]::IsNullOrEmpty($book.SelectedId)) { return }

            $gone = $book.SelectedId

            try {
                $book.Line = [string[]] @(& $call 'Remove-HDTSelectionProfile' @{
                        Line = $book.Line; Id = $gone; Confirm = $false
                    })
            } catch {
                $commandText.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $commandText.Text = ([string] $book.View.RemoveCommandFormat -f $gone)
            $book.SelectedId = ''
            $nameBox.Text = ''

            & $reread
            & $refresh
        }.GetNewClosure())

    $saveButton.Add_Click({
            if ([string]::IsNullOrEmpty($book.SelectedId)) { return }

            # THE TICKS AS THEY STAND NOW, read off the tree the window has been
            # binding to - a TwoWay binding wrote every click straight onto the
            # node, so this is the administrator's answer and not the one the
            # view model started with.
            $include = @(& $call 'Get-HDTConsoleSelectionProfileInclude' -Tree ([object[]] @($tree.ItemsSource)))

            try {
                # -Root, SO THE SHARE HAS THE LAST WORD. Every path here came
                # from a tick on a folder the tree read off the share, so this
                # can only fail if somebody deleted one while the window was
                # open - which is exactly when it should.
                $book.Line = [string[]] @(& $call 'Set-HDTSelectionProfile' @{
                        Line = $book.Line; Id = $book.SelectedId
                        Include = [string[]] $include
                        Root = $Root; FileSystem = $writer; Confirm = $false
                    })

                [void] (& $call 'Save-HDTSelectionProfileDocument' @{
                        Path = $documentPath; Line = $book.Line
                        FileSystem = $writer; Confirm = $false
                    })
            } catch {
                $commandText.Text = '# {0}' -f [string] $_.Exception.Message
                return
            }

            $book.Saved = $true
            $profileHost.Answer = 'saved'

            $quoted = ''
            if (@($include).Count -gt 0) {
                $quoted = (@($include | ForEach-Object { "'{0}'" -f $_ }) -join ', ')
            } else {
                $quoted = '@()'
            }

            $commandText.Text = (([string] $book.View.SaveCommandFormat -f $book.SelectedId, $quoted) +
                [Environment]::NewLine +
                ([string] $book.View.SaveDocumentFormat -f $documentPath))

            & $reread
            & $refresh
        }.GetNewClosure())

    $closeButton.Add_Click({
            # A WINDOW THAT WAS NEVER SHOWN CANNOT BE CLOSED, and a test builds
            # one and presses this. The answer has already landed either way, so
            # the refusal is genuinely nothing to act on - it is swallowed
            # deliberately and Close is the last thing this handler does.
            try {
                $window.Close()
            } catch {
                Write-Verbose ("the window was never shown, so there was nothing to close: {0}" -f
                    [string] $_.Exception.Message)
            }
        }.GetNewClosure())

    # -- the first draw -------------------------------------------------------

    $first = @($book.Profile | Where-Object { -not $_.IsBuiltIn }) | Select-Object -First 1
    if ($null -ne $first) {
        $book.SelectedId = [string] $first.Id
        $nameBox.Text = [string] $first.Name
    }

    & $refresh
    & $showId

    return $window
}
