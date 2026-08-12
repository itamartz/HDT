Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HDTTestToolsRoot = $PSScriptRoot

$toolFile = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'tools') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

foreach ($file in $toolFile) {
    try {
        . $file.FullName
    } catch {
        throw ("Failed to dot-source '{0}': {1}" -f $file.FullName, $_.Exception.Message)
    }
}

Export-ModuleMember -Function ($toolFile | ForEach-Object { $_.BaseName })
