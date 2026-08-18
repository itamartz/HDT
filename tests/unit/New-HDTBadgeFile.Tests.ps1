# THE TWO NUMBERS A README CAN SHOW WITHOUT ANYBODY OPENING THE BUILD LOG:
# how many tests ran, and how much of the engine they touched.
#
# WHY A JSON FILE AND NOT AN IMAGE. shields.io renders a badge from an
# "endpoint" document - {schemaVersion, label, message, color} - fetched from any
# public URL. CI writes these two files, pushes them to the orphan `badges`
# branch, and the README points shields at their raw URL. Nothing signs up for a
# coverage service, no token is stored, and the numbers cannot disagree with the
# run that produced them because the same build wrote both.
#
# THE BOM IS THE TRAP. Under Windows PowerShell 5.1 every convenient way of
# writing a file - Out-File, Set-Content, Add-Content, redirection - emits UTF-8
# WITH a byte order mark, and a BOM in front of `{` is not valid JSON to a
# strict parser. The badge would render as "invalid" with the file looking
# perfect in every editor. WriteAllText with a UTF8Encoding($false) is the only
# spelling that is safe here, so a test pins it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTBadgeFile' {

    It 'writes the file it was asked for' {
        $path = Join-Path -Path $TestDrive -ChildPath 'badges/tests.json'
        New-HDTBadgeFile -Path $path -Label 'tests' -Message '7950 passed' -Color 'brightgreen'

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
    }

    It 'creates the directory rather than failing on a missing one' {
        # out/ is removed by the clean task, so the first badge of every full
        # build writes into a directory that does not exist yet.
        $path = Join-Path -Path $TestDrive -ChildPath 'not/made/yet/tests.json'
        { New-HDTBadgeFile -Path $path -Label 'tests' -Message '1 passed' -Color 'green' } | Should -Not -Throw

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
    }

    It 'writes the document shields.io reads' {
        $path = Join-Path -Path $TestDrive -ChildPath 'coverage.json'
        New-HDTBadgeFile -Path $path -Label 'coverage' -Message '83%' -Color 'green'

        $badge = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))

        $badge.schemaVersion | Should -Be 1
        $badge.label | Should -BeExactly 'coverage'
        $badge.message | Should -BeExactly '83%'
        $badge.color | Should -BeExactly 'green'
    }

    It 'writes UTF-8 with no byte order mark' {
        # A BOM in front of { is not valid JSON, and shields.io renders the badge
        # as "invalid" while the file looks perfect in every editor.
        $path = Join-Path -Path $TestDrive -ChildPath 'bom.json'
        New-HDTBadgeFile -Path $path -Label 'tests' -Message '1 passed' -Color 'green'

        $byte = [System.IO.File]::ReadAllBytes($path)

        $byte[0] | Should -Be 0x7B   # '{', not 0xEF
    }

    It 'replaces the badge rather than appending to it' {
        $path = Join-Path -Path $TestDrive -ChildPath 'twice.json'
        New-HDTBadgeFile -Path $path -Label 'tests' -Message '1 passed' -Color 'green'
        New-HDTBadgeFile -Path $path -Label 'tests' -Message '2 passed' -Color 'green'

        (ConvertFrom-Json ([System.IO.File]::ReadAllText($path))).message | Should -BeExactly '2 passed'
    }

    It 'refuses an empty <Parameter>' -ForEach @(
        @{ Parameter = 'Label' }
        @{ Parameter = 'Message' }
        @{ Parameter = 'Color' }
    ) {
        $argument = @{
            Path    = (Join-Path -Path $TestDrive -ChildPath 'refused.json')
            Label   = 'tests'
            Message = '1 passed'
            Color   = 'green'
        }
        $argument[$Parameter] = ''

        { New-HDTBadgeFile @argument } | Should -Throw
    }
}

Describe 'Get-HDTBadgeColor' {

    It 'calls <Percent>% <Expected>' -ForEach @(
        @{ Percent = 100; Expected = 'brightgreen' }
        @{ Percent = 90; Expected = 'brightgreen' }
        @{ Percent = 89.9; Expected = 'green' }
        @{ Percent = 80; Expected = 'green' }
        @{ Percent = 70; Expected = 'yellowgreen' }
        @{ Percent = 60; Expected = 'yellow' }
        @{ Percent = 50; Expected = 'orange' }
        @{ Percent = 49.9; Expected = 'red' }
        @{ Percent = 0; Expected = 'red' }
    ) {
        Get-HDTBadgeColor -Percent $Percent | Should -BeExactly $Expected
    }

    It 'refuses a percentage outside 0 to 100' {
        # A coverage number above 100 means the sum was computed wrong, and a
        # badge is the last place that should be discovered.
        { Get-HDTBadgeColor -Percent 101 } | Should -Throw
        { Get-HDTBadgeColor -Percent -1 } | Should -Throw
    }
}
