# THE MARKUP AND THE STRING TABLE HAVE TO AGREE, and nothing else notices when
# they stop.
#
# A window converted to the table carries no text of its own: every label, hint
# and caption arrives at load time, found by control name. So a control renamed
# in the markup without its key renamed in the table is a BLANK LABEL - and a
# blank label looks like a layout bug, gets reported as one, and is invisible in
# every test that does not open a window.
#
# THIS FILE IS THE THING THAT NOTICES. Two directions, and both matter:
#
#   a key naming no control     dead text nobody will ever see, and usually the
#                               first half of a rename somebody did not finish
#   a literal left in markup    a string that cannot be translated or edited,
#                               hiding among five hundred that can
#
# WHAT IS DELIBERATELY NOT TEXT: the VALUES in a combo box - amd64, 512 MB -
# and glyph captions. Nobody translates a unit or a Segoe codepoint, and a table
# carrying them is a table a translator has to skip through.

# WHICH WINDOW IS WHICH BLOCK. A window converted to the table is added here,
# and that is what puts it under this contract.
#
# AT FILE SCOPE, NOT IN BeforeAll: -ForEach is read while Pester is DISCOVERING
# tests, and BeforeAll has not run by then - a table defined there discovers as
# an empty array and the whole file fails to load.
$script:converted = @(
    @{ Page = 'BootImage'; Xaml = 'src/Hephaestus/UI/Console/HDTBootImage.xaml' }
)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:namedControl = {
        param([string] $Path)

        $document = [xml] (Get-Content -LiteralPath $Path -Raw)

        return @($document.SelectNodes('//*[@*[local-name()="Name"]]') |
                ForEach-Object { [string] $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # A literal that a human would read: it has letters in it, it is not a
    # binding, and it is not sitting on a ComboBoxItem.
    $script:proseLiteral = {
        param([string] $Path)

        $found = New-Object System.Collections.ArrayList

        foreach ($line in @(Get-Content -LiteralPath $Path)) {

            if ($line -match '<ComboBoxItem') { continue }

            foreach ($match in @([regex]::Matches($line, '\b(Text|ToolTip|Content|Header)="([^"]+)"'))) {

                # DECODED BEFORE IT IS JUDGED, and the first run of this test is
                # why: '  &#x2192;  ' is an arrow, but the ENTITY contains the
                # letter x, so a raw check calls a glyph prose and demands
                # somebody translate an arrow.
                $value = [System.Net.WebUtility]::HtmlDecode([string] $match.Groups[2].Value)

                if ($value.TrimStart().StartsWith('{')) { continue }
                if ($value -notmatch '[A-Za-z]') { continue }

                [void] $found.Add($match.Value)
            }
        }

        return @($found)
    }
}

Describe 'the string table and the markup it fills: <Page>' -ForEach $script:converted {

    BeforeAll {
        $script:xamlPath = Join-Path -Path $script:repoRoot -ChildPath $Xaml
        $script:table = Get-HDTStringTable -Page $Page
        $script:control = & $script:namedControl $script:xamlPath
    }

    It 'has a window to fill' {
        $script:xamlPath | Should -Exist
    }

    It 'names a control that exists for every key' {
        # A KEY NAMING NO CONTROL IS DEAD TEXT, and usually half of a rename.
        # Common's keys are exempt one at a time rather than as a block: a
        # shared word that no window on this contract carries is still worth
        # keeping, because another window carries it.
        $orphan = @()
        foreach ($key in @($script:table.Keys)) {

            $name = [string] $key
            $split = $name.LastIndexOf('.')
            if ($split -gt 0) { $name = $name.Substring(0, $split) }

            if ($script:control -notcontains $name) { $orphan += [string] $key }
        }

        # The shared block is filled on windows this contract does not cover
        # yet, so its keys are allowed to be absent HERE.
        $common = @(Get-HDTStringTable -Page $Page).Keys | Where-Object { $_ -like 'HDTNextButton*' -or $_ -like 'HDTCancelButton*' -or $_ -like 'HDTBackButton*' -or $_ -like 'HDTOpenCmdButton*' -or $_ -like 'HDTSaveButton*' -or $_ -like 'HDTCloseButton*' }
        $orphan = @($orphan | Where-Object { $common -notcontains $_ })

        $orphan | Should -BeNullOrEmpty -Because ('these keys name no control in {0}: {1}' -f $Xaml, ($orphan -join ', '))
    }

    It 'leaves no prose literal in the markup' {
        # A STRING LEFT BEHIND CANNOT BE TRANSLATED OR EDITED, and hides among
        # the ones that can.
        $literal = @(& $script:proseLiteral $script:xamlPath)

        $literal | Should -BeNullOrEmpty -Because ('these are still hard-coded in {0}: {1}' -f $Xaml, ($literal -join ' | '))
    }

    It 'names every key Control.Property' {
        foreach ($key in @($script:table.Keys)) {
            ([string] $key) | Should -Match '^[A-Za-z0-9_]+\.[A-Za-z]+$' -Because 'the walker splits on the last dot'
        }
    }

    It 'fills something on this window' {
        # A block that filled nothing would pass every assertion above by being
        # empty.
        @($script:table.Keys | Where-Object {
                $name = [string] $_
                $split = $name.LastIndexOf('.')
                if ($split -gt 0) { $name = $name.Substring(0, $split) }
                $script:control -contains $name
            }).Count | Should -BeGreaterThan 10
    }
}

Describe 'the shipped string table' {

    It 'carries a Common block' {
        $data = Import-PowerShellDataFile -LiteralPath (
            Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings/en-us.psd1')

        @($data.Keys) | Should -Contain 'Common'
    }

    It 'ships en-us and nothing else, until somebody translates one' {
        # THE FLOOR, AND THE ONLY LANGUAGE THIS REPOSITORY CARRIES. A second
        # file appears when a site translates one, not because a test wrote it.
        @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings') -Filter '*.psd1' |
                ForEach-Object { $_.Name }) | Should -Be @('en-us.psd1')
    }

    It 'gives every block a hashtable' {
        $data = Import-PowerShellDataFile -LiteralPath (
            Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings/en-us.psd1')

        foreach ($block in @($data.Keys)) {
            $data[$block] -is [System.Collections.IDictionary] |
                Should -BeTrue -Because ("'{0}' is a block, and a block is a table of strings" -f $block)
        }
    }
}
