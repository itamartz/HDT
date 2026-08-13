# The fixed shape, and the one tests/integration/ImageService.Integration.Tests.ps1
# and tests/e2e/Deployment.E2E.Tests.ps1 now use: discovery computes its own copy
# for -Skip:, and BeforeAll RECOMPUTES the condition from the same inputs rather
# than reaching across the phase boundary for it.
#
# The scanner must report nothing for this file.

BeforeDiscovery {
    $script:mediaPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:skipSlow = -not (Test-Path -LiteralPath $script:mediaPath -PathType Leaf)
}

BeforeAll {
    $script:mediaPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:skipSlow = -not (Test-Path -LiteralPath $script:mediaPath -PathType Leaf)

    if (-not $script:skipSlow) {
        $script:disk = 'built the expensive thing'
    }
}

Describe 'a slow suite' -Skip:$skipSlow {
    It 'does something slow' {
        $script:disk | Should -Not -BeNullOrEmpty
    }
}
