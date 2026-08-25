function New-HDTConsoleBootImageView {
    <#
        .SYNOPSIS
            Builds the Windows PE window and wires it, without showing it.

        .DESCRIPTION
            THE WINDOWS PE WINDOW, which is Deployment Workbench's deployment
            share Properties: the boot image's name and architecture, its
            optional components, its drivers and its customisations.


            BUILDING A WINDOW AND SHOWING ONE ARE TWO DIFFERENT JOBS, and only
            the second needs a desktop. This loads the markup, paints the
            palette and hangs every handler off the tree; the ScriptMethod that
            calls it then calls ShowDialog, which is the part that blocks. See
            New-HDTConsoleView for the whole reasoning and for why the rule in
            .planning/WPF-FIRST.md was narrowed to allow it.

            THE HOST IS INJECTED RATHER THAN BEING $this. Inside a handler $this
            is the control that raised the event, and a ScriptMethod's enclosing
            scope is not in scope either - so the handlers close over the host by
            name, and that name arrives as a parameter.

            IT SHOWS NOTHING AND RETURNS THE WINDOW.

        .PARAMETER ConsoleHost
            The service object the handlers write their answer to.

        .PARAMETER Xaml
            The boot image markup.

        .PARAMETER Path
            The workspace document being edited.

        .PARAMETER Line
            The document, as lines.

        .PARAMETER Component
            The optional components that can be ticked.

        .PARAMETER SelectionProfile
            The driver profiles that can be chosen.

        .PARAMETER Theme
            The palette, as brushes.

        .PARAMETER Size
            The size to open at.

        .PARAMETER TimeZone
            The time zones the box offers.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built and wired, never shown.

        .EXAMPLE
            New-HDTConsoleBootImageView -ConsoleHost $service -Xaml $xaml

        .EXAMPLE
            $window = New-HDTConsoleBootImageView -ConsoleHost $host -Xaml $xaml
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
        [Parameter()] [AllowEmptyString()] [string] $Path = '',
        [Parameter()] [AllowNull()] [string[]] $Line = @(),
        [Parameter()] [AllowNull()] [object[]] $Component = @(),
        [Parameter()] [AllowNull()] [object[]] $SelectionProfile = @(),
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Size = $null,
        [Parameter()] [AllowNull()] [object[]] $TimeZone = @()
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
        $window.Owner = $ConsoleHost.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        $ConsoleHost.Answer = ''
        $imageHost = $ConsoleHost

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

        $driverBox = $window.FindName('HDTSelectionProfileBox')

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

            # THROUGH THE DOOR, because this block is a closure. A closure is
            # bound to its own dynamic module and resolves commands THERE, so a
            # private helper named directly is "not recognized" - which is the
            # same reason every handler in this window reaches its helpers
            # through $call. Test-HDTBootImageCertificatePassword above is
            # exported and needs no door.
            $book.View = & $call 'Get-HDTConsoleBootImageSetting' -Line $book.Line -Path $Path `
                -Component $Component -SelectionProfile $SelectionProfile `
                -HasCertificatePassword ([bool] $stored) -TimeZone $TimeZone
            return $book.View
        }.GetNewClosure()

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

        }.GetNewClosure()

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
        }.GetNewClosure()

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

                # TWO GUARDS THAT CANNOT BE COLLAPSED, and both were paid for.
                # ALREADY THERE means WPF raised this and not a person - the
                # Features tab builds its checkboxes on first click and each
                # raises Checked as it takes its bound value, which killed the
                # window on that click. A LOCKED ROW is not the document's to
                # name: the six the engine always applies are ticked and absent
                # from the document, so they PASS the first guard and would be
                # written by the click that first draws them. That is how a
                # share which named nothing ended up naming ten.
                # tests/unit/ConsoleComponentWrite.Tests.ps1.
                if (-not (& $call 'Test-HDTConsoleComponentWrite' -Row $row `
                            -Declared ([string[]] @($book.View.DeclaredName)) -Ticking)) {
                    return
                }

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
                # ever naming them, so no lock test is needed on this side.
                if (-not (& $call 'Test-HDTConsoleComponentWrite' -Row $row `
                            -Declared ([string[]] @($book.View.DeclaredName)))) {
                    return
                }

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
        # A CLOSURE, AND IT HAS TO BE. This block reads $startList, $book,
        # $commandText and $fillLists - all locals of this function - and it is
        # invoked from { & $move Up }.GetNewClosure(), which captured $move and
        # NOTHING ELSE. Without this, pressing Up or Down on the Start Command
        # list threw "the variable '$startList' cannot be retrieved" on the
        # dispatcher, which takes the window down. Same class as $writeRow and
        # $drain, found by pressing every button in
        # tests/unit/ConsoleButtonPress.Tests.ps1.
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
        }.GetNewClosure()

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
        return $window
}
