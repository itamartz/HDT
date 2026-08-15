function Show-HDTSequenceEditor {
    <#
        .SYNOPSIS
            Opens the task sequence editor on one task sequence.

        .DESCRIPTION
            Deployment Workbench's shape: the browser lists task sequences and
            editing their steps happens in a window opened from one. CLAUDE.md
            asks for a console close enough to it that muscle memory transfers.

            THE DECISIONS ARE Get-HDTConsoleSequenceEditor'S; THIS ONE HANDS
            THEM OVER. The rows, the title, the properties and the cmdlet each
            row shows are all built there and asserted in tests. This command
            loads the markup, resolves the palette and calls the injected host,
            which is what leaves the host branch-free and honestly exempt from
            TDD (CLAUDE.md rule 1).

            THE DOCUMENT PATH GOES TO THE WINDOW SEPARATELY, and the window
            shows it. Both of this lab's shares hold a DEMO-M4, so two editors
            open at once would otherwise be identical windows over different
            files - and the difference would only appear at the moment one of
            them saved.

            IT TAKES THE SEQUENCE OBJECT, NEVER AN ID, for the same reason.

        .PARAMETER Sequence
            One task sequence row from Get-HDTConsoleWorkspace's TaskSequence
            collection.

        .PARAMETER XamlPath
            The window markup. Defaults to the module's own.

        .PARAMETER ConsoleHost
            An IConsoleHost with a ShowEditor method. Defaults to the real
            adapter.

        .PARAMETER Theme
            Light or Dark. Light by default, matching the console.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action, Id, Name,
            DocumentPath and NodeCount.

        .EXAMPLE
            $share = Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share'
            Show-HDTSequenceEditor -Sequence @($share.TaskSequence)[0]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a window. The editing cmdlets it offers carry their own ShouldProcess, and this writes nothing itself.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Sequence,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTConsoleRoot -ChildPath 'UI\HDTSequenceEditor.xaml'),

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [ValidateSet('Light', 'Dark')]
        [string] $Theme = 'Light'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $ConsoleHost) { $ConsoleHost = New-HDTConsoleHost }
    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    if (-not (Test-Path -LiteralPath $XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTConsoleErrorRecord -Path $XamlPath `
                    -Category ObjectNotFound `
                    -Message 'the task sequence editor markup is missing, so the editor cannot be shown.'))
    }

    $editor = Get-HDTConsoleSequenceEditor -Sequence $Sequence

    $xaml = [System.IO.File]::ReadAllText($XamlPath)

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

    $answer = [string] $ConsoleHost.ShowEditor($xaml, $editor.Title, $editor.DocumentPath,
        [object[]] @($editor.Root), $line,
        [object[]] @(Get-HDTConsoleStepCatalog), (Get-HDTConsoleTheme -Name $Theme))

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
