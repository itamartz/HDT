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
        param([string] $Xaml, [string] $Title, [object[]] $Node, [object] $Theme, [object] $Size)

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

        # Selecting the root raises SelectedItemChanged, which is what fills the
        # two panes and the banner; the window is never shown blank.
        $window.Add_ContentRendered({
                $first = $tree.ItemContainerGenerator.ContainerFromIndex(0)
                $first.IsSelected = $true
            }.GetNewClosure())

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
    # A SECOND WINDOW, THE SAME ADAPTER. It loads markup, assigns an
    # ItemsSource and attaches handlers by name; every decision about what the
    # rows say was made in Get-HDTConsoleSequenceEditor and asserted there.
    #
    # THE ACTION BUTTONS ARE INERT UNTIL THE EDITING CMDLETS ARE WIRED, and the
    # markup disables them rather than leaving them bright and unresponsive. An
    # administrator pressing a blue button that does nothing concludes the
    # window is broken; a greyed one says "not yet" without being asked.
    $service | Add-Member -MemberType ScriptMethod -Name ShowEditor -Value {
        param([string] $Xaml, [string] $Title, [string] $Path, [object[]] $Node, [object] $Theme)

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

        $titleText.Text = $Title
        $pathText.Text = $Path

        $tree.ItemsSource = $Node

        $tree.Add_SelectedItemChanged({
                $selected = $tree.SelectedItem
                $detail.ItemsSource = $selected.Field
                $command.Text = [string] $selected.Command
            }.GetNewClosure())

        $window.Add_ContentRendered({
                $first = $tree.ItemContainerGenerator.ContainerFromIndex(0)
                if ($null -ne $first) { $first.IsSelected = $true }
            }.GetNewClosure())

        $close.Add_Click({
                $editorHost.Answer = 'Close'
                $window.Close()
            }.GetNewClosure())

        [void] $window.ShowDialog()

        return [string] $this.Answer
    }

    return $service
}
