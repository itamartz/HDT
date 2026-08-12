Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HDTModuleRoot = $PSScriptRoot

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
