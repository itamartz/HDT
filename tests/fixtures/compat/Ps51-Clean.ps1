# Fixture: valid Windows PowerShell 5.1. Must yield zero compatibility violations.

function Get-HDTCleanSample {
    param([string] $Path)

    if ($Path) {
        Write-Output $Path
    }
}
