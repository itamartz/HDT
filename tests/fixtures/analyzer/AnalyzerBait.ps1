# DELIBERATELY DIRTY. Do not clean this file up.
#
# It exists so the self-check can prove PSScriptAnalyzer actually reports
# violations with PSScriptAnalyzerSettings.psd1 in force - in particular that
# PSUseCompatibleSyntax fires, as an Error, against the TargetVersions declared
# there.
#
# It lives under tests/fixtures/, which Get-HDTSourceFile excludes, so it is
# never linted as part of lint and never parsed by the naming or 5.1
# compatibility contracts. Nothing may dot-source it.
#
# TWO PIECES OF BAIT, BECAUSE PSUseCompatibleSyntax READS THE FILE WITH THE
# PARSER OF THE EDITION IT IS RUNNING UNDER. That parser can only report a
# construct it managed to parse, so a rule running under 5.1 can never report a
# 5.1 incompatibility - by the time it has an AST, the syntax was 5.1-legal.
# One line each way is therefore the only arrangement that fires under both:
#
#   ??        parses under 7, flagged as unavailable in 5.1;
#   workflow  parses under 5.1, flagged as unavailable in 6/7.
#
# Only the workflow fired on the CI 5.1 leg, which is how the ?? line was found
# to be proving nothing there - the leg was green only because PSScriptAnalyzer
# was absent on the developer machine and the check skipped itself.

function Get-HDTAnalyzerBait {
    $value = $null
    $result = $value ?? 'fallback'   # PSUseCompatibleSyntax (Error) - PS7-only
    Write-Host $result               # PSAvoidUsingWriteHost (Warning)
    gci C:\ | ? { $_.Name }          # PSAvoidUsingCmdletAliases (Warning) x2
}

workflow Get-HDTAnalyzerBaitWorkflow {   # PSUseCompatibleSyntax (Error) - 5.1 only
    Get-Process
}
