<#
    .SYNOPSIS
        Opens the HDT admin console on one or more deployment shares.

    .DESCRIPTION
        THE ENTRY POINT FOR A COPY THAT IS NOT ON THE MODULE PATH, and nothing
        more. Everything it used to do - the STA relaunch, hiding a console this
        process owns, -Detach - moved into Start-HDTConsole in the module,
        because a .ps1 in a folder is not a command: Import-Module gives you
        functions, and nothing puts a script file on the command path.

        SOMEBODY WHO INSTALLED THE MODULE NEVER COMES NEAR THIS FILE. They type

            Start-HDTConsole -Detach C:\HDTLab\Share

        and it autoloads off $env:PSModulePath with no import at all. Installed,
        this script lands in ...\Modules\Hephaestus\<version>\, which is not a
        folder anybody browses to.

        WHAT IT IS ACTUALLY FOR is a loose copy - the working tree, a clone, an
        unzipped download, a folder on a share. src\Hephaestus is not on the
        module path, so there is no command to call until something imports the
        manifest, and this is the file that does it.

        IT IS NOT FOR DOUBLE-CLICKING, whatever its name suggests. Windows ships
        .ps1 with no Open verb deliberately - Explorer hands it to an editor
        rather than running it - so the double-click this file was first written
        for does not happen on a default install. Run it, or point a shortcut at
        powershell.exe -File; both work, and neither is a double-click.

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
