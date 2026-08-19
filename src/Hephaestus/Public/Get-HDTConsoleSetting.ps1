function Get-HDTConsoleSetting {
    <#
        .SYNOPSIS
            Reads the console's remembered window size, or the default.

        .DESCRIPTION
            The console opens at the size it was last left at. That is the whole
            feature, and everything below is about it never being the reason a
            window fails to open.

            IT IS NOT ON THE DEPLOYMENT SHARE, AND THAT IS DELIBERATE. A window
            size is one administrator's preference on one workstation. Two people
            opening the same share must not fight over its geometry, a share
            opened read-only must still remember a size, and C1 writes nothing to
            a share at all. So it lives in %APPDATA%\HDT\console.json.

            EVERY UNTRUSTWORTHY FILE ANSWERS WITH THE DEFAULT. Absent, empty, not
            JSON, JSON of the wrong shape, or holding a size nobody could use -
            all of them yield 1800 x 900 rather than an error. A convenience that
            can lock an administrator out of their tooling is a defect, and the
            way it happens is a half-written file after a disk filled up.

            A SIZE SMALLER THAN THE WINDOW'S MINIMUM IS RAISED, NOT REJECTED. A
            console remembered at 200 x 100 is one nobody can use and nobody can
            easily fix, because the thing they would fix it with is the window.
            The floor is the MinWidth and MinHeight the markup declares.

            AND A SIZE BIGGER THAN THE SCREEN IS LOWERED, WHICH IS THE SAME
            ARGUMENT FROM THE OTHER END. The window opens at the top-left of the
            work area, so a size larger than the desktop hangs off the right and
            the bottom - and the bottom edge is where the Close button is. The
            shipped default of 1800 x 900 on a 1280 x 800 laptop is exactly that,
            so this is not a size only a strange preference file could produce.

            THE POSITION IS NOT REMEMBERED, ONLY THE SIZE. Where a window opens
            is not a preference an administrator expressed: it is the corner of
            whatever desktop they are sitting at today, which the console has to
            measure rather than recall. Left and Top come back on the same object
            because the window needs all four numbers at once, and
            Resolve-HDTConsoleWindowPosition decides them.

            THE FLOOR STILL WINS WHERE THEY DISAGREE. On a desktop smaller than
            MinWidth x MinHeight there is no size that satisfies both, and WPF
            would enforce the minimum regardless; reporting anything lower would
            be a number that lies about the window it produces.

            A SCREEN THAT CANNOT BE MEASURED CHANGES NOTHING. Same rule as the
            preference file: a convenience must never be the reason a window
            fails to open, so a display query that throws or answers zero leaves
            the size exactly as the file and the floor left it.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default.

        .PARAMETER Environment
            An IEnvironmentProvider - the real adapter by default. APPDATA is
            read through it so the whole path is provable under Pester.

        .PARAMETER Screen
            An IScreen - the real adapter by default. Injected so a window that
            does not fit a 1280 x 800 laptop can be proven from any desk.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Share, Path, Width, Height,
            Left and Top.

        .EXAMPLE
            Get-HDTConsoleSetting

            The size the console will open at.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Environment,

        [Parameter()]
        [AllowNull()]
        [object] $Screen
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Environment) { $Environment = New-HDTEnvironmentProvider }
    if ($null -eq $Screen) { $Screen = New-HDTConsoleScreen }

    $path = Get-HDTConsoleSettingPath -Environment $Environment

    # LEFT AND TOP START AT THE CORNER AND ARE NEVER READ FROM THE FILE. The size
    # is a preference; the position is not one. Every console opens at the origin
    # of the work area, and Resolve-HDTConsoleWindowPosition is what finds out
    # where that is - these two are the answer for a desktop that will not say.
    $result = [pscustomobject] @{
        Path   = $path
        Width  = [int] $script:HDTConsoleDefaultWidth
        Height = [int] $script:HDTConsoleDefaultHeight
        Left   = 0
        Top    = 0

        # THE SHARES THIS CONSOLE WAS LAST OPEN ON. Empty is a machine that has
        # never opened one, which is what Show-HDTConsole reads as "ask for a
        # path" rather than "open nothing".
        Share  = [string[]] @()
    }

    # A first run is clamped too: the default is 1800 x 900, and a laptop that
    # cannot show it is the commonest way this goes wrong, not the rarest.
    if ([string]::IsNullOrWhiteSpace($path) -or -not $FileSystem.TestPath($path)) {
        return (Resolve-HDTConsoleWindowPosition `
                -Size (Resolve-HDTConsoleWindowSize -Size $result -Screen $Screen) -Screen $Screen)
    }

    # ONE try FOR THE WHOLE READ. Every way this file can be wrong ends in the
    # same answer, so distinguishing "not JSON" from "JSON without a width" would
    # be a distinction with no consequence.
    try {
        $document = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText($path))

        $width = [int] (Get-HDTConsoleJsonProperty -InputObject $document -Name 'width' -Default 0)
        $height = [int] (Get-HDTConsoleJsonProperty -InputObject $document -Name 'height' -Default 0)

        # Zero and negative are "the file did not say", not "open at nothing".
        if ($width -gt 0 -and $height -gt 0) {
            $result.Width = [Math]::Max($width, $script:HDTConsoleMinimumWidth)
            $result.Height = [Math]::Max($height, $script:HDTConsoleMinimumHeight)
        }

        # A REMEMBERED PATH IS NOT A PROMISE. Nothing is checked here: a share
        # on a disconnected disk is read like any other and becomes a row that
        # says it could not be opened, which is the console's rule everywhere.
        $result.Share = [string[]] @(@(Get-HDTConsoleJsonProperty -InputObject $document -Name 'share' -Default @()) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        Write-Verbose ("The console setting at '{0}' could not be read, so the default size is used: {1}" -f
            $path, [string] $_.Exception.Message)
    }

    return (Resolve-HDTConsoleWindowPosition `
            -Size (Resolve-HDTConsoleWindowSize -Size $result -Screen $Screen) -Screen $Screen)
}
