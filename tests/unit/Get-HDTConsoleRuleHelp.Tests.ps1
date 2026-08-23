# WHAT THE ? ON THE RULES AND BOOTSTRAP TABS SHOWS.
#
# A rules file is written in a vocabulary nobody can hold in their head: forty
# variable names, the MDT names they came from, and now MDT's #Left(...)#
# expressions. The window that edits rules.yaml offered none of it, so the only
# way to find out what may be written was to read DESIGN.md - on another
# machine, because this window is usually open over a share.
#
# THE LIST IS DERIVED, NEVER TYPED. Get-HDTVariableMap already carries every
# variable, its MDT name, where it comes from and what it means; a second list
# in a XAML file would be one that goes stale the first time a variable is
# added, and going stale silently is the whole failure mode of documentation
# inside a product.
#
# THREE GROUPS, BECAUSE THAT IS THE QUESTION BEING ASKED. Somebody writing a
# rule wants to know which names they may SET, which the machine will REPORT so
# they can match on them, and which the engine fills in so they should not.
# Get-HDTVariableMap's Origin is per-source - Win32_BIOS.SerialNumber,
# authored, engine - which is the right grain for a document and the wrong one
# for a panel with a scrollbar.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot

    $script:help = Get-HDTConsoleRuleHelp
}

Describe 'Get-HDTConsoleRuleHelp' {

    Context 'the expressions, which is why this exists at all' {

        BeforeAll {
            $script:expression = @($script:help.Section | Where-Object { $_.Kind -eq 'Expression' })
        }

        It 'is one section, first, because it is the thing nobody knows is there' {
            @($script:expression).Count | Should -Be 1
            @($script:help.Section)[0].Kind | Should -BeExactly 'Expression'
        }

        It 'lists every function the engine will actually evaluate' {
            $name = @($script:expression[0].Row | ForEach-Object { $_.Name })

            $name | Should -Contain 'Left'
            $name | Should -Contain 'Right'
            $name | Should -Contain 'Mid'
            $name | Should -Contain 'UCase'
            $name | Should -Contain 'LCase'
            $name | Should -Contain 'Trim'
        }

        # A SIGNATURE IS NOT AN EXAMPLE. 'Left(text, count)' tells somebody
        # nothing they could not guess; the line that shortens a 35-character
        # serial to something Windows Setup will accept is the reason they
        # opened this panel.
        It 'shows each one as a line that could be pasted into the rule' {
            foreach ($row in @($script:expression[0].Row)) {
                $row.Example | Should -Match '^#'
                $row.Example | Should -Match '#$'
            }
        }

        It 'shows what the example produces, not only what it says' {
            $left = @($script:expression[0].Row | Where-Object { $_.Name -eq 'Left' })[0]

            $left.Result | Should -Not -BeNullOrEmpty
            $left.Result.Length | Should -BeLessOrEqual 15
        }
    }

    Context 'the variables, grouped by the question being asked' {

        It 'has a group for what an administrator may set' {
            $set = @($script:help.Section | Where-Object { $_.Kind -eq 'Authored' })

            @($set).Count | Should -Be 1
            @($set[0].Row).Count | Should -BeGreaterThan 10
        }

        It 'has a group for what the machine reports, which rules match on' {
            $gathered = @($script:help.Section | Where-Object { $_.Kind -eq 'Gathered' })

            @($gathered).Count | Should -Be 1
            @($gathered[0].Row | ForEach-Object { $_.Name }) | Should -Contain 'HDTSerialNumber'
        }

        It 'has a group for what the engine fills in, so nobody sets those' {
            $engine = @($script:help.Section | Where-Object { $_.Kind -eq 'Engine' })

            @($engine).Count | Should -Be 1
            @($engine[0].Row).Count | Should -BeGreaterThan 5
        }

        It 'accounts for every variable the map knows, in exactly one group' {
            $mapped = @(Get-HDTVariableMap | ForEach-Object { $_.HDTName }) | Sort-Object -Unique

            $shown = @($script:help.Section |
                    Where-Object { $_.Kind -ne 'Expression' } |
                    ForEach-Object { $_.Row } | ForEach-Object { $_.Name })

            @($shown | Sort-Object -Unique) | Should -Be $mapped
            @($shown).Count | Should -Be @($mapped).Count -Because 'a variable in two groups is a variable somebody reads twice'
        }

        # THE MDT NAME IS THE COLUMN THIS PANEL IS FOR. Somebody with a
        # CustomSettings.ini in front of them is translating, not learning.
        It 'carries the MDT name beside HDT own' {
            $serial = @($script:help.Section |
                    Where-Object { $_.Kind -ne 'Expression' } |
                    ForEach-Object { $_.Row } |
                    Where-Object { $_.Name -eq 'HDTSerialNumber' })[0]

            $serial.MdtName | Should -BeExactly 'SerialNumber'
        }

        It 'says what each one means' {
            $empty = @($script:help.Section |
                    Where-Object { $_.Kind -ne 'Expression' } |
                    ForEach-Object { $_.Row } |
                    Where-Object { [string]::IsNullOrWhiteSpace($_.Description) })

            @($empty).Count | Should -Be 0
        }
    }

    Context 'what the window needs from it' {

        It 'gives every section a heading to render' {
            foreach ($section in @($script:help.Section)) {
                $section.Title | Should -Not -BeNullOrEmpty
            }
        }

        # ONE TEMPLATE, NOT A TemplateSelector - see the command's own comment.
        It 'offers the whole thing flat, with a heading flag the markup can bind' {
            @($script:help.Line).Count | Should -BeGreaterThan @($script:help.Section).Count

            $header = @($script:help.Line | Where-Object { $_.IsHeader })

            @($header).Count | Should -Be @($script:help.Section).Count
            @($header | ForEach-Object { $_.Left }) | Should -Contain 'Expressions'
        }

        It 'puts the MDT name in the middle column, where a translator looks' {
            $serial = @($script:help.Line | Where-Object { $_.Left -eq 'HDTSerialNumber' })[0]

            $serial.Middle | Should -BeExactly 'SerialNumber'
        }

        # DOUBLE-CLICK TAKES THE ROW INTO THE EDITOR, so each row has to say what
        # it puts there. A reference list you cannot take anything from is half a
        # feature - and retyping HDTSecureBootEnabled from a panel that is
        # covering the box is how a rule gets a typo nothing catches until a
        # deployment runs.
        It 'says what each row inserts' {
            $serial = @($script:help.Line | Where-Object { $_.Left -eq 'HDTSerialNumber' })[0]

            # THE BARE NAME. A variable is written both ways in a rules file -
            # as a key under set:, and as %HDTSerialNumber% in a value - and the
            # name is the half that is the same in both.
            $serial.Insert | Should -BeExactly 'HDTSerialNumber'
        }

        It 'inserts an expression as the whole expression, ready to edit' {
            $left = @($script:help.Line | Where-Object { $_.Left -like '#Left(*' })[0]

            $left.Insert | Should -BeExactly $left.Left
        }

        It 'inserts nothing from a heading' {
            foreach ($header in @($script:help.Line | Where-Object { $_.IsHeader })) {
                $header.Insert | Should -BeExactly ''
            }
        }

        It 'is pure - the same call twice gives the same answer' {
            $again = Get-HDTConsoleRuleHelp

            @($again.Section).Count | Should -Be @($script:help.Section).Count
        }
    }
}


}
