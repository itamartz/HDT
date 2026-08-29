# ONE PARSE PER DOCUMENT, NOT ONE PER CLICK.
#
# $reflect runs at the end of every selection change and used to hand the lines
# to Import-HDTSequenceDocument every time - 125ms of a 365ms click, spent
# re-reading text that had not moved since the last click. The fix that came
# before this one collapsed FOUR parses per refresh into one; this collapses the
# one that is left into one per EDIT.
#
# THE INVALIDATION SIGNAL IS THE LINES THEMSELVES, and that is the whole
# argument for the cache being safe. It is not a flag somebody has to remember
# to clear on the add path, the remove path, the move path, the rename path, the
# undo path and the reload path - it is Test-HDTConsoleLineChange over the text,
# which every one of those paths changes by definition. A cache keyed on an
# event you can forget to raise is the one that goes stale; this one cannot be
# forgotten, only deleted.
#
# THE TEST THAT MATTERS IS THE LAST ONE. A stale cache is invisible to anything
# that measures speed - it makes the window FASTER - and shows up only as a pane
# describing the document as it was before the edit. So the tick box is clicked
# for real and read back for real, with nothing mocked.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Hardware rendering on a build agent paints blank often enough to look like
    # a wiring failure when it is not.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, so the window these tests drive and the one the editor
    # opens cannot drift apart.
    $script:editorXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTSequenceEditor.xaml'))

    $script:editorPath = 'C:\ws\TaskSequences\DEMO-05\sequence.yaml'

    # FLAT, so every row is a root and the tree's own ItemsSource holds all of
    # them - a step inside a group has no container until its group is expanded,
    # and an unexpanded row cannot be selected by a test.
    $script:editorYaml = [string[]] @(
        'schemaVersion: 1'
        'id: DEMO-05'
        'name: Windows 11 bare metal'
        'variables:'
        '  HDTOSImage: Win11-LTSC-2024'
        'steps:'
        '  - name: Prepare Boot'
        '    type: Validate'
        '    minRamMB: 2048'
        '  - name: Stamp The Build'
        '    type: SetVariable'
        '    variable: HDTBuild'
        '    value: one'
        '  - name: Restart Once'
        '    type: Restart'
    )

    function New-HDTTestParseCacheWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        # -Node TAKES THE ROOTS, not the state object. Handing it the state
        # builds a tree of one row carrying no steps at all, and every click
        # test against it passes by finding nothing to break.
        $state = Get-HDTConsoleEditorState -Line $script:editorYaml -Path $script:editorPath

        $window = New-HDTConsoleEditorView `
            -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
            -Xaml $script:editorXaml -Title 'DEMO-05' -Path $script:editorPath `
            -Node ([object[]] @($state.Root)) -Line $script:editorYaml `
            -Catalog ([object[]] @(Get-HDTConsoleStepCatalog)) -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 0; Top = 0 }) `
            -Editor $state

        # AN ELEMENT THAT WAS NEVER SHOWN HAS NO SIZE, and a tree with no size
        # generates no containers - so nothing below could be selected.
        $content = $window.Content
        $content.Measure([System.Windows.Size]::new(1180, 760))
        $content.Arrange([System.Windows.Rect]::new(0, 0, 1180, 760))
        $content.UpdateLayout()

        return $window
    }

    function Wait-HDTTestDispatcher {
        [CmdletBinding()]
        [OutputType([void])]
        param([Parameter(Mandatory = $true)] [object] $Window)

        # THE REBUILD AFTER A BANK IS DELIBERATELY DEFERRED to Background, so
        # draining the queue to that priority is what lets it run.
        $Window.Dispatcher.Invoke([action] {},
            [System.Windows.Threading.DispatcherPriority]::Background)
    }

    function Select-HDTTestRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Drives an in-memory window; it changes no state on the machine.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [object] $Window,
            [Parameter(Mandatory = $true)] [string] $Like)

        $tree = $Window.FindName('HDTStepTree')
        $tree.UpdateLayout()

        $row = @($tree.ItemsSource) |
            Where-Object { [string] $_.Text -like ('*{0}*' -f $Like) } |
            Select-Object -First 1

        if ($null -eq $row) { throw ("no row matching '{0}' in the tree" -f $Like) }

        # THE CONTAINERS ARE GENERATED AT Render PRIORITY, NOT WHEN ASKED FOR.
        # Standalone this file passed on the first look; run after twenty other
        # files that each build a window, the generator had not caught up and
        # ContainerFromItem came back $null - so no row was selected, the
        # handler never ran, and 'parsed once' passed by parsing NOTHING. The
        # queue is drained first and the look is retried.
        $item = $null

        foreach ($attempt in 1..10) {
            $tree.UpdateLayout()
            Wait-HDTTestDispatcher -Window $Window

            $item = $tree.ItemContainerGenerator.ContainerFromItem($row)
            if ($null -ne $item) { break }
        }

        # AND IT THROWS RATHER THAN RETURNING NOTHING. A helper that gives up
        # quietly turns every assertion below it into one that passes by finding
        # nothing to break, which is exactly what happened here.
        if ($null -eq $item) {
            throw ("the tree generated no container for '{0}', so nothing could be selected" -f $Like)
        }

        # DESELECTED FIRST, so asking for the row that is already selected still
        # raises SelectedItemChanged - which is the event under test, and
        # assigning $true to something already $true raises nothing at all.
        $item.IsSelected = $false
        $item.IsSelected = $true
        Wait-HDTTestDispatcher -Window $Window

        return $row
    }
    # A HAND-WRITTEN SPY, INSTALLED INTO THE LIVE MODULE - not Pester's Mock.
    #
    # Mock could not see this call, and the reason is worth writing down. The
    # view parses through '& (Get-Module -Name ''Hephaestus'') { ... }', which
    # resolves the module BY NAME AT THE MOMENT IT RUNS, while three other files
    # in tests/unit re-import Hephaestus with -Force from inside a BeforeAll -
    # that is, DURING the run. Each of those replaces the module object, so the
    # instance Pester bound its mock to is not the instance the closure reaches,
    # and the mock counted 0 while the parse ran perfectly. Standalone the file
    # passed; behind twenty others it did not, which is the worst way for a test
    # to be wrong.
    #
    # SO THE SPY IS PUT WHERE THE CALL WILL LOOK, resolved the same way and at
    # the same time, and it counts into an ArrayList the test holds - objects
    # cross session states by reference, which is what makes the count readable
    # from here.
    function Install-HDTTestParseSpy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Patches an in-memory module function for the duration of one test.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        $sink = New-Object -TypeName System.Collections.ArrayList

        & (Get-Module -Name 'Hephaestus') {
            param($Sink)

            $script:HDTTestParseReal = (Get-Item -LiteralPath 'function:Import-HDTSequenceDocument').ScriptBlock
            $script:HDTTestParseSink = $Sink

            # function:script: - THE SCOPE QUALIFIER IS THE WHOLE TRICK.
            # '& $module { ${function:X} = ... }' runs in the module's session
            # state but in a CHILD SCOPE, so the replacement is thrown away the
            # moment the scriptblock returns and the real command goes on
            # running, uncounted. Naming the script scope explicitly is what
            # reaches the module's own function table.
            Set-Item -LiteralPath 'function:script:Import-HDTSequenceDocument' -Value {
                param($Path, $FileSystem)

                [void] $script:HDTTestParseSink.Add([string] $Path)

                return & $script:HDTTestParseReal -Path $Path -FileSystem $FileSystem
            }
        } $sink

        # THE UNARY COMMA IS NOT DECORATION. An EMPTY ArrayList returned bare
        # unrolls to nothing, the caller's variable lands $null, and the spy
        # then counts into an object the test threw away - which reads exactly
        # like a mock that never fired. Same trap as Get-HDTShareAccessRule's.
        return , $sink
    }

    function Remove-HDTTestParseSpy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Restores the in-memory module function the spy replaced.')]
        [CmdletBinding()]
        [OutputType([void])]
        param()

        # RESTORED IN A finally, ALWAYS. A module left carrying the spy would
        # count parses for every file that runs after this one.
        & (Get-Module -Name 'Hephaestus') {
            if ($null -ne $script:HDTTestParseReal) {
                Set-Item -LiteralPath 'function:script:Import-HDTSequenceDocument' `
                    -Value $script:HDTTestParseReal
            }
        }
    }

}

Describe 'the parse behind a selection' {

    # THE SPY GOES ON BEFORE THE WINDOW IS BUILT, and the numbers are DELTAS
    # from the moment the window is up. Opening the editor legitimately parses -
    # once for the tree this test hands it, once for the first fill of the pane -
    # and neither is what this is about. What it is about is what a CLICK adds,
    # which is the number a person waits for.

    # THE CLOCK IS NOT THE ASSERTION. A timing test is flaky on a shared machine
    # and says nothing about which work stopped happening; this counts the call.
    It 'pays for the document once and adds nothing for the clicks after it' {
        $parse = Install-HDTTestParseSpy

        try {
            $window = New-HDTTestParseCacheWindow
            $opened = [int] $parse.Count

            [void] (Select-HDTTestRow -Window $window -Like 'Prepare Boot')
            $first = [int] $parse.Count

            [void] (Select-HDTTestRow -Window $window -Like 'Stamp The Build')
            [void] (Select-HDTTestRow -Window $window -Like 'Restart Once')
            [void] (Select-HDTTestRow -Window $window -Like 'Prepare Boot')

            $rest = [int] $parse.Count
        } finally {
            Remove-HDTTestParseSpy
        }

        # THE PANE REALLY FILLED, so a delta of zero below is a kept parse and
        # not three clicks that did nothing - which is exactly how this test
        # first passed for the wrong reason.
        [string] $window.FindName('HDTStepNameBox').Text | Should -BeExactly 'Prepare Boot'

        # THE FIRST CLICK READS THE DOCUMENT. Nothing had parsed these lines for
        # the pane yet, so this one is the honest cost of opening.
        ($first - $opened) | Should -Be 1 -Because 'the first click is what reads the document for the pane'

        # AND THE THREE AFTER IT READ NOTHING. This is the whole change: it was
        # one parse EACH, on the UI thread, while somebody clicked through a
        # sequence they were only reading.
        ($rest - $first) | Should -Be 0 -Because 'no line moved, so the kept parse serves every click after the first'
    }

    # THE OTHER HALF OF THE PAIR. Without this, a cache that never invalidated
    # at all would pass the test above - and would be the worst version of this
    # change rather than the best one.
    It 'parses again, exactly once, when an edit has moved the lines' {
        $parse = Install-HDTTestParseSpy

        try {
            $window = New-HDTTestParseCacheWindow

            [void] (Select-HDTTestRow -Window $window -Like 'Prepare Boot')
            $beforeEdit = [int] $parse.Count

            # TICKING Disable SPLICES THE DOCUMENT, which is an edit like any
            # other and is the cheapest one to drive from here.
            $disable = $window.FindName('HDTDisableCheck')
            $disable.IsChecked = $true
            $disable.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Wait-HDTTestDispatcher -Window $window

            $afterEdit = [int] $parse.Count
        } finally {
            Remove-HDTTestParseSpy
        }

        # ONE, AND THE NUMBER IS THE EDIT PATH'S WHOLE STORY. The splice
        # invalidates the kept parse, $rebuild re-reads it once, and the
        # $reflect that follows on the next line gets that same object rather
        # than parsing again - which is what an edit used to cost twice over.
        ($afterEdit - $beforeEdit) | Should -Be 1 -Because 'the lines moved, so the kept parse is re-read exactly once'
    }
}

# THE ANTI-STALE TEST, AND THE ONE THAT MATTERS MOST.
#
# NOTHING IS MOCKED HERE ON PURPOSE. A cache that never invalidates makes every
# test about SPEED pass harder, so the only test that can catch it is one that
# reads a value off the pane after an edit and asks whether it is the new one.
Describe 'what the pane shows after an edit' {

    BeforeAll {
        $script:staleWindow = New-HDTTestParseCacheWindow

        $script:disableCheck = $script:staleWindow.FindName('HDTDisableCheck')
        $script:saveButton = $script:staleWindow.FindName('HDTSaveButton')
        $script:conditionBox = $script:staleWindow.FindName('HDTConditionText')

        [void] (Select-HDTTestRow -Window $script:staleWindow -Like 'Prepare Boot')

        $script:tickBefore = [bool] $script:disableCheck.IsChecked
        $script:saveBefore = [bool] $script:saveButton.IsEnabled

        # THE EDIT. The tick writes 'disabled: true' into the document and then
        # rebuilds, and the rebuild refills this very box FROM THE DOCUMENT - so
        # a $reflect reading a kept parse would put the tick straight back where
        # it was, in the same frame, and the click would look like it did
        # nothing at all.
        $script:disableCheck.IsChecked = $true
        $script:disableCheck.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Wait-HDTTestDispatcher -Window $script:staleWindow

        $script:tickAfter = [bool] $script:disableCheck.IsChecked
        $script:saveAfter = [bool] $script:saveButton.IsEnabled

        # AND AGAIN AFTER WALKING AWAY AND BACK, which is the second reflect off
        # the same document and the path a person actually takes.
        [void] (Select-HDTTestRow -Window $script:staleWindow -Like 'Restart Once')
        [void] (Select-HDTTestRow -Window $script:staleWindow -Like 'Prepare Boot')

        $script:tickOnReturn = [bool] $script:disableCheck.IsChecked

        # A SECOND EDIT, ON A DIFFERENT PAGE AND A DIFFERENT STEP, so this is
        # not one lucky control. The condition box commits on leaving it.
        $script:conditionBox.Text = '$Model -like ''Virtual*'''
        $script:conditionBox.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                    [System.Windows.UIElement]::LostFocusEvent)))
        Wait-HDTTestDispatcher -Window $script:staleWindow

        $script:conditionAfter = [string] $script:conditionBox.Text

        [void] (Select-HDTTestRow -Window $script:staleWindow -Like 'Restart Once')
        [void] (Select-HDTTestRow -Window $script:staleWindow -Like 'Prepare Boot')

        $script:conditionOnReturn = [string] $script:conditionBox.Text
    }

    It 'starts with the step enabled and nothing to save' {
        # If this fails nothing below is testing what it claims to.
        $script:tickBefore | Should -BeFalse
        $script:saveBefore | Should -BeFalse
    }

    It 'lights Save, so the edit really reached the document' {
        $script:saveAfter | Should -BeTrue
    }

    It 'leaves the tick ticked rather than refilling it from the old document' {
        $script:tickAfter | Should -BeTrue
    }

    It 'still shows the step disabled after walking away and back' {
        $script:tickOnReturn | Should -BeTrue
    }

    It 'shows the condition that was just typed' {
        $script:conditionAfter | Should -BeExactly '$Model -like ''Virtual*'''
    }

    It 'still shows that condition after walking away and back' {
        $script:conditionOnReturn | Should -BeExactly '$Model -like ''Virtual*'''
    }
}

}
