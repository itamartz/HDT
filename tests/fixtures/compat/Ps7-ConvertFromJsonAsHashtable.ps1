# Fixture: ConvertFrom-Json -AsHashtable does not exist in Windows PowerShell 5.1.

function Get-HDTJsonSample {
    '{}' | ConvertFrom-Json -AsHashtable
}
