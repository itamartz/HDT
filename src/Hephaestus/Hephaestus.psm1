Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HDTModuleRoot = $PSScriptRoot

# THE DEFAULT CONSOLE WINDOW SIZE, AND THE FLOOR UNDER A REMEMBERED ONE. They are
# here rather than in either command because the reader and the writer must agree
# about them, and because they have to match UI\Console\HDTConsole.xaml's Height,
# Width, MinHeight and MinWidth - a test asserts that they do.
#
# 1800 x 900 was measured, not chosen: the boot image pane is seventeen fields
# including two 64-character hashes, it wants 866 units of height to show all of
# it at once, and 1800 is what puts a full SHA-256 on one line beside its caption.
$script:HDTConsoleDefaultWidth = 1800
$script:HDTConsoleDefaultHeight = 900
$script:HDTConsoleMinimumWidth = 900
$script:HDTConsoleMinimumHeight = 520

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
