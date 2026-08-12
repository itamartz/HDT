# Fixture proving Get-HDTSourceFunction reads .psm1 as well as .ps1.

function Get-HDTModuleScopedThing {
    Write-Output 'module scoped'
}
