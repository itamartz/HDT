# DELIBERATELY UNPARSEABLE, and deliberately carrying the S9.15 violation.
#
# The brace opened by the Describe below is never closed, so
# [System.Management.Automation.Language.Parser]::ParseFile reports errors on
# both engines and the AST walk has nothing to walk. Returning nothing for a file
# like this would let the violation hide behind a syntax error, so the scanner
# falls back to a line scan and says so in the message - the same discipline
# Get-HDTMdtDependency carries, for the same reason.

BeforeDiscovery {
    $script:skipSlow = -not (Test-Path -LiteralPath 'C:\HDTLab\media' -PathType Container)
}

BeforeAll {
    if (-not $script:skipSlow) {
        $script:disk = 'built the expensive thing'
    }
}

Describe 'a slow suite' -Skip:$skipSlow {
    It 'does something slow' {
        $script:disk | Should -Not -BeNullOrEmpty
