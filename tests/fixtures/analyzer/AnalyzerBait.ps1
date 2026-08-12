# DELIBERATELY DIRTY. Do not clean this file up.
#
# It exists so the self-check can prove PSScriptAnalyzer actually reports
# violations with PSScriptAnalyzerSettings.psd1 in force - in particular that
# PSUseCompatibleSyntax is targeting 5.1 and therefore flags PS7-only syntax as
# an Error.
#
# It lives under tests/fixtures/, which Get-HDTSourceFile excludes, so it is
# never linted as part of lint and never parsed by the naming or 5.1
# compatibility contracts. That exclusion matters: the ?? below is a PARSE ERROR
# under Windows PowerShell 5.1, so nothing may dot-source or ParseFile this file.
# Only Invoke-ScriptAnalyzer, running under pwsh 7, ever reads it.

function Get-HDTAnalyzerBait {
    $value = $null
    $result = $value ?? 'fallback'   # PSUseCompatibleSyntax (Error) - PS7-only
    Write-Host $result               # PSAvoidUsingWriteHost (Warning)
    gci C:\ | ? { $_.Name }          # PSAvoidUsingCmdletAliases (Warning) x2
}
