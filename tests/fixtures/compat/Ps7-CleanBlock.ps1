# Fixture: a PowerShell 7.3+ clean block. Under 7 the parser produces a
# ScriptBlockAst with a CleanBlock; under 5.1 the same text parses as a command
# named 'clean' taking a script block argument. Both routes must be caught.

function Get-HDTCleanBlockSample {
    clean { Write-Output 'x' }
}
