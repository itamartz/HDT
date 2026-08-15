Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The module's own directory, so Show-HDTConsole can default -XamlPath to the
# window that ships beside it. Resolved once, here, rather than from $PSScriptRoot
# inside a dot-sourced function, where it would name the Public folder instead.
$script:HDTConsoleRoot = $PSScriptRoot

# THE DEFAULT WINDOW SIZE, AND THE FLOOR UNDER A REMEMBERED ONE. They are here
# rather than in either command because the reader and the writer must agree
# about them, and because they have to match UI\HDTConsole.xaml's Height, Width,
# MinHeight and MinWidth - a test asserts that they do.
#
# 1800 x 900 was measured, not chosen: the boot image pane is seventeen fields
# including two 64-character hashes, it wants 866 units of height to show all of
# it at once, and 1800 is what puts a full SHA-256 on one line beside its caption.
$script:HDTConsoleDefaultWidth = 1800
$script:HDTConsoleDefaultHeight = 900
$script:HDTConsoleMinimumWidth = 900
$script:HDTConsoleMinimumHeight = 520

# THE CONSOLE IS A THIN CLIENT OVER THE ENGINE (DESIGN 12): it may not do
# anything the cmdlets cannot. It therefore imports the engine rather than
# reimplementing any part of it, and it imports the one BESIDE it in the
# repository rather than whatever version happens to be on PSModulePath - the
# console and the engine ship together and a console reading a share through a
# different engine's parser is a console that disagrees with the deployment.
#
# Already-loaded wins, so a test that imported the engine with -Force keeps its
# instance and nothing is reloaded underneath it.
# -Global, AND IT IS LOAD-BEARING. A plain Import-Module here loads the engine
# into THIS module's session state only, where Get-Module does not list it - and
# Get-HDTStepType discovers step types by walking Get-Module (DESIGN 5.4, so
# that a third-party type dropped into Modules\ is found the moment it is
# imported). The console therefore came up with an Add menu offering 'New Group'
# and none of the ten step types the engine ships, on the one path that matters:
# an administrator running Start-HDTConsole.ps1, which imports this module and
# nothing else. Every test passed, because a test imports the engine itself.
#
# It is also the honest arrangement. DESIGN 12 says the console may not do
# anything the cmdlets can't and shows the invocation for everything it does;
# an administrator who reads one out of the window and types it should find the
# command there.
if (-not (Get-Module -Name 'Hephaestus')) {
    $enginePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Hephaestus/Hephaestus.psd1'
    Import-Module -Name $enginePath -Global -ErrorAction Stop
}

$privateFile = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$publicFile = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

foreach ($file in @($privateFile + $publicFile)) {
    try {
        . $file.FullName
    } catch {
        throw ("Failed to dot-source '{0}': {1}" -f $file.FullName, $_.Exception.Message)
    }
}

# Enumerate with ForEach-Object rather than member enumeration: an empty array's
# .BaseName behaves differently between engines under Set-StrictMode -Version Latest.
Export-ModuleMember -Function ($publicFile | ForEach-Object { $_.BaseName })
