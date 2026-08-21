# The name on the banner (DESIGN 3.2, MDT's _SMSTSOrgName).
#
# MDT PUTS THE ORGANISATION'S NAME ON THE DEPLOYMENT WINDOW, and the reason is
# not vanity: a technician at a bench is often looking at two toolkits, and the
# banner is the fastest way to know which one has this machine. HDT's banner
# said 'Hephaestus' on every machine ever built from it.
#
# THE DECISION IS PURE. The window that draws it is an adapter no Pester test
# can open, so what the value MEANS - trimmed, and what an unset one falls back
# to - is settled here where it can be asserted.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTBrandingName' {

    It 'returns the name it was given' {
        Get-HDTBrandingName -Value 'Contoso' | Should -BeExactly 'Contoso'
    }

    It 'trims the space a YAML editor left behind' {
        Get-HDTBrandingName -Value '  Contoso  ' | Should -BeExactly 'Contoso'
    }

    It 'falls back to Hephaestus when nothing was set' {
        # The banner every machine built before this variable existed carried,
        # so a share that never mentions it looks exactly as it did.
        Get-HDTBrandingName -Value '' | Should -BeExactly 'Hephaestus'
    }

    It 'falls back to Hephaestus for a null value' {
        Get-HDTBrandingName -Value $null | Should -BeExactly 'Hephaestus'
    }

    It 'falls back to Hephaestus for a value that is only space' {
        # A wizard box a technician cleared, or a rule that resolved to nothing.
        # A banner painted with three spaces is a banner nobody can read.
        Get-HDTBrandingName -Value '   ' | Should -BeExactly 'Hephaestus'
    }

    It 'returns the fallback when it is not given a value at all' {
        Get-HDTBrandingName | Should -BeExactly 'Hephaestus'
    }

    It 'keeps the inner space of a real organisation name' {
        Get-HDTBrandingName -Value 'Contoso Field Services' | Should -BeExactly 'Contoso Field Services'
    }
}
