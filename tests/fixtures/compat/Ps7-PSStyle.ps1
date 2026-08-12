# Fixture: the $PSStyle automatic variable does not exist in Windows PowerShell 5.1.

function Get-HDTStyleSample {
    Write-Output $PSStyle.Foreground.Red
}
