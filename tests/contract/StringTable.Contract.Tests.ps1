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
#
# EVERY WINDOW IS UNDER THIS CONTRACT BY DEFAULT. A new .xaml is covered the
# moment it is added, without anybody remembering to list it: it must either
# name its block below or be named as an exemption, with a reason, in $notYet.
# That is what stops the table from being a thing that was done once.

# WHICH WINDOW IS WHICH BLOCK.
$script:page = @{
    'HDTBootImage.xaml'           = 'BootImage'
    'HDTBuildProgress.xaml'       = 'BuildProgress'
    'HDTConsole.xaml'             = 'Console'
    'HDTNewSequence.xaml'         = 'NewSequence'
    'HDTPartitionProperties.xaml' = 'PartitionProperties'
    'HDTSequenceEditor.xaml'      = 'SequenceEditor'
}

# WHAT IS NOT UNDER IT YET, AND WHY. This list only ever shrinks. Adding to it
# is a decision somebody makes on purpose and can be seen making.
$script:notYet = @{
    'HDTTheme.xaml'            = 'a resource dictionary - brushes and styles, no controls and no text'
    'HDTWelcome.xaml'          = 'WinPE: converting it means rebuilding the boot image to see it'
    'HDTWizard.xaml'           = 'WinPE'
    'HDTWizardShell.xaml'      = 'WinPE'
    'HDTWizardCredential.xaml' = 'WinPE'
    'HDTProgress.xaml'         = 'WinPE'
    'HDTFailure.xaml'          = 'WinPE'
}

# AT FILE SCOPE, NOT IN BeforeAll: -ForEach is read while Pester is DISCOVERING
# tests, and BeforeAll has not run by then - a table defined there discovers as
# an empty array and the whole file fails to load.
$script:uiRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/UI'

$script:window = @(Get-ChildItem -LiteralPath $script:uiRoot -Filter '*.xaml' -Recurse |
        ForEach-Object {
            @{
                File    = $_.Name
                Path    = $_.FullName
                # DECIDED HERE, WHERE THE TABLES ARE IN SCOPE. Pester runs an It
                # in a scope that discovery's variables do not reach, so what a
                # run-time assertion needs has to travel as -ForEach data.
                Covered = ($script:page.ContainsKey($_.Name) -or $script:notYet.ContainsKey($_.Name))
            }
        })

$script:converted = @($script:window |
        Where-Object { $script:page.ContainsKey($_.File) } |
        ForEach-Object { @{ Page = $script:page[$_.File]; File = $_.File; Path = $_.Path } })

$script:ledger = @{
    Stale = @($script:notYet.Keys | Where-Object { $_ -notin @($script:window.File) })
    Stray = @($script:page.Keys | Where-Object { $_ -notin @($script:window.File) })
    Block = @($script:page.Values)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:tablePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings/en-us.psd1'

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

Describe 'every window this module ships' -ForEach $script:ledger {

    It 'either names a block or says why not: <File>' -ForEach $script:window {

        # THE MANDATORY HALF. A window added tomorrow fails here until its text
        # is in the table - which is the only moment anybody is looking at its
        # strings anyway.
        $Covered | Should -BeTrue -Because ("{0} carries text nobody can translate. Convert it and name its block, or exempt it in `$notYet with a reason." -f $File)
    }

    It 'exempts nothing that is no longer there' {
        # A STALE EXEMPTION IS SILENCE NOBODY ASKED FOR: rename a window and its
        # exemption keeps covering a file that does not exist, while the renamed
        # one walks in uncovered.
        $Stale | Should -BeNullOrEmpty -Because ('these are exempt but not shipped: {0}' -f ($Stale -join ', '))
    }

    It 'names a block for nothing that is no longer there' {
        $Stray | Should -BeNullOrEmpty -Because ('these name a block but are not shipped: {0}' -f ($Stray -join ', '))
    }
}

Describe 'the string table and the markup it fills: <Page>' -ForEach $script:converted {

    BeforeAll {
        $script:xamlPath = $Path
        $script:table = Get-HDTStringTable -Page $Page
        $script:control = & $script:namedControl $script:xamlPath

        # Common is filled on windows this block knows nothing about, so its
        # keys are allowed to name no control HERE.
        $script:common = @((Import-PowerShellDataFile -LiteralPath $script:tablePath).Common.Keys)
    }

    It 'has a window to fill' {
        $script:xamlPath | Should -Exist
    }

    It 'names a control that exists for every key' {
        # A KEY NAMING NO CONTROL IS DEAD TEXT, and usually half of a rename.
        $orphan = @()
        foreach ($key in @($script:table.Keys)) {

            if ($script:common -contains [string] $key) { continue }

            $name = [string] $key
            $split = $name.LastIndexOf('.')
            if ($split -gt 0) { $name = $name.Substring(0, $split) }

            if ($script:control -notcontains $name) { $orphan += [string] $key }
        }

        $orphan | Should -BeNullOrEmpty -Because ('these keys name no control in {0}: {1}' -f $File, ($orphan -join ', '))
    }

    It 'leaves no prose literal in the markup' {
        # A STRING LEFT BEHIND CANNOT BE TRANSLATED OR EDITED, and hides among
        # the ones that can.
        $literal = @(& $script:proseLiteral $script:xamlPath)

        $literal | Should -BeNullOrEmpty -Because ('these are still hard-coded in {0}: {1}' -f $File, ($literal -join ' | '))
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
            }).Count | Should -BeGreaterThan 0
    }
}

Describe 'the shipped string table' -ForEach $script:ledger {

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

    It 'names a window for every block it carries' {
        # THE OTHER DIRECTION: a block for a window that was renamed or removed
        # is text nobody will ever see again.
        $data = Import-PowerShellDataFile -LiteralPath (
            Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Strings/en-us.psd1')

        $orphan = @(@($data.Keys) |
                Where-Object { $_ -ne 'Common' -and $_ -notin $Block })

        $orphan | Should -BeNullOrEmpty -Because ('these blocks fill no window: {0}' -f ($orphan -join ', '))
    }
}
