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

# THE SAME FOUR NUMBERS FOR THE TASK SEQUENCE EDITOR, and they must match
# UI\Console\HDTSequenceEditor.xaml's Height, Width, MinHeight and MinWidth for
# the same reason - a test asserts that too.
#
# THE EDITOR NORMALLY IGNORES THESE, because it opens at the size of the console
# it was double-clicked in. They are what Resolve-HDTConsoleEditorSize answers
# with when there is no console: Show-HDTSequenceEditor is a command, and it can
# be run on a share with no window open anywhere.
$script:HDTConsoleEditorDefaultWidth = 1180
$script:HDTConsoleEditorDefaultHeight = 760
$script:HDTConsoleEditorMinimumWidth = 820
$script:HDTConsoleEditorMinimumHeight = 480

$privateFile = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$publicFile = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

# ONE FILE IF THERE IS ONE, 363 IF THERE IS NOT.
#
# Dot-sourcing the sources costs 2.46 seconds on the lab host: PowerShell parses
# 2.6 MB of script - comment-based help included - and pays the per-file cost
# every time. The same code concatenated parses in 1.37. That second is what
# somebody watches nothing happen for after Start-HDTConsole -Detach, which
# starts a fresh powershell.exe and imports this module cold before it can draw.
#
# THE BUNDLE IS GENERATED AND NEVER COMMITTED. Write-HDTModuleBundle writes it;
# ./build.ps1 -Task bundle is what runs that.
#
# AND A STALE ONE IS NEVER USED. If any source is newer than the bundle, the
# bundle is ignored and the files are dot-sourced - so editing a file is always
# what runs, whether or not anybody remembered to rebuild. Enumerating the
# sources costs 11ms and has already happened above, so the check is free.
$bundlePath = Join-Path -Path $PSScriptRoot -ChildPath 'Hephaestus.bundle.ps1'
$bundle = $null

if (Test-Path -LiteralPath $bundlePath) {
    $candidate = Get-Item -LiteralPath $bundlePath

    $newest = @(@($privateFile + $publicFile) | Sort-Object -Property LastWriteTimeUtc -Descending)

    if (@($newest).Count -eq 0 -or $candidate.LastWriteTimeUtc -ge $newest[0].LastWriteTimeUtc) {
        $bundle = $candidate
    }
}

if ($null -ne $bundle) {
    try {
        . $bundle.FullName
    } catch {
        throw ("Failed to dot-source '{0}': {1}. Delete it and import again - it is a generated file, and the module loads from its sources without it." -f
            $bundle.FullName, $_.Exception.Message)
    }
} else {
    foreach ($file in @($privateFile + $publicFile)) {
        try {
            . $file.FullName
        } catch {
            throw ("Failed to dot-source '{0}': {1}" -f $file.FullName, $_.Exception.Message)
        }
    }
}

# Enumerate with ForEach-Object rather than member enumeration: an empty array's
# .BaseName behaves differently between engines under Set-StrictMode -Version Latest.
Export-ModuleMember -Function ($publicFile | ForEach-Object { $_.BaseName })
