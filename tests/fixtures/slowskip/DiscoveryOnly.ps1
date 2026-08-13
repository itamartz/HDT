# A discovery variable used ONLY where discovery variables are legal: on the
# -Skip: of a Describe, which is evaluated during discovery. Nothing reads it
# from a run body, so the scanner must report nothing.

BeforeDiscovery {
    $script:skipSlow = -not (Test-Path -LiteralPath 'C:\HDTLab\media' -PathType Container)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'a slow suite' -Skip:$skipSlow {
    It 'does something slow' {
        $script:repoRoot | Should -Not -BeNullOrEmpty
    }
}
