# THE TEXT ON SCREEN, IN A FILE RATHER THAN IN THE MARKUP.
#
# Every label, hint, button and tab header was a literal in XAML, so changing a
# sentence meant editing a window and translating one meant forking it. This is
# the table those strings move into: one .psd1 per culture, in the module's
# Strings folder, loaded at runtime.
#
# IT FALLS BACK RATHER THAN FAILS. A culture nobody has translated yet gets
# en-us, and a key nobody has translated yet gets the en-us string - because a
# half-translated console is still a usable console, and a blank label is not.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:stringRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings'
}

Describe 'Get-HDTStringTable' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTStringTable' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'ships an en-us table' {
            Join-Path -Path $script:stringRoot -ChildPath 'en-us.psd1' | Should -Exist
        }
    }

    Context 'what it returns' {

        It 'reads the shipped table' {
            $table = Get-HDTStringTable

            $table.Count | Should -BeGreaterThan 20
        }

        It 'is case-insensitive, as every lookup in this engine is' {
            $table = Get-HDTStringTable

            $key = @($table.Keys)[0]
            $table[$key.ToUpperInvariant()] | Should -BeExactly ([string] $table[$key])
        }

        It 'gives every value as a string' {
            foreach ($value in @((Get-HDTStringTable).Values)) {
                $value | Should -BeOfType [string]
            }
        }

        It 'names its keys Control.Property, which is what the walker splits on' {
            foreach ($key in @((Get-HDTStringTable).Keys)) {
                ([string] $key) | Should -Match '^[A-Za-z0-9_]+\.[A-Za-z]+$'
            }
        }
    }

    Context 'a culture nobody has translated' {

        It 'falls back to en-us rather than throwing' {
            $table = Get-HDTStringTable -Culture 'fr-FR'

            $table.Count | Should -BeGreaterThan 20
            [string] $table.Culture | Should -BeNullOrEmpty
        }

        It 'says which culture it actually loaded' {
            (Get-HDTStringTable -Culture 'fr-FR' -PassThruCulture) | Should -BeExactly 'en-us'
            (Get-HDTStringTable -Culture 'en-us' -PassThruCulture) | Should -BeExactly 'en-us'
        }
    }

    Context 'a table of its own' {

        BeforeEach {
            $script:root = Join-Path -Path $TestDrive -ChildPath 'Strings'
            [void] (New-Item -ItemType Directory -Path $script:root -Force)

            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'en-us.psd1') `
                -Value "@{`n  'A.Text' = 'the english one'`n  'B.Text' = 'only in english'`n}" -Encoding UTF8

            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'he-il.psd1') `
                -Value "@{`n  'A.Text' = 'the hebrew one'`n}" -Encoding UTF8
        }

        It 'loads the culture that exists' {
            [string] (Get-HDTStringTable -Culture 'he-il' -Path $script:root)['A.Text'] |
                Should -BeExactly 'the hebrew one'
        }

        It 'fills a key the translation is missing from the en-us table' {
            # HALF A TRANSLATION IS STILL USABLE. A key nobody has translated
            # shows the English rather than nothing at all, which is what makes
            # it safe to ship a language before it is finished.
            [string] (Get-HDTStringTable -Culture 'he-il' -Path $script:root)['B.Text'] |
                Should -BeExactly 'only in english'
        }

        It 'refuses a Strings folder with no en-us at all' {
            # en-us IS THE FLOOR. Without it a missing key has nothing to fall
            # back to, and the console would show blanks nobody could explain.
            $empty = Join-Path -Path $TestDrive -ChildPath 'Empty'
            [void] (New-Item -ItemType Directory -Path $empty -Force)

            { Get-HDTStringTable -Path $empty } | Should -Throw
        }
    }
}
