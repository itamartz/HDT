<#
    .SYNOPSIS
        Opens the HDT admin console on one or more deployment shares.

    .DESCRIPTION
        The one file an administrator runs. It imports the console module beside
        it and calls Show-HDTConsole; beyond the two pieces of housekeeping
        below it holds no logic of its own, because anything else it decided
        would be a decision no test could reach.

        THE CONSOLE WINDOW IT WAS LAUNCHED IN IS HIDDEN, WHEN IT OWNS IT. A
        desktop application that leaves a black terminal sitting behind it looks
        like something that is still running a script, and the terminal is not
        part of the product. It is hidden only when this process is the ONLY one
        attached to that console - which is true when the script was
        double-clicked or started with Start-Process, and false when it was run
        from a terminal the administrator already had open. GetConsoleProcessList
        answers that exactly; the usual shortcut, hiding GetConsoleWindow()
        unconditionally, would make somebody's terminal tab disappear.

        IT RE-LAUNCHES ITSELF INTO A SINGLE-THREADED APARTMENT WHEN IT HAS TO.
        WPF requires STA. Windows PowerShell 5.1 and pwsh 7.5 both start STA, so
        this is normally a no-op - but 'pwsh -MTA', and any host that runs this
        on an MTA thread, would otherwise reach Show-HDTConsole's refusal, and a
        refusal an administrator can do nothing about is worse than a re-launch
        they never notice.

        IT ONLY READS THE SHARES. C1 writes nothing.

        AN ERROR IS SHOWN IN A BOX, NOT IN THE TERMINAL THAT WAS JUST HIDDEN.
        Once the console window is gone, anything written to it is written to
        nobody - which is how the first version of this script reported a
        parameter mistake by silently exiting 1. A GUI application says what went
        wrong in a way the person who started it can see.

    .PARAMETER Path
        The deployment shares to open, positionally or after -Path. Defaults to
        the lab share.

        REMAINING ARGUMENTS COUNT AS SHARES, deliberately: 'pwsh -File' does not
        build an array out of several arguments, so
        '-Path C:\a \\host\share' would otherwise bind only the first and refuse
        the second. Every extra argument is another share.

    .PARAMETER Title
        The window title.

    .PARAMETER Theme
        Light or Dark. Light by default - see Show-HDTConsole.

    .EXAMPLE
        .\Start-HDTConsole.ps1

        Opens the console on C:\HDTLab\Share.

    .EXAMPLE
        .\Start-HDTConsole.ps1 -Theme Dark

        The same window in the wizard's palette.

    .EXAMPLE
        .\Start-HDTConsole.ps1 'C:\HDTLab\Share' '\\192.168.2.108\HDTShare'

        Two shares, one window - and the form that survives 'pwsh -File'.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Path = @('C:\HDTLab\Share'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Title = 'Hephaestus Deployment Toolkit',

    [Parameter()]
    [ValidateSet('Light', 'Dark')]
    [string] $Theme = 'Light'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- the apartment WPF needs ----------------------------------------------

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $argument = @('-NoProfile', '-STA', '-File', $PSCommandPath, '-Title', $Title, '-Theme', $Theme, '-Path') + @($Path)

    $process = Start-Process -FilePath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) `
        -ArgumentList $argument -WindowStyle Hidden -PassThru -Wait

    exit $process.ExitCode
}

# -- the terminal, which is not part of the product ------------------------

Add-Type -Namespace 'HDTConsoleNative' -Name 'Terminal' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("kernel32.dll")]
public static extern int GetConsoleProcessList(int[] lpdwProcessList, int dwProcessCount);

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@

$consoleWindow = [HDTConsoleNative.Terminal]::GetConsoleWindow()

if ($consoleWindow -ne [IntPtr]::Zero) {
    $attached = New-Object -TypeName 'int[]' -ArgumentList 8
    $attachedCount = [HDTConsoleNative.Terminal]::GetConsoleProcessList($attached, $attached.Length)

    # One attached process is this one, alone, in a console nobody else is
    # using. Anything else is a terminal that was already open.
    if ($attachedCount -eq 1) {
        [void] [HDTConsoleNative.Terminal]::ShowWindow($consoleWindow, 0)   # SW_HIDE
    }
}

# -- the window ------------------------------------------------------------

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'HDT.Console.psd1') -Force -ErrorAction Stop

    $answer = Show-HDTConsole -Path $Path -Title $Title -Theme $Theme

    Write-Verbose ('The console closed with {0} after showing {1} rows.' -f $answer.Action, $answer.NodeCount)
} catch {
    # The terminal is hidden by now, so writing there would be writing to
    # nobody. A window application reports in a window.
    Add-Type -AssemblyName PresentationFramework

    [void] [System.Windows.MessageBox]::Show(
        [string] $_.Exception.Message,
        'Hephaestus Deployment Toolkit',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error)

    exit 1
}
