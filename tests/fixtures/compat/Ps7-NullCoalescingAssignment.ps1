# Fixture: PowerShell 7-only null-coalescing assignment. Unparseable under 5.1.

$script:HDTValue = $null
$script:HDTValue ??= 'fallback'
