Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The module's own directory, so Show-HDTConsole can default -XamlPath to the
# window that ships beside it. Resolved once, here, rather than from $PSScriptRoot
# inside a dot-sourced function, where it would name the Public folder instead.
$script:HDTConsoleRoot = $PSScriptRoot

# THE CONSOLE IS A THIN CLIENT OVER THE ENGINE (DESIGN 12): it may not do
# anything the cmdlets cannot. It therefore imports the engine rather than
# reimplementing any part of it, and it imports the one BESIDE it in the
# repository rather than whatever version happens to be on PSModulePath - the
# console and the engine ship together and a console reading a share through a
# different engine's parser is a console that disagrees with the deployment.
#
# Already-loaded wins, so a test that imported the engine with -Force keeps its
# instance and nothing is reloaded underneath it.
if (-not (Get-Module -Name 'Hephaestus')) {
    $enginePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Hephaestus/Hephaestus.psd1'
    Import-Module -Name $enginePath -ErrorAction Stop
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
