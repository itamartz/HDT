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

        # BUILDING THE WINDOW AND SHOWING IT ARE TWO DIFFERENT JOBS, and only
        # the second one needs a desktop. New-HDTConsoleView loads the markup,
        # paints the palette and hangs every handler off the tree; ShowDialog is
        # what blocks. Splitting them is what lets the wiring be reached at all -
        # a WPF window builds perfectly well on a thread that never shows it.
        $window = New-HDTConsoleView -ConsoleHost $this -Xaml $Xaml -Title $Title `
            -Node $Node -Theme $Theme -Size $Size -RefreshSecond $RefreshSecond `
            -NewSequenceXaml $NewSequenceXaml `
            -ImportOperatingSystemXaml $ImportOperatingSystemXaml `
            -ImportApplicationXaml $ImportApplicationXaml `
            -ApplicationDependencyXaml $ApplicationDependencyXaml `
            -ApplicationDetectionXaml $ApplicationDetectionXaml `
            -Fill $Fill -NewWorkspaceXaml $NewWorkspaceXaml

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
    # THE BOXES ARE BUILT AT RUNTIME BECAUSE THE TYPE DECIDES THEM, and that
    # happens in New-HDTConsoleDetectionDialog rather than here - see below.
    $service | Add-Member -MemberType ScriptMethod -Name ShowApplicationDetection -Value {
        param([string] $Xaml, [string] $Workspace, [string] $Id, [object] $Detect,
            [object] $Theme, [object] $Owner)

        # BUILDING THE WINDOW AND SHOWING IT ARE TWO JOBS, and only the second
        # needs a desktop. New-HDTConsoleDetectionDialog does the first, which
        # is what lets Pester type into the boxes and ask what the window made
        # of it; ShowDialog is the part that blocks, and it stays here.
        $dialog = New-HDTConsoleDetectionDialog -Xaml $Xaml -Workspace $Workspace -Id $Id `
            -Detect $Detect -Theme $Theme -Owner $Owner -ConsoleHost $this

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

            # WHICH OF THREE COMPLAINTS GETS THE ONE LINE, and whether Create
            # survives it. THE ELEVATION SENTENCE OUTRANKS THE OTHERS because it
            # is the one nothing on this page can fix - and it warns without
            # blocking, since the folder is still worth writing and the share
            # can be added later. That asymmetry is the kind that gets tidied
            # up by somebody who did not know why, so it is asserted in
            # tests/unit/ConsoleNewWorkspaceMessage.Tests.ps1 now.
            $say = & $call 'Get-HDTConsoleNewWorkspaceMessage' `
                -CanCreate ([bool] $answer.CanCreate) -Message ([string] $answer.Message) `
                -ShareMessage ([string] $share.Message) -Publishing $publishing -Elevated ([bool] $elevated)

            $create.IsEnabled = [bool] $say.CanCreate
            $messageText.Text = [string] $say.Message

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

        # WHAT WAS TYPED, AND ONLY WHAT WAS TYPED. An empty box writes no
        # variable rather than an empty one: a sequence carrying
        # HDTOrgName: '' looks like a decision somebody made.
        #
        # IT IS ONE SCRIPTBLOCK BECAUSE THE FOOTER AND THE BUTTON MAY NOT
        # DISAGREE. They did: the line named three parameters and Create passed
        # a fourth, so an administrator who copied it - the one thing DESIGN 12
        # says the line is for - got a sequence with no operating system and no
        # administrator password. Two copies of this loop is how that happens
        # again, so there is one, and both callers read it.
        $typed = {
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

            return $variable
        }.GetNewClosure()

        # WHETHER THE ANSWERS CAN BE USED, ON EVERY KEYSTROKE. The alternative
        # is a wizard that takes seven answers and refuses on the last press.
        $check = {
            $answer = & $call 'Test-HDTConsoleNewSequence' -Workspace $Workspace `
                -Id ([string] $idBox.Text) -Name ([string] $nameBox.Text)

            $create.IsEnabled = [bool] $answer.CanCreate
            $messageText.Text = [string] $answer.Message

            $commandText.Text = & $call 'Get-HDTConsoleNewSequenceCommand' `
                -Workspace $Workspace -Id ([string] $idBox.Text) -Name ([string] $nameBox.Text) `
                -Template ([string] $templateBox.SelectedValue) `
                -Variable (& $typed) -Setting ([object[]] @($offer.Setting))
        }.GetNewClosure()

        $idBox.Add_TextChanged({ & $check }.GetNewClosure())
        $nameBox.Add_TextChanged({ & $check }.GetNewClosure())
        $templateBox.Add_SelectionChanged({ & $check }.GetNewClosure())

        # THE OTHER FOUR BOXES MOVE THE LINE TOO, now that the line carries what
        # they write. Before, typing an organisation changed the file and not a
        # character on screen.
        $imageBox.Add_SelectionChanged({ & $check }.GetNewClosure())
        $fullNameBox.Add_TextChanged({ & $check }.GetNewClosure())
        $orgBox.Add_TextChanged({ & $check }.GetNewClosure())
        $passwordBox.Add_TextChanged({ & $check }.GetNewClosure())

        & $check

        $this.NewSequencePath = ''
        $dialogHost = $this

        $create.Add_Click({
                # THE SAME BLOCK THE FOOTER READ. See $typed above.
                $variable = & $typed

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
            [string] $Xaml, [object] $Row, [object[]] $Unit, [object] $Theme, [object] $Owner,
            [string] $Step
        )

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
        $commandText = $dialog.FindName('HDTVolumeCommandText')
        $ok = $dialog.FindName('HDTVolumeOkButton')

        $unitBox.ItemsSource = $Unit
        $unitBox.SelectedIndex = 0

        # THE ROW THIS DIALOG WOULD LOOK UP. Empty for New, and for Edit the name
        # the document still carries - a rename is a value Set-HDTStepPartition
        # writes, not the row it finds.
        $existing = ''
        if ($null -ne $Row) { $existing = [string] $Row.Name }

        # WHAT OK WOULD RUN, ON EVERY KEYSTROKE. See
        # Get-HDTConsolePartitionCommand: the editor prints the same line, but
        # only once this window has closed.
        $describe = {
            $commandText.Text = & $call 'Get-HDTConsolePartitionCommand' `
                -Step $Step -Partition ([string] $nameBox.Text) -Existing $existing
        }.GetNewClosure()

        $nameBox.Add_TextChanged({ & $describe }.GetNewClosure())

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
        & $describe

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

        # BUILDING THE WINDOW AND SHOWING IT ARE TWO DIFFERENT JOBS, and only
        # the second one needs a desktop. See New-HDTConsoleView.
        $window = New-HDTConsoleEditorView -ConsoleHost $this `
            -Xaml $Xaml -Title $Title -Path $Path -Node $Node -Line $Line `
            -Catalog $Catalog -Theme $Theme -Size $Size -PartitionXaml $PartitionXaml `
            -Editor $Editor

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
            [object[]] $Component, [object[]] $SelectionProfile, [object] $Theme, [object] $Size,
            [object[]] $TimeZone = @()
        )

        # BUILDING THE WINDOW AND SHOWING IT ARE TWO DIFFERENT JOBS, and only
        # the second one needs a desktop. See New-HDTConsoleView.
        $window = New-HDTConsoleBootImageView -ConsoleHost $this `
            -Xaml $Xaml -Path $Path -Line $Line -Component $Component `
            -SelectionProfile $SelectionProfile -Theme $Theme -Size $Size -TimeZone $TimeZone

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # =====================================================================
    # THE DRIVER PROPERTIES WINDOW
    # =====================================================================
    #
    # Workbench's driver Properties, opened by a double-click on the grid.

    $service | Add-Member -MemberType ScriptMethod -Name ShowDriver -Value {
        param([string] $Xaml, [string] $Root, [object] $Driver, [object] $Theme, [object] $Size)

        $window = New-HDTConsoleDriverView -ConsoleHost $this `
            -Xaml $Xaml -Root $Root -Driver $Driver -Theme $Theme -Size $Size

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    # =====================================================================
    # THE SELECTION PROFILES WINDOW
    # =====================================================================
    #
    # Workbench's Advanced Configuration \ Selection Profiles. It is reached
    # from TWO places - the share tree, and the Edit profiles button beside the
    # Windows PE picker - and both come through here, so there is one window and
    # not two implementations of it.

    $service | Add-Member -MemberType ScriptMethod -Name ShowSelectionProfile -Value {
        param(
            [string] $Xaml, [string] $Root, [string[]] $Line,
            [object[]] $SelectionProfile, [object[]] $Folder, [object] $Theme, [object] $Size
        )

        $window = New-HDTConsoleSelectionProfileView -ConsoleHost $this `
            -Xaml $Xaml -Root $Root -Line $Line -SelectionProfile $SelectionProfile `
            -Folder $Folder -Theme $Theme -Size $Size

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

    # THE WORK IS A PARAMETER, NOT A HARD-CODED COMMAND. This ran only
    # Update-HDTBootImage until 2026-08-27, when importing a 2.38 GB Dell driver
    # pack froze the console for 86 seconds on the dispatcher - the same defect
    # this window was built to cure, in a second place. Everything below the
    # dispatch is already generic: the queue, the timer, the elapsed clock, the
    # EndInvoke that surfaces a runspace which died before its command ran. Only
    # four lines named the build.
    #
    # Duplicating it for imports was the safer-looking option and was rejected:
    # two copies of subtle cross-runspace code means the next fix has to be made
    # twice, and the second copy is the one that gets missed.
    #
    # $Command IS A NAME AND $Argument IS A PLAIN HASHTABLE, deliberately - both
    # cross a runspace boundary, where a scriptblock would arrive bound to a
    # session state the other side cannot invoke. That is the same trap the
    # block comment above records about the sink.
    $service | Add-Member -MemberType ScriptMethod -Name ShowBuildProgress -Value {
        param(
            [string] $Xaml, [string] $WorkspaceRoot, [string] $ModulePath,
            [object] $Theme, [object] $Size, [string] $Command, [object] $Argument,
            [string] $StringPage, [string] $LogFile
        )

        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Icon = Get-HDTConsoleWindowIcon

        # The text comes out of Strings\<culture>.psd1, not out of the markup,
        # and before the first report replaces the starting step.
        #
        # WHICH PAGE DEPENDS ON WHAT IS RUNNING. One window, two jobs: a window
        # headed 'Updating Boot Image' while it expands a driver pack is lying to
        # the person watching it.
        $page = 'BuildProgress'
        if (-not [string]::IsNullOrWhiteSpace($StringPage)) { $page = $StringPage }

        [void] (Set-HDTWindowText -Root $window -String (Get-HDTStringTable -Page $page))

        $window.Left = [double] $Size.Left
        $window.Top = [double] $Size.Top
        $window.Owner = $this.Window

        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $window.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }

        # THE DOOR, HELD AT METHOD SCOPE SO A HANDLER CAN CAPTURE IT.
        # GetNewClosure rebinds a handler to the session state of whoever called
        # this method, where only EXPORTED functions resolve - so a handler that
        # calls Get-HDTHandlerCall itself gets "not recognized" and takes the
        # window down with it. The method body still runs in the module's own
        # state, which is the one place this can be asked for.
        $call = Get-HDTHandlerCall

        $titleText = $window.FindName('HDTBuildTitleText')
        $pathText = $window.FindName('HDTBuildPathText')
        $stepText = $window.FindName('HDTBuildStepText')
        $detailText = $window.FindName('HDTBuildDetailText')
        $countText = $window.FindName('HDTBuildCountText')
        $elapsedText = $window.FindName('HDTBuildElapsedText')
        $bar = $window.FindName('HDTBuildBar')
        $log = $window.FindName('HDTBuildLog')
        $close = $window.FindName('HDTBuildCloseButton')
        $logButton = $window.FindName('HDTBuildLogButton')

        # THE BANNER IS THE STRING TABLE'S, NOT A LITERAL HERE. This line used to
        # read $titleText.Text = 'Updating Boot Image', set immediately AFTER
        # Set-HDTWindowText had applied the page - so it clobbered the page every
        # time and the ImportProgress wording was dead text that no test noticed.
        # The string-table contract checks that a key names a real control, not
        # that the value it wrote survives the next ten lines. Opening the window
        # is what noticed.
        #
        # BuildProgress carries the same 'Updating Boot Image' it always did, so
        # the boot image path is unchanged.
        #
        # AND THE WINDOW CHROME FOLLOWS THE BANNER. HDTBuildProgress.xaml carries
        # Title="Updating Boot Image" as a literal and nothing ever set
        # $window.Title, so the task bar and the title bar said 'Updating Boot
        # Image' while the window expanded a driver pack - the one part of a
        # window somebody reads when it is behind three others.
        $window.Title = [string] $titleText.Text
        $pathText.Text = $WorkspaceRoot

        $line = New-Object -TypeName System.Collections.ObjectModel.ObservableCollection[string]
        $log.ItemsSource = $line

        $queue = [System.Collections.Queue]::Synchronized((New-Object -TypeName System.Collections.Queue))

        # THE BUILD, IN ITS OWN RUNSPACE. The module is imported by path rather
        # than by name: a console started from a working copy is not running the
        # module that Import-Module Hephaestus would find.
        $shell = [powershell]::Create()

        [void] $shell.AddScript({
                param($ModulePath, $Command, $Argument, $Queue)

                Import-Module -Name $ModulePath -Force -ErrorAction Stop

                # CREATED HERE, on this side of the boundary. See the block
                # comment above: a sink made in the window's runspace would carry
                # scriptblocks this one cannot invoke.
                $progress = New-HDTBuildProgress -Queue $Queue

                # COPIED RATHER THAN SPLATTED DIRECTLY, so the caller's hashtable
                # is not mutated by the Progress key - it belongs to a live window
                # on the other thread.
                $splat = @{}
                foreach ($key in @($Argument.Keys)) { $splat[[string] $key] = $Argument[$key] }
                $splat['Progress'] = $progress

                # -Confirm:$false because every command this runs carries
                # SupportsShouldProcess and a prompt on a runspace with no host
                # is a window that waits forever for an answer nobody can give.
                #
                # AND THE END IS GUARANTEED HERE, NOT LEFT TO THE COMMAND.
                # Update-HDTBootImage reports its own completion; Import-HDTDriver
                # has half a dozen exits - ThrowTerminatingError twice, a
                # ShouldProcess refusal, the archive branch - and the first import
                # through this window extracted 269 drivers, listed every one, and
                # then said 'FAILED - the build ended without saying why'. A
                # successful import reported as a failure, because nothing
                # enqueued an ending.
                #
                # A command that DOES report keeps its own words: Completed is
                # checked, so this adds an ending only where one is missing and
                # never overwrites a failure with a success.
                try {
                    & $Command @splat -Confirm:$false

                    if (-not $progress.Completed) { $progress.Complete($true, '') }
                } catch {
                    if (-not $progress.Completed) {
                        $progress.Complete($false, [string] $_.Exception.Message)
                    }

                    # RETHROWN so EndInvoke still surfaces it. The window reads
                    # the queue first and the error stream second; swallowing it
                    # here would lose the stack for anything the message alone
                    # does not explain.
                    throw
                }
            })

        # THE ORDER IS THE param() BLOCK'S ORDER. AddArgument binds positionally,
        # so a reordered param() and an unreordered set of these bind silently
        # and wrongly rather than failing.
        [void] $shell.AddArgument($ModulePath)
        [void] $shell.AddArgument($Command)
        [void] $shell.AddArgument($Argument)
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

            # WHEN ANYTHING WAS LAST HEARD. The bar sweeps on SILENCE rather
            # than on elapsed time - see Get-HDTConsoleBuildBusy - because a
            # step that reports seventy times over seven minutes has a position
            # worth keeping, and one that reports once and works for ninety
            # seconds does not.
            ReportAt  = [datetime]::UtcNow
        }

        $timer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)

        $drain = {
                # ITS OWN DOOR, because this one is not a closure either - see
                # $writeRow. A $call inherited by luck from whichever scope
                # invoked it is a null reference waiting for the caller that is
                # not a closure, and this one runs on a timer where a throw is
                # silent.
                $call = Get-HDTHandlerCall

                $elapsed = [datetime]::UtcNow - $startedAt

                if (-not $book.Finished) {
                    # BOTH CLOCKS, because they answer different questions: the
                    # total says how long to wait, and the per-step says whether
                    # anything is happening at all.
                    $onStep = [datetime]::UtcNow - $book.StepAt

                    $elapsedText.Text = 'elapsed {0:mm\:ss}   -   {1:N0}s on "{2}"' -f
                        $elapsed, $onStep.TotalSeconds, $book.StepText

                    # A FROZEN BAR AND A HUNG BUILD LOOK THE SAME. This is the
                    # only thing on the window that says "working" during a
                    # DISM call that will not report again for a minute.
                    $bar.IsIndeterminate = [bool] (& $call 'Get-HDTConsoleBuildBusy' `
                            -QuietSecond ([datetime]::UtcNow - $book.ReportAt).TotalSeconds)
                }

                # DEQUEUED DIRECTLY, not through the sink: the sink belongs to
                # the other runspace, and the queue is the only thing shared.
                while ($queue.Count -gt 0) {
                    $report = $queue.Dequeue()

                    # EVERY LINE THIS WINDOW SHOWS FOR ONE REPORT, composed away
                    # from the timer. The detail belongs on the LOG LINE and not
                    # only in the label - step 8 reports once per cab, and a
                    # line carrying the title alone printed "Applying the
                    # optional components" nineteen times - and the per-step
                    # clock restarts on a new TITLE rather than on every report,
                    # or it never shows that a step has been running for a
                    # minute. tests/unit/ConsoleBuildProgress.Tests.ps1.
                    $show = & $call 'Get-HDTConsoleBuildProgress' -Report $report `
                        -Elapsed $elapsed -OnStep ([datetime]::UtcNow - $book.StepAt) `
                        -StepText ([string] $book.StepText)

                    $stepText.Text = [string] $show.StepText
                    $detailText.Text = [string] $show.DetailText

                    # NEWS: the bar measures again, from here.
                    $book.ReportAt = [datetime]::UtcNow
                    $bar.IsIndeterminate = $false
                    $bar.Maximum = [double] $show.BarMaximum
                    $bar.Value = [double] $show.BarValue

                    [void] $line.Add([string] $show.LogLine)

                    if ($show.Finished) {
                        $book.Finished = $true
                        $book.Succeeded = [bool] $report.Succeeded

                        if ($show.IsFailure) { $stepText.Foreground = $window.Resources['HDTErrorBrush'] }

                        $elapsedText.Text = [string] $show.ElapsedText
                        $close.IsEnabled = [bool] $show.CloseEnabled
                        continue
                    }

                    $countText.Text = [string] $show.CountText

                    if ($show.RestartStepClock) {
                        $book.StepAt = [datetime]::UtcNow
                        $book.StepText = [string] $report.Title
                    }

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

                    # THE SAME COMPOSITION AS THE LOOP ABOVE, and deliberately
                    # the same call: this window used to spell the completion
                    # lines out twice, which is two places for "done - " and
                    # "FAILED - " to drift apart.
                    $show = & $call 'Get-HDTConsoleBuildProgress' -Report $final `
                        -Elapsed $elapsed -StepText ([string] $book.StepText)

                    $book.Finished = $true
                    $book.Succeeded = [bool] $final.Succeeded

                    $stepText.Text = [string] $show.StepText
                    $detailText.Text = [string] $show.DetailText
                    $bar.Value = [double] $show.BarValue

                    if ($show.IsFailure) { $stepText.Foreground = $window.Resources['HDTErrorBrush'] }

                    [void] $line.Add([string] $show.LogLine)

                    $elapsedText.Text = [string] $show.ElapsedText
                    $close.IsEnabled = [bool] $show.CloseEnabled
                }

                $timer.Stop()

                # A BUILD THAT DIED WITHOUT REPORTING. Update-HDTBootImage
                # reports its own failure, but a runspace can also fail before
                # the command runs at all - a module that will not import, for
                # instance - and that error exists only in this stream.
                if (-not $book.Finished) {
                    # EndInvoke IS WHAT RAISES THE RUNSPACE'S TERMINATING ERROR.
                    # A build that threw outside its own try - the ISO step is
                    # outside it - reports nothing and leaves Streams.Error
                    # empty, and the window then said "ended without saying why"
                    # about a failure PowerShell was holding all along. Which of
                    # the three answers wins is
                    # tests/unit/ConsoleBuildFailure.Tests.ps1.
                    $raised = ''

                    try {
                        [void] $shell.EndInvoke($handle)
                    } catch {
                        $raised = [string] $_.Exception.Message
                    }

                    $streamed = [string[]] @(@($shell.Streams.Error) |
                            ForEach-Object { [string] $_.Exception.Message })

                    $failure = & $call 'Get-HDTConsoleBuildFailure' -Raised $raised -Streamed $streamed

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

        # EVERY LINE THIS WINDOW SHOWED, WRITTEN AND OPENED.
        #
        # The log was in the list and nowhere else, so closing the window threw
        # away the record of what the build did - including the build that
        # failed, which is the one worth reading. It writes on the press rather
        # than at the end so it works MID-BUILD: the moment a step has been
        # silent for two minutes is the moment somebody wants to read what led
        # up to it.
        #
        # A FAILURE TO WRITE IS SHOWN AND NOT THROWN. This button is pressed
        # when something has already gone wrong, and a share that refuses the
        # write must not take the window down on top of it.
        $logButton.Add_Click({
                try {
                    # THE IMAGE'S OWN NAME, from the document rather than from
                    # the banner - the banner carries the SHARE root, and
                    # deriving a name from it produces Share.build.log. A
                    # document that will not read leaves the name empty, which
                    # Get-HDTConsoleBuildLogPath answers for.
                    # WHAT RAN DECIDES WHERE THE LOG GOES. This derived the boot
                    # image's name unconditionally, so a driver import through
                    # this window wrote its lines over Boot\<image>.build.log -
                    # DESTROYING the build log of an image it had nothing to do
                    # with, and answering "where is the import log" with a file
                    # named after a boot image.
                    $path = $LogFile

                    if ([string]::IsNullOrWhiteSpace($path)) {
                        # THE IMAGE'S OWN NAME, from the document rather than from
                        # the banner - the banner carries the SHARE root, and
                        # deriving a name from it produces Share.build.log. A
                        # document that will not read leaves the name empty, which
                        # Get-HDTConsoleBuildLogPath answers for.
                        $imageName = ''

                        try {
                            $imageName = [string] (Import-HDTWorkspaceDocument -Path (
                                    [System.IO.Path]::Combine($WorkspaceRoot, 'workspace.yaml'))).BootImage.Name
                        } catch {
                            $imageName = ''
                        }

                        $path = & $call 'Get-HDTConsoleBuildLogPath' -WorkspaceRoot $WorkspaceRoot -Name $imageName
                    }

                    [System.IO.File]::WriteAllLines($path, [string[]] @($line))

                    [void] (Start-Process -FilePath $path)
                } catch {
                    [void] $line.Add(('the log could not be written: {0}' -f $_.Exception.Message))
                    $log.ScrollIntoView($line[$line.Count - 1])
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
