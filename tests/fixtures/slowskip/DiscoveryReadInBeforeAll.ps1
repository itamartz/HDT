# A deliberate SPIKES S9.15 violation, kept as a fixture so the scanner is
# proven against the exact shape that took tests/integration down.
#
# $script:skipSlow is set in BeforeDiscovery and READ in BeforeAll without being
# recomputed there. Pester's discovery and run phases do not share a scope, so
# under Set-StrictMode -Version Latest the read throws; without StrictMode it is
# $null, and 'if (-not $null)' is TRUE, so the expensive body runs on a machine
# that was supposed to be skipping it.
#
# Nothing runs this file: tests/fixtures is outside Run.Path and outside
# Get-HDTSourceFile.

BeforeDiscovery {
    $script:mediaPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:skipSlow = -not (Test-Path -LiteralPath $script:mediaPath -PathType Leaf)
}

BeforeAll {
    if (-not $script:skipSlow) {
        $script:disk = 'built the expensive thing'
    }
}

Describe 'a slow suite' -Skip:$skipSlow {
    It 'does something slow' {
        $script:disk | Should -Not -BeNullOrEmpty
    }
}
