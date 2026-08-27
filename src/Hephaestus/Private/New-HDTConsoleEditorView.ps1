function New-HDTConsoleEditorView {
    <#
        .SYNOPSIS
            Builds the task sequence editor's window and wires it, without showing it.

        .DESCRIPTION
            THE TASK SEQUENCE EDITOR'S WINDOW: the step tree, the properties
            sheet, the Options tab and the partition dialog it opens.


            BUILDING A WINDOW AND SHOWING ONE ARE TWO DIFFERENT JOBS, and only
            the second needs a desktop. This loads the markup, paints the
            palette and hangs every handler off the tree; the ScriptMethod that
            calls it then calls ShowDialog, which is the part that blocks. See
            New-HDTConsoleView for the whole reasoning and for why the rule
            in .planning/WPF-FIRST.md was narrowed to allow it.

            THE HOST IS INJECTED RATHER THAN BEING $this. Inside a handler $this
            is the control that raised the event, and a ScriptMethod's enclosing
            scope is not in scope either - so the handlers close over the host by
            name, and that name arrives as a parameter.

            IT SHOWS NOTHING AND RETURNS THE WINDOW.

        .PARAMETER ConsoleHost
            The service object the handlers write their answer to.

        .PARAMETER Xaml
            The editor markup.

        .PARAMETER Title
            The window title.

        .PARAMETER Path
            The sequence document being edited.

        .PARAMETER Node
            The step tree's rows.

        .PARAMETER Line
            The document, as lines.

        .PARAMETER Catalog
            The step types that can be added.

        .PARAMETER Theme
            The palette, as brushes.

        .PARAMETER Size
            The size to open at.

        .PARAMETER PartitionXaml
            Markup for the partition properties dialog.

        .PARAMETER Editor
            The editor's own settings.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built and wired, never shown.

        .EXAMPLE
            New-HDTConsoleEditorView -ConsoleHost $service -Xaml $xaml

        .EXAMPLE
            $window = New-HDTConsoleEditorView -ConsoleHost $host -Xaml $xaml
            [void] $window.ShowDialog()
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
        [Parameter()] [AllowEmptyString()] [string] $Title = '',
        [Parameter()] [AllowEmptyString()] [string] $Path = '',
        [Parameter()] [AllowNull()] [object[]] $Node = @(),
        [Parameter()] [AllowNull()] [string[]] $Line = @(),
        [Parameter()] [AllowNull()] [object[]] $Catalog = @(),
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Size = $null,
        [Parameter()] [AllowEmptyString()] [string] $PartitionXaml = '',
        [Parameter()] [AllowNull()] [object] $Editor = $null
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
        $window.Owner = $ConsoleHost.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $ConsoleHost.Answer = ''

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
        $editorHost = $ConsoleHost

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
            # A ROW FROM A NAMED LAYOUT IS NOT IN THE DOCUMENT YET, and it used
            # to be untouchable for that reason - which left the five buttons
            # dark on every sequence the standard client template produces.
            # MDT's Format and Partition Disk grid is editable the moment it
            # opens; pressing one of these now writes the layout out as the
            # step's own table first and then does what was asked. The
            # conversion is named on the strip, so it is a decision somebody can
            # see rather than a side effect they cannot.
            $ownRow = ($at -gt 0 -and -not $partitionList.SelectedItem.FromLayout)
            $rowEditable = ($at -gt 0 -and ($ownRow -or $view.CanExpand))

            $partitionUp.IsEnabled = ($rowEditable -and $at -gt 1)
            $partitionDown.IsEnabled = ($rowEditable -and $at -lt @($view.Row).Count)
            $partitionRemove.IsEnabled = ($rowEditable -and @($view.Row).Count -gt 1)
            $partitionEdit.IsEnabled = $rowEditable

            # New needs a table to add to, or a layout it can turn into one. A
            # layout named by a variable is neither, because which table it means
            # is not decided until the machine is in front of it.
            $partitionAdd.IsEnabled = ($view.HasTable -or $view.CanExpand)

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

            # THE CMDLET THE ACTION JUST ECHOED HAS TO SURVIVE THIS.
            #
            # Replacing ItemsSource re-selects a row, and the tree's selection
            # handler writes the SELECTED STEP's command onto the same line -
            # so every edit that rebuilds published its cmdlet and had it
            # overwritten in the same frame. Nobody could read the command off
            # a rename, an add, a remove or a partition edit, which is the one
            # thing this line exists for. $book.Quiet silences banking here; it
            # does not silence that write, and it must not - clicking a row is
            # how the line gets filled in the first place.
            $echo = [string] $command.Text

            $book.Quiet = $true
            $tree.ItemsSource = $state.Root
            $book.Quiet = $false

            $command.Text = $echo

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

                # DID IT ACTUALLY CHANGE? Marking the window dirty
                # unconditionally lights Save up for walking through a sequence
                # and reading it, and then Save writes a file with no edit in
                # it - re-serialising a document whose comments and ordering are
                # the reason this editor splices lines at all.
                # tests/unit/ConsoleLineChange.Tests.ps1.
                if (-not (& $call 'Test-HDTConsoleLineChange' `
                            -Before ([string[]] $before) -After ([string[]] @($book.Line)))) {
                    return
                }

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

        # THE STEP HAS TO OWN A TABLE BEFORE ANY OF THE FIVE CAN EDIT ONE.
        #
        # A step that names uefi-standard carries no rows, so every one of these
        # commands would refuse it - which is why the buttons were dark, on every
        # sequence the standard client template produces. This writes the layout
        # out first, ONCE, and says on the strip that it did: after it the step
        # no longer follows the built-in, and that is a change somebody is
        # entitled to see rather than discover.
        #
        # IT RETURNS FALSE RATHER THAN THROWING when the layout cannot be
        # expanded - a name picked by a variable at run time is an ordinary
        # document, not a mistake, and the note already on the strip says so.
        $ensureTable = {
            $current = & $call 'Get-HDTConsolePartitionRow' -Line $book.Line -Path $Path -Name $book.Selected

            if ($current.HasTable) { return $true }

            if (-not $current.CanExpand) {
                $command.Text = [string] $current.ExpandNote
                return $false
            }

            & $partitionAttempt {
                $book.Line = @(Expand-HDTStepPartition -Line $book.Line -Name $book.Selected -Confirm:$false)
            } ([string] $current.ExpandCommand)

            return $true
        }.GetNewClosure()

        # THE DIALOG, AND WHAT COMES BACK FROM IT. It returns a hashtable ready
        # to splat at Add-HDTStepPartition or Set-HDTStepPartition, or $null if
        # it was cancelled - so the two handlers below differ only in which
        # command they call.
        $partitionDialog = {
            param([object] $Row)

            $view = & $call 'Get-HDTConsolePartitionRow' -Line $book.Line -Path $Path -Name $book.Selected

            # THE STEP GOES IN because the dialog prints the command OK would
            # run, and that line names the step whose table is being edited.
            $dialog = $editorHost.ShowPartitionProperties($PartitionXaml, $Row, $view.Unit, $Theme,
                $window, $book.Selected)
            if ($null -eq $dialog) { return $null }

            return $dialog
        }.GetNewClosure()

        $partitionAdd.Add_Click({
                # BEFORE THE DIALOG, not after it: a person who filled eight
                # boxes and then met "this step names a layout" would have
                # filled them for nothing.
                if (-not (& $ensureTable)) { return }

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

                if (-not (& $ensureTable)) { return }

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
                if (-not (& $ensureTable)) { return }

                $subject = [string] $book.Partition

                & $partitionAttempt {
                    $book.Line = @(Remove-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject -Confirm:$false)

                    $book.Partition = ''
                } ("Remove-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}'" -f $book.Selected, $subject)
            }.GetNewClosure())

        $partitionUp.Add_Click({
                if ([string]::IsNullOrWhiteSpace($book.Partition)) { return }
                if (-not (& $ensureTable)) { return }

                $subject = [string] $book.Partition

                & $partitionAttempt {
                    $book.Line = @(Move-HDTStepPartition -Line $book.Line -Name $book.Selected `
                            -Partition $subject -Direction Up -Confirm:$false)
                } ("Move-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}' -Direction Up" -f $book.Selected, $subject)
            }.GetNewClosure())

        $partitionDown.Add_Click({
                if ([string]::IsNullOrWhiteSpace($book.Partition)) { return }
                if (-not (& $ensureTable)) { return }

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
        # A RENAME BANKS LIKE EVERY OTHER BOX ON THIS WINDOW, and that is the
        # whole fix.
        #
        # It used to commit from LostFocus alone, which RACES the tree's
        # selection change: clicking another step moves focus first, so the
        # rename spliced AND rebuilt ItemsSource in the middle of the click that
        # was still choosing a row. What the selection handler then read was a
        # row from the tree that no longer existed, so $book.Selected ended up
        # holding the OLD name - and coming back to the step found nothing under
        # it, which is why the name box came up disabled and Remove went dark.
        #
        # $book.Bank is the controlled moment: it runs BEFORE the pane refills
        # and asks for no rebuild, exactly as the property, image, command and
        # condition boxes already do.
        $nameWrite = {
                param([bool] $Rebuild = $true)

                if ($book.Quiet) { return }

                $typed = [string] $stepNameBox.Text
                if ([string]::IsNullOrWhiteSpace($typed)) { return }

                $was = [string] $book.Selected
                if ($typed -eq $was) { return }

                # THE BOX MAY BE SHOWING A STEP THAT IS NO LONGER SELECTED. Bank
                # runs from inside the selection change, and a rename is only
                # this step's if the document still holds the name it started
                # with.
                if ([string]::IsNullOrWhiteSpace($was)) { return }

                & $partitionAttempt {
                    $book.Line = @(Set-HDTStepProperty -Line $book.Line -Name $was `
                            -Property 'name' -Value $typed -Confirm:$false)

                    $book.Selected = $typed
                } ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'name' -Value '{1}'" -f $was, $typed) $Rebuild
            }.GetNewClosure()

        # THE TREE HAS TO CATCH UP AFTER A BANK, JUST NOT DURING THE CLICK.
        #
        # Banking runs from inside the selection change and asks for no rebuild,
        # because replacing ItemsSource there pulls the rows out from under the
        # handler that is still choosing one. But a RENAME changes what the rows
        # SAY - so the tree went on showing the old name, and clicking that row
        # again selected a step the document no longer had: the name box came up
        # disabled and Remove went dark.
        #
        # Rebuilding at Background priority happens after the click has finished
        # with the tree, and $rebuild restores the selection BY NAME, so the row
        # that comes back is the one the person is looking at.
        #
        # BUILT HERE, WHERE $rebuild IS A LOCAL. GetNewClosure captures locals
        # only, and a closure made inside the handler would capture nothing.
        $deferRebuild = [action] {
                & $rebuild
            }.GetNewClosure()

        $book.Bank = {
                # THE NAME FIRST, because every other write addresses the step BY
                # name - banking a property under the old name and then renaming
                # would splice two different steps.
                & $nameWrite $false
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
        #
        # IT MUST NOT REBUILD THE TREE FROM HERE. Clicking another step moves
        # focus out of this box BEFORE the tree has finished choosing a row, so
        # rebuilding synchronously replaced ItemsSource mid-click; the selection
        # handler then read a row that no longer existed and left $book.Selected
        # holding the OLD name. Coming back to the step found nothing under that
        # name, which is why the name box came up DISABLED and Remove went dark.
        # Committing with no rebuild and queueing $deferRebuild at Background
        # lets the click finish first, and $rebuild restores the selection by
        # name - by then the name of whichever step the click landed on.
        $stepNameBox.Add_LostFocus({
                $before = [string[]] @($book.Line)

                & $nameWrite $false

                if (-not (& $call 'Test-HDTConsoleLineChange' `
                            -Before ([string[]] $before) -After ([string[]] @($book.Line)))) {
                    return
                }

                [void] $stepNameBox.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background, $deferRebuild)
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
                $beforeBank = [string[]] @($book.Line)

                if ($null -ne $book.Bank -and -not $book.Quiet) { & $book.Bank }

                # AND IF THAT CHANGED THE DOCUMENT, LET THE TREE CATCH UP - after
                # this click, not inside it. See $deferRebuild.

                if (-not $book.Quiet -and
                    (& $call 'Test-HDTConsoleLineChange' -Before $beforeBank -After ([string[]] @($book.Line)))) {

                    # PRIORITY FIRST. BeginInvoke(Delegate, params Object[])
                    # also matches when the priority is passed second, and then
                    # the priority is an ARGUMENT to an action that takes none -
                    # which is silently nothing happening at all.
                    [void] $tree.Dispatcher.BeginInvoke(
                        [System.Windows.Threading.DispatcherPriority]::Background, $deferRebuild)
                }

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
        return $window
}
