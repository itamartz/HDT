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

# ONE FILE. ALWAYS THE BUNDLE, NEVER THE 377 IT WAS BUILT FROM.
#
# Dot-sourcing the sources costs 2.46 seconds on the lab host: PowerShell parses
# 2.6 MB of script - comment-based help included - and pays the per-file cost
# every time. The same code concatenated parses in 1.37. That second is what
# somebody watches nothing happen for after Start-HDTConsole -Detach, which
# starts a fresh powershell.exe and imports this module cold before it can draw.
#
# THERE USED TO BE A SECOND WAY IN - a fallback that dot-sourced the files one
# by one whenever the bundle was missing or stale. It is gone. Two load paths
# for one module is two sets of line numbers in a stack trace, two shapes of
# coverage report, and a standing difference between what a developer runs and
# what ships to a machine mid-deployment.
#
# THE BUNDLE IS GENERATED AND NEVER COMMITTED. Write-HDTModuleBundle writes it;
# ./build.ps1 -Task bundle is what runs that deliberately, and the block below
# is what runs it when nobody did.
$bundlePath = Join-Path -Path $PSScriptRoot -ChildPath 'Hephaestus.bundle.ps1'

# THE SOURCES ARE HERE OR THEY ARE NOT, and which it is decides everything below.
# In a working tree they are, and this module is expected to reflect whatever was
# last saved. In a boot image, on a deployed disk, or in a package off the
# Gallery there is only the bundle - ./build.ps1 -Task build drops Private\ and
# Public\ once it has bundled them - and there is nothing to compare against.
$sourceFile = @(
    @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
)

# A STALE BUNDLE IS REBUILT, NOT SIDESTEPPED AND NOT TOLERATED.
#
# A generated file older than the sources it came from would run yesterday's code
# while today's is on disk: the worst failure this repository could ship, because
# nothing looks wrong. And 266 test files import this manifest directly, so
# refusing instead would put a build task between every edit and every test run.
#
# Enumerating the sources costs 11ms, and it has already happened above.
$stale = $false

if (@($sourceFile).Count -gt 0) {
    if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
        $stale = $true
    } else {
        $newest = @($sourceFile | Sort-Object -Property LastWriteTimeUtc -Descending)[0]

        if ((Get-Item -LiteralPath $bundlePath).LastWriteTimeUtc -lt $newest.LastWriteTimeUtc) {
            $stale = $true
        }
    }
}

if ($stale) {
    # TWO FILES BY NAME, BECAUSE THE ONE THAT LOADS EVERYTHING DOES NOT EXIST YET.
    # The writer, and the single private helper its refusal path calls. Anything
    # more than this is the fallback growing back.
    $bootstrap = @(
        (Join-Path -Path $PSScriptRoot -ChildPath 'Private\New-HDTErrorRecord.ps1'),
        (Join-Path -Path $PSScriptRoot -ChildPath 'Public\Write-HDTModuleBundle.ps1')
    )

    foreach ($needed in $bootstrap) {
        if (-not (Test-Path -LiteralPath $needed -PathType Leaf)) {
            throw ("Cannot build '{0}': '{1}' is missing. The module has sources but not the two files that turn them into a bundle - check out the tree again, or run ./build.ps1 -Task bundle from a complete one." -f
                $bundlePath, $needed)
        }

        . $needed
    }

    try {
        [void] (Write-HDTModuleBundle -ModuleRoot $PSScriptRoot)
    } catch {
        # A READ-ONLY TREE IS THE LIKELY ONE, and the message has to say so:
        # without a fallback there is no quiet way through this.
        throw ("Failed to build '{0}': {1}. The sources here are newer than the bundle and the module loads only the bundle, so this has to succeed - check the folder is writable." -f
            $bundlePath, $_.Exception.Message)
    }
}

if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    # NO BUNDLE AND NO SOURCES. A package that shipped without the one file it
    # consists of; there is nothing on disk to recover from.
    throw ("'{0}' is missing and there are no sources here to build it from. Reinstall the module - this package ships the bundle only." -f
        $bundlePath)
}

try {
    . $bundlePath
} catch {
    throw ("Failed to dot-source '{0}': {1}. It is a generated file - delete it and import again to have it rebuilt, or reinstall the module if this package ships no sources." -f
        $bundlePath, $_.Exception.Message)
}

# WHAT TO EXPORT COMES OUT OF THE BUNDLE, because the Public\ folder may not have
# travelled with it.
#
# That is the normal case for the copy that matters: one file in a boot image and
# on the disk of every machine HDT deploys. Enumerating Public\ there would find
# nothing, load every function and export NONE of them - an import with no error
# and CommandNotFound for everything, on a machine halfway through a deployment
# with nobody watching. Write-HDTModuleBundle writes the list, because the names
# are known at the moment it is built.
#
# Get-Variable, not $script:HDTBundleExport: under Set-StrictMode -Version Latest
# naming a variable that was never assigned is an error, and a hand-mangled
# bundle that never assigned it should say so rather than fail obscurely.
$exportName = Get-Variable -Name 'HDTBundleExport' -Scope Script -ValueOnly -ErrorAction SilentlyContinue

if ($null -eq $exportName) {
    throw ("'{0}' carries no export list, so nothing would be exported from it. It is a generated file - delete it and import again, or rebuild it with ./build.ps1 -Task bundle." -f
        $bundlePath)
}

Export-ModuleMember -Function @($exportName)
