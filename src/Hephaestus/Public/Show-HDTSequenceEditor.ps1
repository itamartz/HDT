function Show-HDTSequenceEditor {
    <#
        .SYNOPSIS
            Opens the task sequence editor on one task sequence.

        .DESCRIPTION
            Deployment Workbench's shape: the browser lists task sequences and
            editing their steps happens in a window opened from one. This toolkit
            asks for a console close enough to it that muscle memory transfers.

            THE DECISIONS ARE Get-HDTConsoleSequenceEditor'S; THIS ONE HANDS
            THEM OVER. The rows, the title, the properties and the cmdlet each
            row shows are all built there and asserted in tests. This command
            loads the markup, resolves the palette and calls the injected host,
            which is what leaves the host branch-free and honestly exempt from
            TDD.

            THE DOCUMENT PATH GOES TO THE WINDOW SEPARATELY, and the window
            shows it. Both of this lab's shares hold a DEMO-M4, so two editors
            open at once would otherwise be identical windows over different
            files - and the difference would only appear at the moment one of
            them saved.

            IT TAKES THE SEQUENCE OBJECT, NEVER AN ID, for the same reason.

            IT OPENS AT THE SIZE OF THE WINDOW IT WAS OPENED FROM. An
            administrator who has dragged the browser out to fill a monitor has
            said how big a window on this machine should be, and a second window
            that ignores that reads as a different application. The caller passes
            what the owner MEASURES, not what its markup says, so a maximised
            console opens a maximised-size editor - and
            Resolve-HDTConsoleEditorSize decides what to do with it, including
            when there is no owner at all, because the host that assigns it is
            not unit tested and must decide nothing.

        .PARAMETER WorkspaceRoot
            The deployment share holding the sequence.

        .PARAMETER Id
            Which sequence on it to open. An id the share does not hold is
            refused by name, with the ones it does hold listed.

        .PARAMETER Sequence
            One task sequence row as the console already holds it. This is the
            console's way in; -WorkspaceRoot and -Id is everybody else's.

        .PARAMETER XamlPath
            The window markup. Defaults to the module's own.

        .PARAMETER ConsoleHost
            An IConsoleHost with a ShowEditor method. Defaults to the real
            adapter.

        .PARAMETER OwnerWidth
            The current width of the window the editor was opened from - the
            console's ActualWidth. Left at zero when it was run on its own, and
            the editor then opens at its own size.

        .PARAMETER OwnerHeight
            The current height of the window the editor was opened from.

        .PARAMETER Screen
            An IScreen - the real adapter by default. Injected so a size that
            does not fit a 1280 x 800 laptop can be proven from any desk.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action, Id, Name,
            DocumentPath and NodeCount.

        .EXAMPLE
            Show-HDTSequenceEditor -WorkspaceRoot 'C:\HDTLab\Share' -Id 'DEMO-05'

            Opens the editor on one sequence. The share is read here, so nothing
            has to be built first.

        .EXAMPLE
            Show-HDTSequenceEditor -WorkspaceRoot 'C:\HDTLab\Share' -Id 'NO-SUCH-ID'

            Throws, naming the id and listing the ones the share does hold.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a window. The editing cmdlets it offers carry their own ShouldProcess, and this writes nothing itself.')]
    [CmdletBinding(DefaultParameterSetName = 'Workspace')]
    [OutputType([pscustomobject])]
    param(
        # THE SHARE AND THE SEQUENCE ON IT, which is what an administrator has.
        # The editor's tree is built from a console workspace row - Status,
        # Finding and the counts alongside the steps - and the only command that
        # builds one is internal to the window. Taking the root and the id means
        # this command reads the share itself rather than asking for an object
        # nobody outside the module can make.
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Workspace')]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Workspace')]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        # THE ROW THE CONSOLE ALREADY HOLDS. It drew the tree from it a moment
        # ago; reading the share again to open a window on it would be a second
        # scan of every sequence for no new information.
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Sequence')]
        [ValidateNotNull()]
        [object] $Sequence,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTSequenceEditor.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $PartitionXamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTPartitionProperties.xaml'),

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,


        [Parameter()]
        [ValidateRange(0, 100000)]
        [int] $OwnerWidth = 0,

        [Parameter()]
        [ValidateRange(0, 100000)]
        [int] $OwnerHeight = 0,

        [Parameter()]
        [AllowNull()]
        [object] $Screen
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $ConsoleHost) { $ConsoleHost = New-HDTConsoleHost }
    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Screen) { $Screen = New-HDTConsoleScreen }

    # READ THE SHARE WHEN THE CALLER NAMED ONE. Get-HDTConsoleWorkspace is what
    # produces the row the editor's tree is built from, and it is internal to the
    # window - so this is the one place that turns a root and an id into one.
    # A LOCAL, NOT THE PARAMETER. Assigning to $Sequence re-runs its
    # ValidateNotNull, so a miss would be reported as "the value is not valid for
    # the Sequence variable" rather than as the id that is not on the share.
    $row = $Sequence

    if ($PSCmdlet.ParameterSetName -eq 'Workspace') {
        $workspace = Get-HDTConsoleWorkspace -Path $WorkspaceRoot -FileSystem $FileSystem

        $row = @($workspace.TaskSequence) | Where-Object { [string] $_.Id -eq $Id } | Select-Object -First 1

        if ($null -eq $row) {
            $offered = @($workspace.TaskSequence | ForEach-Object { [string] $_.Id }) -join ', '
            if ([string]::IsNullOrWhiteSpace($offered)) { $offered = '(none)' }

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                        -Category ObjectNotFound `
                        -Message ("no task sequence with the id '{0}' is on this share. It holds: {1}." -f $Id, $offered)))
        }
    }

    if (-not (Test-Path -LiteralPath $XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath `
                    -Category ObjectNotFound `
                    -Message 'the task sequence editor markup is missing, so the editor cannot be shown.'))
    }

    $editor = Get-HDTConsoleSequenceEditor -Sequence $row

    $xaml = [System.IO.File]::ReadAllText($XamlPath)

    # THE VOLUME DIALOG'S MARKUP TRAVELS WITH THE EDITOR'S. It is opened from a
    # button on the Disk tab, so reading it here means the host never touches the
    # file system - the same reason the editor's own markup arrives as a string.
    $partitionXaml = ''
    if (Test-Path -LiteralPath $PartitionXamlPath) {
        $partitionXaml = [System.IO.File]::ReadAllText($PartitionXamlPath)
    }

    # THE DOCUMENT'S OWN LINES, WHICH ARE WHAT THE EDITOR EDITS. Every editing
    # cmdlet splices a string array, and the whole reason for that (see
    # ConsoleStepEdit.Tests.ps1) is that the comments survive - so the text is
    # read once, here, and never round-tripped through the parser.
    #
    # A sequence that would not parse still opens: its rows are empty and the
    # engine's message is already on its row in the browser, but the file's
    # lines are the one thing that might let an administrator fix it.
    $line = [string[]] @()

    if ($FileSystem.TestPath($editor.DocumentPath)) {
        $line = [string[]] @([string] $FileSystem.ReadAllText($editor.DocumentPath) -split "`r?`n")
    }

    # THE TREE COMES FROM THE SAME TEXT THE EDITOR EDITS, and until now it did
    # not. This window read the document TWICE, FROM TWO PLACES: the LINES above,
    # freshly off disk, and the ROWS - which came from $Sequence, the projection
    # Get-HDTConsoleWorkspace built when the CONSOLE opened and which knows
    # nothing about anything saved since.
    #
    # WATCHED IN THE CONSOLE, AND IT MADE THE WHOLE WINDOW UNTRUSTWORTHY. A
    # technician removed a step, saved, closed the editor and opened it again -
    # and the step was back. The file was right the whole time; the picture of it
    # was a session old. Worse than a wrong row: every edit spliced the correct
    # file while showing the wrong document, so the two drifted further apart
    # with each one.
    #
    # ONE READ, ONE SOURCE. Get-HDTConsoleEditorState is what the editor's own
    # rebuild uses after every splice, so opening now produces exactly the tree
    # the first edit would have produced anyway.
    #
    # A DOCUMENT THAT WILL NOT PARSE STILL OPENS, which is the reason $line is
    # read whatever happens: the state comes back with no rows and a message,
    # and the file's text is the one thing that might let somebody fix it.
    $opening = Get-HDTConsoleEditorState -Line $line -Path $editor.DocumentPath
    $root = [object[]] @($opening.Root)

    # THE SIZE OF THE WINDOW THIS WAS OPENED FROM, FITTED TO THE DESKTOP. The
    # host assigns the two numbers and works out neither of them.
    $size = Resolve-HDTConsoleEditorSize -OwnerWidth $OwnerWidth -OwnerHeight $OwnerHeight -Screen $Screen

    $answer = [string] $ConsoleHost.ShowEditor($xaml, $editor.Title, $editor.DocumentPath,
        $root, $line,
        [object[]] @(Get-HDTConsoleStepCatalog), (Get-HDTConsoleTheme), $size,
        $partitionXaml, $editor)

    $action = 'Close'
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $action = $answer }

    return [pscustomobject] @{
        Action       = $action
        Id           = $editor.Id
        Name         = $editor.Name
        DocumentPath = $editor.DocumentPath
        NodeCount    = @($editor.Node).Count
    }
}
