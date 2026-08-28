function Hide-HDTShellWindow {
    <#
        .SYNOPSIS
            Hides or restores the WinPE console window, and makes the desktop it
            uncovers repaint.

        .DESCRIPTION
            WinPE boots into cmd.exe running startnet.cmd, and that black
            X:\Windows\System32> window sits behind everything for the whole
            deployment. -WindowStyle Hidden on the PowerShell launch does not
            touch it: that hides the POWERSHELL host, not the shell that
            started it. The only way to move it is the Win32 ShowWindow API
            against the console's own handle, which is what this calls.

            THE CONSOLE IS RESTORED ON FAILURE, AND THAT IS NOT OPTIONAL. A
            hidden console plus a wizard that then throws leaves a technician
            staring at a BLANK SCREEN with no way to read what went wrong and
            nothing to type into. Every caller that hides it must restore it on
            its failure path - hidden is a presentation choice, not a place to
            get stuck.

            AND IT FORCES THE DESKTOP TO REPAINT, WHICH IS NOT AN EXTRA - it
            is the other half of uncovering it. BGInfo does not paint pixels: it
            sets the DESKTOP WALLPAPER and returns, which marks the desktop as
            needing a repaint rather than performing one. In full Windows
            Explorer does that repaint immediately. WINPE HAS NO EXPLORER -
            cmd.exe is the shell - so nothing redraws the desktop, and the last
            thing actually painted there stays on screen.

            MEASURED ON A BOOTED VM. A boot image carrying both a winpe.jpg
            background and a BGInfo start command showed the JPG and no BGInfo
            for the whole of WinPE, and then BGInfo's version appeared the
            instant the Welcome screen opened - because a window taking a chunk
            of the screen is the first thing that forces a real desktop repaint.
            BGInfo had worked all along; nobody had asked the desktop to draw it.

            IT WAS INVISIBLE UNTIL THE CONSOLE MOVED. Before the payload hid the
            console for the whole run, the console covered the desktop from
            startnet.cmd to the wizard, so a desktop that never repainted looked
            exactly like a desktop that did.

            IT ASKS FOR A REPAINT AND NEVER TOUCHES THE WALLPAPER, and the
            first version of this function did the opposite. It called
            SystemParametersInfo(SPI_SETDESKWALLPAPER) with a null path, on the
            belief that null means "re-apply whatever is already set". IT DOES
            NOT. pvParam is the bitmap's path, and null or empty means REMOVE THE
            WALLPAPER - so a boot image built with that call came up on a BLACK
            SCREEN, having deleted the very BGInfo wallpaper it was written to
            reveal. A repaint must never be spelled as a set.

            InvalidateRect WITH A NULL WINDOW IS THE WHOLE LEVER. Passing NULL
            for hWnd invalidates and redraws EVERY window on the desktop, which
            is precisely the thing WinPE has no Explorer to do for itself.
            RedrawWindow on GetDesktopWindow() is kept with it: that one names
            the desktop explicitly, this one catches everything that was over
            it, and neither reads or writes a setting.

            AN ADAPTER, AND THEREFORE BRANCH-FREE. It wraps four Win32 calls and
            has nothing to decide; whether to hide at all is the payload's
            decision. It is also SAFE OUTSIDE WinPE: a process with no console
            gets a null handle and returns before any of it, so the desktop
            preview tool never repaints a developer's own wallpaper.

        .PARAMETER Restore
            Show the console again instead of hiding it.

        .OUTPUTS
            System.Boolean - whether a console window was found to act on.

        .EXAMPLE
            Hide-HDTShellWindow

            What the payload calls once the wizard is about to appear.

        .EXAMPLE
            try { Hide-HDTShellWindow; ... } finally { Hide-HDTShellWindow -Restore }

            The only correct shape: hidden for the happy path, back for every
            other one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes only the visibility of this process own console window; it alters no system state.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch] $Restore
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The type is added ONCE per session; Add-Type throws if the name already
    # exists, and the payload may show more than one page.
    if (-not ([System.Management.Automation.PSTypeName]'HDT.NativeWindow').Type) {
        Add-Type -Namespace 'HDT' -Name 'NativeWindow' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
public static extern IntPtr GetDesktopWindow();

[DllImport("user32.dll")]
public static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

[DllImport("user32.dll")]
public static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);
'@
    }

    $handle = [HDT.NativeWindow]::GetConsoleWindow()

    # No console - a windowed host, or the desktop preview tool. Nothing to do,
    # and not an error: this must never be the reason a wizard fails to open.
    if ($handle -eq [System.IntPtr]::Zero) {
        return $false
    }

    # 0 = SW_HIDE, 5 = SW_SHOW.
    $command = 0
    if ($Restore) { $command = 5 }

    [void] [HDT.NativeWindow]::ShowWindow($handle, $command)

    # AND NOW THE DESKTOP DRAWS ITSELF. See the header: WinPE has no Explorer, so
    # a wallpaper BGInfo set while the console covered the screen is a wallpaper
    # nothing has ever painted. Both directions want this - hiding uncovers the
    # desktop, restoring puts a window back over it - so it is not conditional on
    # -Restore.
    #
    # NOTHING BELOW SETS ANYTHING. Both calls ask for a repaint of what is
    # already there. The version that reached a VM called SPI_SETDESKWALLPAPER
    # with a null path instead and came up BLACK, because null is how that API
    # spells "no wallpaper".

    # A NULL WINDOW MEANS EVERY WINDOW. InvalidateRect documents it in those
    # words: with hWnd NULL the system invalidates and redraws all of them,
    # which is what nothing else on a WinPE machine is going to do.
    [void] [HDT.NativeWindow]::InvalidateRect([System.IntPtr]::Zero, [System.IntPtr]::Zero, $true)

    # 0x0001 RDW_INVALIDATE | 0x0004 RDW_ERASE | 0x0080 RDW_ALLCHILDREN, aimed at
    # the desktop by name - the window whose ground the wallpaper actually is.
    [void] [HDT.NativeWindow]::RedrawWindow(
        [HDT.NativeWindow]::GetDesktopWindow(), [System.IntPtr]::Zero, [System.IntPtr]::Zero, 0x0085)

    return $true
}
