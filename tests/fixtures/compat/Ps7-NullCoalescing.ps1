# Fixture: PowerShell 7-only null-coalescing operator. Unparseable under 5.1.

$script:HDTValue = $null
$script:HDTResult = $script:HDTValue ?? 'fallback'
