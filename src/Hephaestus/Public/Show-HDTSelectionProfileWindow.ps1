function Show-HDTSelectionProfileWindow {
    <#
        .SYNOPSIS
            Opens the Selection Profiles window on a deployment share.

        .DESCRIPTION
            Deployment Workbench's Advanced Configuration \ Selection Profiles: a
            list of profiles beside a tick box tree of the share.

            A PROFILE IS SHARE-WIDE, WHICH IS WHY THIS IS ITS OWN WINDOW. DESIGN
            13 calls standalone media a content projection of the share, and a
            selection profile is that projection's filter - so the same document
            that picks two vendor WinPE packs for a boot image picks which
            applications go on a USB stick. Hanging it off the boot image would
            say it was about drivers.

            IT IS REACHED FROM TWO PLACES AND IS ONE WINDOW. The Selection
            Profiles node in the share tree, and the Edit profiles button beside
            the Windows PE picker - which is there because the real first run is
            "open the picker, find only built-ins, need one now".

            IT READS THE DOCUMENT'S OWN LINES AND NEVER ROUND-TRIPS THEM, like
            every other editor here: an administrator's notes about which HP pack
            is the G11 one survive a New, a Rename, a Delete and a Save.

            A SHARE WITH NO DOCUMENT IS THE ORDINARY FIRST RUN, not an error.
            New-HDTWorkspace writes no selection-profiles.yaml, so the window
            opens on the built-ins alone and New writes the file.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER XamlPath
            The window's markup. Defaults to the one shipped beside the module.

        .PARAMETER ConsoleHost
            The host to show it through. Omitted, one is created - which is what
            makes this command runnable on its own, without the browser.

        .PARAMETER FileSystem
            The IFileSystem to read the share with.

        .PARAMETER OwnerWidth
            The width of the window this was opened from. Zero means the
            remembered size.

        .PARAMETER OwnerHeight
            The height of the window this was opened from.

        .PARAMETER Screen
            The screen service, for keeping the window on a monitor that exists.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Answer - 'saved'
            when the window wrote the document, empty otherwise.

        .EXAMPLE
            Show-HDTSelectionProfileWindow -Root 'C:\HDTLab\Share'

            The profiles this share has, and the tree to build another one from.

        .EXAMPLE
            $answer = Show-HDTSelectionProfileWindow -Root 'C:\HDTLab\Share'
            if ($answer.Answer -eq 'saved') { Get-HDTSelectionProfile -Root 'C:\HDTLab\Share' }

            Re-reading the share after the window wrote to it, which is what the
            Windows PE picker does when Edit profiles closes.

        .LINK
            Get-HDTSelectionProfile

        .LINK
            Set-HDTBootImageDriver
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTSelectionProfile.xaml'),

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

    if (-not (Test-Path -LiteralPath $XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath `
                    -Category ObjectNotFound `
                    -Message 'the Selection Profiles window markup is missing, so the window cannot be shown.'))
    }

    $documentPath = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'selection-profiles.yaml'

    # A SHARE WITH NO DOCUMENT OPENS ON THE BUILT-INS. New writes the file.
    $line = [string[]] @()

    if ($FileSystem.TestPath($documentPath)) {
        $line = [string[]] @([string] $FileSystem.ReadAllText($documentPath) -split "`r?`n")
    }

    # A DOCUMENT THAT WILL NOT LOAD IS THE ONE THING THIS REFUSES. Every other
    # window here opens on a broken share and shows what it can; this one edits
    # that document, and a Save from a window built on a half-read one would
    # write over an administrator's file with less than it started with.
    $selectionProfile = @()

    try {
        $selectionProfile = @(Get-HDTSelectionProfile -Root $Root -FileSystem $FileSystem)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $documentPath `
                    -Message ("the selection profile document could not be read, so it cannot be edited safely: {0}" -f
                        [string] $_.Exception.Message)))
    }

    # THE SHARE'S OWN FOLDERS, read here because the view model has no
    # IFileSystem - the same split the Windows PE window's ADK list uses.
    $folder = @(Get-HDTShareContentFolder -Root $Root -FileSystem $FileSystem)

    $size = Resolve-HDTConsoleEditorSize -OwnerWidth $OwnerWidth -OwnerHeight $OwnerHeight -Screen $Screen

    $answer = $ConsoleHost.ShowSelectionProfile(
        [System.IO.File]::ReadAllText($XamlPath), $Root, $line,
        [object[]] @($selectionProfile), [object[]] @($folder),
        (Get-HDTConsoleTheme), $size)

    return [pscustomobject] @{
        Answer = [string] $answer
        Root   = $Root
        Path   = $documentPath
    }
}
