function Hide-HDTShellWindow {
    <#
        .SYNOPSIS
            Hides or restores the WinPE console window behind the wizard.

        .DESCRIPTION
            WinPE boots into cmd.exe running startnet.cmd, and that black
            X:\Windows\System32> window sits behind everything for the whole
            deployment. -WindowStyle Hidden on the PowerShell launch does not
            touch it: that hides the POWERSHELL host, not the shell that
            started it. The only way to move it is the Win32 ShowWindow API
            against the console's own handle, which is what MDT and PSD do.

            THE CONSOLE IS RESTORED ON FAILURE, AND THAT IS NOT OPTIONAL. A
            hidden console plus a wizard that then throws leaves a technician
            staring at a BLANK SCREEN with no way to read what went wrong and
            nothing to type into. Every caller that hides it must restore it on
            its failure path - hidden is a presentation choice, not a place to
            get stuck.

            AN ADAPTER, AND THEREFORE BRANCH-FREE (CLAUDE.md rule 1). It wraps
            two Win32 calls and has nothing to decide; whether to hide at all is
            the payload's decision. It is also SAFE OUTSIDE WinPE: a process
            with no console gets a null handle and this does nothing, so the
            desktop preview tool is unaffected.

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

    return $true
}
