function Get-HDTConsoleWindowIcon {
    <#
        .SYNOPSIS
            The icon every console window wears, in its title bar and in the
            taskbar button: Hephaestus' anvil on the banner blue.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER WPF AND IS DELIBERATELY BRANCH-FREE. It
            decides nothing and reads nothing: two colours and one path, drawn
            once. tests/unit/ConsoleWindowIcon.Tests.ps1 asserts the size, that
            it is an ImageSource, and that it is frozen - the three things that
            can be wrong without looking at it.

            WHY THERE IS ONE AT ALL. A WPF window that declares no Icon falls
            back to the icon of the process that hosts it, and that process is
            powershell.exe - so the console, the task sequence editor and every
            dialog came up wearing the PowerShell feather. An administrator
            alt-tabbing between the console and the shell that started it had
            two identical buttons, and pinning the console to the taskbar pinned
            something indistinguishable from a shell.

            IT IS DRAWN, NOT SHIPPED AS A .ico. A binary asset is a file nobody
            can review in a diff, and it would have to be found at run time at a
            path that differs between a source tree, a generated bundle and an
            installed module - three ways for a window to come up with no icon
            because a file move was missed. Geometry is text and lives in this
            file, and RenderTargetBitmap turns it into what Window.Icon takes.

            256 SQUARE IS THE LARGEST SIZE A SHELL ASKS FOR - the jumbo icon in
            an Alt+Tab switcher and in the taskbar at 200% scaling. WPF
            downsamples for the 16- and 32-pixel uses, which is why the anvil is
            a solid silhouette with no detail small enough to disappear when it
            is a sixteenth of this size.

            IT IS FROZEN because the boot image build opens its progress window
            on a second thread, and an unfrozen Freezable belongs to the thread
            that made it. Freezing also lets all thirteen windows share the one
            bitmap instead of rendering their own.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A frozen System.Windows.Media.Imaging.RenderTargetBitmap, 256x256.

        .EXAMPLE
            $window.Icon = Get-HDTConsoleWindowIcon
    #>
    # OutputType IS [object] AND NOT THE REAL TYPE. An attribute is bound before
    # a single line of the body runs, so naming ImageSource here would demand
    # PresentationCore from a session that has not loaded it yet - and this
    # function is what loads it. The Add-Type calls below are the reason the
    # attribute cannot say what they make available.
    [CmdletBinding()]
    [OutputType([object])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase

    # THE BADGE IS THE BANNER'S BLUE, #0E639C, the one colour that is the same
    # in both palettes (Get-HDTConsoleTheme). The icon does not follow the theme:
    # a taskbar button that changed colour when somebody switched the console to
    # dark would stop being the thing they learned to look for.
    $badge = New-Object -TypeName System.Windows.Media.SolidColorBrush -ArgumentList (
        [System.Windows.Media.ColorConverter]::ConvertFromString('#FF0E639C'))
    $metal = New-Object -TypeName System.Windows.Media.SolidColorBrush -ArgumentList (
        [System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFFFF'))

    # THE ANVIL, ON A 256 GRID: horn on the left tapering to a point, top face,
    # waist, splayed foot. It is a silhouette rather than an outline because an
    # outline of this at 16 pixels is a grey smudge.
    $anvil = [System.Windows.Media.Geometry]::Parse((
        'M 22,98 L 104,80 L 216,80 L 216,114 ' +
        'L 176,114 L 176,166 L 222,166 L 234,202 ' +
        'L 80,202 L 92,166 L 144,166 L 144,114 L 96,114 ' +
        'C 70,112 44,108 22,98 Z'))

    $visual = New-Object -TypeName System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $context.DrawRoundedRectangle($badge, $null,
        (New-Object -TypeName System.Windows.Rect -ArgumentList 0, 0, 256, 256), 48, 48)
    $context.DrawGeometry($metal, $null, $anvil)
    $context.Close()

    $bitmap = New-Object -TypeName System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList (
        256, 256, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $bitmap.Freeze()

    $bitmap
}
