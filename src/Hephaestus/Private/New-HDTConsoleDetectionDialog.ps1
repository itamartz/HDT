function New-HDTConsoleDetectionDialog {
    <#
        .SYNOPSIS
            Builds the Detection dialog and wires every handler on it, without
            showing it.

        .DESCRIPTION
            BUILDING A WINDOW AND SHOWING ONE ARE TWO DIFFERENT JOBS, and only
            the second needs a desktop - the same split New-HDTConsoleView
            already makes for the console itself. New-HDTConsoleHost's
            ShowApplicationDetection calls this and then ShowDialog, which is
            the part that blocks and the part that needs a window station.

            THAT SPLIT IS WHAT MAKES THE WIRING REACHABLE. While the only entry
            point was a method ending in ShowDialog, nothing in Pester could
            type into a box and ask what the window did about it - and the
            window did nothing about it for four detection types at once.

            THE BOXES ARE BUILT HERE BECAUSE THE TYPE DECIDES THEM.
            Get-HDTConsoleDetectionForm says which keys, what is in them, what
            to call them and whether they hold a rule that can be written; this
            makes a TextBox per row and reads them back. Every decision is that
            command's; the only thing settled here is which control shows what
            it said.

            EVERY BOX IS ASKED AGAIN ON EVERY KEYSTROKE. The rows do not exist
            in the markup - they are made when a type is chosen - so the
            Add_TextChanged that every other dialog in this toolkit declares in
            XAML has to be hung on them as they are made. Without it the
            validator and the preview read only what the DOCUMENT said, and a
            path typed into the one box on screen left the window insisting that
            box was empty.

        .PARAMETER Xaml
            HDTApplicationDetection.xaml, as text.

        .PARAMETER Workspace
            The share the application lives on. Shown in the header and passed
            to Set-HDTApplication on Save.

        .PARAMETER Id
            The application id.

        .PARAMETER Detect
            The rule the document holds, or nothing.

        .PARAMETER Theme
            The palette, keyed by resource name.

        .PARAMETER Owner
            The window this one is modal to, or nothing.

        .PARAMETER ConsoleHost
            The host object whose DetectionAnswer this sets when Save writes.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Windows.Window - built and wired, never shown.

        .EXAMPLE
            $dialog = New-HDTConsoleDetectionDialog -Xaml $markup -Workspace 'C:\Share' `
                -Id 'App-1' -Detect $rule -Theme (Get-HDTConsoleTheme) -Owner $window `
                -ConsoleHost $this

        .LINK
            Get-HDTConsoleDetectionForm

        .LINK
            Set-HDTApplication
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
    [CmdletBinding()]
    [OutputType([System.Windows.Window])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Xaml,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Workspace,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter()] [AllowNull()] [object] $Detect = $null,
        [Parameter()] [AllowNull()] [object] $Theme = $null,
        [Parameter()] [AllowNull()] [object] $Owner = $null,
        [Parameter()] [AllowNull()] [object] $ConsoleHost = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Add-Type -AssemblyName PresentationFramework

    # THE DOOR A HANDLER REACHES A PRIVATE HELPER THROUGH - see
    # Get-HDTHandlerCall. Declared here so every closure below captures it.
    $call = Get-HDTHandlerCall

    $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $Xaml)
    $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
    $dialog.Icon = Get-HDTConsoleWindowIcon

    if ($null -ne $Owner) { $dialog.Owner = $Owner }

    if ($null -ne $Theme) {
        $converter = New-Object -TypeName System.Windows.Media.BrushConverter
        foreach ($key in @($Theme.Keys)) {
            $dialog.Resources[$key] = $converter.ConvertFromString([string] $Theme[$key])
        }
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

    # WHAT THE BOXES HOLD, ASKED AGAIN. The form is rebuilt from what is typed
    # rather than from what the document said, so Save writes what is on screen.
    #
    # THIS AND $judge ARE DECLARED BEFORE $draw ON PURPOSE. .GetNewClosure()
    # captures the variables that exist AT THAT MOMENT, so a $draw built first
    # would carry a null $judge and every keystroke would call nothing - which
    # is exactly the class of bug ConsoleButtonPress.Tests.ps1 exists to catch.
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

    # THE HANDLER EVERY BOX GETS, MADE ONCE AND MADE HERE.
    #
    # NOT INSIDE $draw, and this is the trap: .GetNewClosure() copies the
    # variables of the scope it is called in and only that scope. A
    # { & $judge }.GetNewClosure() written inside $draw runs in $draw's own
    # invocation scope, where $judge is a PARENT's variable - readable, but not
    # copied - so the closure comes out holding $null and every keystroke fails
    # with "the expression after '&' ... produced an object that was not valid".
    # Out here $judge is local, so it is captured.
    #
    # ONE BLOCK FOR ALL THE BOXES. It reads no sender; what changed does not
    # matter, because the whole form is asked again either way.
    $retype = { & $judge }.GetNewClosure()

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

            # EVERY KEYSTROKE, NOT EVERY TYPE CHANGE. The rule the footer
            # previews and the refusal above it are both read off these boxes,
            # so they have to be re-read whenever a box changes - and the
            # handler goes on AFTER the initial Text, so a redraw does not
            # judge a panel it is still halfway through building.
            $box.Add_TextChanged($retype)

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

    $typeBox.Add_SelectionChanged({
            if ($state.Loading) { return }

            # SelectedItem, NOT SelectedValue. SelectedValue is a second
            # dependency property WPF coerces from the item AFTER the selection
            # has changed, so inside this handler it can still be the value that
            # was there before - empty, on the first choice made in a window
            # that opened with no rule. The item is the row the ComboBox is
            # actually holding, and it is set before the event is raised.
            $chosen = ''
            if ($null -ne $typeBox.SelectedItem) { $chosen = [string] $typeBox.SelectedItem.Type }

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

    if ($null -ne $ConsoleHost) { $ConsoleHost.DetectionAnswer = $null }

    $dialogHost = $ConsoleHost

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

                # NAMED DIRECTLY, NOT THROUGH $call. Set-HDTApplication is
                # exported, and an exported command is the one thing a closure
                # CAN resolve out in the caller's session state - see
                # Get-HDTHandlerCall. $call is for the private helpers.
                [void] (Set-HDTApplication @splat)

                if ($null -ne $dialogHost) { $dialogHost.DetectionAnswer = $now.Rule }
                $dialog.DialogResult = $true
            } catch {
                $messageText.Text = [string] $_.Exception.Message
            }
        }.GetNewClosure())

    return $dialog
}
