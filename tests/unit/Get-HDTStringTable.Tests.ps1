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

    Context 'one window at a time' {

        It 'returns the block it was asked for' {
            $table = Get-HDTStringTable -Page 'BootImage'

            $table.Count | Should -BeGreaterThan 20
            @($table.Keys) | Should -Contain 'HDTBootImageImageNameLabel.Text'
        }

        It 'merges every block when no page is named' {
            @(Get-HDTStringTable).Count | Should -BeGreaterOrEqual @(Get-HDTStringTable -Page 'BootImage').Count
        }

        It 'refuses a page name nothing carries' {
            # THE MARKUP HAS NO TEXT LEFT, so an empty table is a window of
            # blank labels rather than a window with nothing to translate - and
            # a typo nobody could see from a screenshot.
            { Get-HDTStringTable -Page 'BootImageee' } | Should -Throw
        }

        It 'names the blocks it does have in the refusal' {
            $message = ''
            try { Get-HDTStringTable -Page 'NoSuchWindow' } catch { $message = [string] $_.Exception.Message }

            $message | Should -BeLike '*BootImage*'
        }
    }

    Context 'the words that belong to no one window' {

        It 'ships a Common block' {
            @(Get-HDTStringTable -Page 'BootImage').Keys | Should -Contain 'HDTSaveButton.Content'
        }

        It 'merges Common under whichever page was asked for' {
            # Save is spelled the same way on every screen, and a page block
            # that had to carry it would be a page block that could disagree.
            [string] (Get-HDTStringTable -Page 'BootImage')['HDTCancelButton.Content'] |
                Should -BeExactly 'Cancel'
        }

        It 'does not let Common alone answer for a page that does not exist' {
            # Otherwise a typo'd page name would return the shared words and
            # nothing else - a window with three buttons and no labels.
            { Get-HDTStringTable -Page 'NoSuchWindow' } | Should -Throw
        }

        It 'lets a page override a shared word' {
            $root = Join-Path -Path $TestDrive -ChildPath 'Override'
            [void] (New-Item -ItemType Directory -Path $root -Force)

            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'en-us.psd1') -Encoding UTF8 `
                -Value "@{`n  Common = @{`n    'HDTSaveButton.Content' = 'Save'`n  }`n  Odd = @{`n    'HDTSaveButton.Content' = 'Write it down'`n  }`n}"

            [string] (Get-HDTStringTable -Path $root -Page 'Odd')['HDTSaveButton.Content'] |
                Should -BeExactly 'Write it down'
        }
    }

    Context 'a culture nobody has translated' {

        It 'falls back to en-us rather than throwing' {
            $table = Get-HDTStringTable -Culture 'fr-FR'

            $table.Count | Should -BeGreaterThan 20

            # ASKED OF THE KEYS, NOT OF THE OBJECT. '$table.Culture' reads as
            # the same question and is not: under Set-StrictMode -Version
            # Latest - which build.ps1 sets and a bare Invoke-Pester does not -
            # a missing key on a hashtable is a terminating error, so this
            # passed all the way to the gate and failed there.
            @($table.Keys) | Should -Not -Contain 'Culture'
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

            # THE SHAPE THE SHIPPED TABLE USES: a block per window, keys inside
            # it. A culture is named xx-xx here on purpose - which language it
            # is has nothing to do with what this asserts.
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'en-us.psd1') -Encoding UTF8 `
                -Value "@{`n  BootImage = @{`n    'A.Text' = 'the shipped one'`n    'B.Text' = 'only in the shipped table'`n  }`n}"

            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'xx-xx.psd1') -Encoding UTF8 `
                -Value "@{`n  BootImage = @{`n    'A.Text' = 'the translated one'`n  }`n}"
        }

        It 'loads the culture that exists' {
            [string] (Get-HDTStringTable -Culture 'xx-xx' -Path $script:root)['A.Text'] |
                Should -BeExactly 'the translated one'
        }

        It 'fills a key the translation is missing from the en-us table' {
            # HALF A TRANSLATION IS STILL USABLE. A key nobody has translated
            # shows the shipped English rather than nothing at all, which is
            # what makes it safe to ship a language before it is finished.
            [string] (Get-HDTStringTable -Culture 'xx-xx' -Path $script:root)['B.Text'] |
                Should -BeExactly 'only in the shipped table'
        }

        It 'takes one block from each file' {
            [string] (Get-HDTStringTable -Culture 'xx-xx' -Path $script:root -Page 'BootImage')['A.Text'] |
                Should -BeExactly 'the translated one'
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
