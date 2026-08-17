<#
    .SYNOPSIS
        Opens the HDT admin console on one or more deployment shares.

    .DESCRIPTION
        THE FILE AN ADMINISTRATOR DOUBLE-CLICKS, and nothing more. Everything it
        used to do - the STA relaunch, hiding a console this process owns,
        -Detach - moved into Start-HDTConsole in the module, because a .ps1 in a
        folder is not a command: Import-Module gives you functions, and nothing
        puts a script file on the command path. Anybody who has imported the
        module types

            Start-HDTConsole -Detach C:\HDTLab\Share

        and this file exists for Explorer, for a shortcut, and for the moment
        before the module has been imported.

        IT IMPORTS AND DELEGATES, WITH NO LOGIC OF ITS OWN. Two copies of the
        window-hiding rules is one copy to get wrong, and the copy that would rot
        is this one - a test asserts this file names the function rather than
        Show-HDTConsole.

        THE FAILURE IS REPORTED WHERE SOMEBODY WHO DOUBLE-CLICKED WILL SEE IT.
        A console that has been hidden, or was never there, cannot show an error
        - so this catches and puts it in a message box.

    .PARAMETER Path
        The deployment shares to open. Position 0 takes the rest of the command
        line, so '-Path C:\a \\host\share' opens both.

    .PARAMETER Title
        The window title.

    .PARAMETER Theme
        Light or Dark. Light by default.

    .PARAMETER Detach
        Start the window in its own hidden process and return at once.

    .EXAMPLE
        .\Start-HDTConsole.ps1

        Opens the console on C:\HDTLab\Share.

    .EXAMPLE
        .\Start-HDTConsole.ps1 -Detach 'C:\HDTLab\Share'

        The window opens and the prompt comes straight back.
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
    [string] $Theme = 'Light',

    [Parameter()]
    [switch] $Detach
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop

    $answer = Start-HDTConsole -Path $Path -Title $Title -Theme $Theme -Detach:$Detach

    if ($null -ne $answer) {
        Write-Verbose ('The console closed with {0} after showing {1} rows.' -f $answer.Action, $answer.NodeCount)
    }
} catch {
    Add-Type -AssemblyName PresentationFramework

    [void] [System.Windows.MessageBox]::Show(
        [string] $_.Exception.Message,
        'Hephaestus Deployment Toolkit',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error)

    exit 1
}
