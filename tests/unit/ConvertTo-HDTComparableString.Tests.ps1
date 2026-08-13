# ConvertTo-HDTComparableString is the one place the resolution engine turns a
# value into the string it compares and substitutes.
#
# It exists because rules.yaml is YAML and facts are CIM: `HDTIsLaptop: true`
# arrives as a [bool] from the parser and as a [bool] from Win32_SystemEnclosure,
# while a wildcard pattern is always a [string]. Comparing them at all requires
# one agreed rendering, and it must be the SAME rendering on both engines and in
# every culture - a machine with a decimal comma must not resolve variables
# differently from one without.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'ConvertTo-HDTComparableString' {

    It 'returns null for null' {
        InModuleScope Hephaestus {
            ConvertTo-HDTComparableString -Value $null | Should -BeNullOrEmpty
        }
    }

    It 'returns a string unchanged' {
        InModuleScope Hephaestus {
            ConvertTo-HDTComparableString -Value 'Latitude 7450' | Should -BeExactly 'Latitude 7450'
        }
    }

    It 'renders true as True' {
        InModuleScope Hephaestus {
            ConvertTo-HDTComparableString -Value $true | Should -BeExactly 'True'
        }
    }

    It 'renders false as False' {
        InModuleScope Hephaestus {
            ConvertTo-HDTComparableString -Value $false | Should -BeExactly 'False'
        }
    }

    It 'renders an integer in the invariant culture' {
        InModuleScope Hephaestus {
            $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                # de-DE groups thousands with a dot. A culture-sensitive render
                # would produce '32.768' here, and a rules.yaml written against
                # 32768 would stop matching on a German machine.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')

                ConvertTo-HDTComparableString -Value ([int] 32768) | Should -BeExactly '32768'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
            }
        }
    }

    It 'renders a decimal in the invariant culture' {
        InModuleScope Hephaestus {
            $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                # de-DE renders 1.5 as '1,5' through ToString() and -f. Only an
                # explicit InvariantCulture render survives this.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')

                ConvertTo-HDTComparableString -Value ([decimal] '1.5') | Should -BeExactly '1.5'
                ConvertTo-HDTComparableString -Value ([double] 1.5) | Should -BeExactly '1.5'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
            }
        }
    }

    It 'renders an empty string as an empty string' {
        InModuleScope Hephaestus {
            ConvertTo-HDTComparableString -Value '' | Should -BeExactly ''
        }
    }
}
