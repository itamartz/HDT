# The lint, on the row, before anybody boots anything.
#
# DESIGN 12: "Validation: the same JSON Schemas the cmdlets use, surfaced
# inline." Test-HDTTaskSequence is the other half and says so in its own header -
# "the console (M8) surfaces them inline while somebody is still editing" - so
# this is that promise kept.
#
# THE SCHEMA HALF IS ALREADY THERE AND ALREADY SHOWN: a sequence.yaml that fails
# Assert-HDTSequenceDocument comes back from Get-HDTConsoleWorkspace with Status
# 'Error' and the engine's message, and the tree draws it with a warning
# triangle. What was missing is the LINT - the problems a schema cannot see,
# which are the ones that ruin a deployment rather than stopping an import.
#
# A WARNING IS NOT AN ERROR AND MUST NOT LOOK LIKE ONE. A sequence with a
# %Var% nobody can supply still imports, still runs, and may well be correct -
# the variable might come from a rules file this console was not opened on. Red
# is reserved for a document that cannot be read at all; a lint finding is amber.
#
# THE COUNT IS ON THE ROW, THE FINDINGS ARE IN THE PANE. A tree of thirty
# sequences is scanned, not read: the row has to say "this one" without being
# opened, and the detail pane is where somebody who has decided to look finds
# out what and where.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:now = [datetime]::new(2026, 8, 15, 22, 0, 0, [System.DateTimeKind]::Utc)

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
'@

    # CLEAN: nothing for the lint to say.
    $script:cleanYaml = @'
schemaVersion: 1
id: CLEAN
name: A sequence with nothing wrong with it
steps:
  - name: Apply OS
    type: ApplyImage
'@

    # A %Var% no source could supply, and a continueOnError on a Restart - two
    # of the three warnings Test-HDTTaskSequence knows about.
    $script:warnYaml = @'
schemaVersion: 1
id: WARN
name: A sequence with two lint warnings
steps:
  - name: Apply OS
    type: ApplyImage
    condition: '%NobodySuppliesThis% -eq "yes"'

  - name: Restart
    type: Restart
    continueOnError: true
'@

    function New-HDTValidationShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        $file = @{
            'C:\ws\workspace.yaml'                    = $script:workspaceYaml
            'C:\ws\TaskSequences\CLEAN\sequence.yaml' = $script:cleanYaml
            'C:\ws\TaskSequences\WARN\sequence.yaml'  = $script:warnYaml
        }

        return Get-HDTConsoleWorkspace -Path 'C:\ws' `
            -FileSystem (New-HDTFakeFileSystem -File $file -Directory @('C:\ws\Logs\_active')) `
            -Clock (New-HDTFakeClock -UtcNow $script:now)
    }
}

Describe 'a task sequence and its lint' {

    BeforeAll { $script:share = New-HDTValidationShare }

    It 'carries the findings on the sequence, so nothing downstream re-runs the lint' {
        $warn = @($script:share.TaskSequence | Where-Object { $_.Id -eq 'WARN' })[0]

        @($warn.Finding).Count | Should -BeGreaterThan 0
    }

    It 'finds nothing to say about a clean one' {
        $clean = @($script:share.TaskSequence | Where-Object { $_.Id -eq 'CLEAN' })[0]

        @($clean.Finding).Count | Should -Be 0
        $clean.WarningCount | Should -Be 0
        $clean.ErrorCount | Should -Be 0
    }

    It 'counts what it found, by severity' {
        $warn = @($script:share.TaskSequence | Where-Object { $_.Id -eq 'WARN' })[0]

        $warn.WarningCount | Should -BeGreaterThan 0
        $warn.ErrorCount | Should -Be 0
    }

    It 'keeps what the lint said, rather than a count somebody has to go and re-derive' {
        $warn = @($script:share.TaskSequence | Where-Object { $_.Id -eq 'WARN' })[0]

        @($warn.Finding | ForEach-Object { $_.Severity }) | Should -Contain 'Warning'
        @($warn.Finding | ForEach-Object { $_.Message }) -join ' ' | Should -BeLike '*NobodySuppliesThis*'
    }
}

Describe 'the row a linted sequence gets' {

    BeforeAll {
        $script:node = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @(New-HDTValidationShare)))
        $script:warnRow = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' -and $_.Name -like 'WARN*' })[0]
        $script:cleanRow = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' -and $_.Name -like 'CLEAN*' })[0]
    }

    It 'says on the row that there is something to look at' {
        # A tree of thirty sequences is scanned, not read.
        $script:warnRow.Text | Should -BeLike '*warning*'
    }

    It 'leaves a clean row alone, so the mark means something' {
        $script:cleanRow.Text | Should -Not -BeLike '*warning*'
        $script:cleanRow.Status | Should -BeExactly 'Ok'
    }

    It 'marks it Warning rather than Error, because it still imports and may still be right' {
        # Red is for a document that cannot be READ. A %Var% this console cannot
        # see might be supplied by a rules file it was not opened on.
        $script:warnRow.Status | Should -BeExactly 'Warning'
    }

    It 'draws a warning in amber, not the red an unreadable document gets' {
        $script:warnRow.IconColor | Should -BeExactly '#FFB77400'
    }

    It 'puts every finding in the detail pane, with its step and its severity' {
        $label = @($script:warnRow.Field | ForEach-Object { $_.Label })

        $label | Should -Contain 'Validation'

        $text = @($script:warnRow.Field | Where-Object { $_.Label -eq 'Validation' })[0].Value
        $text | Should -BeLike '*Warning*'
        $text | Should -BeLike '*NobodySuppliesThis*'
    }

    It 'says so plainly when there is nothing to report' {
        $text = @($script:cleanRow.Field | Where-Object { $_.Label -eq 'Validation' })[0].Value

        $text | Should -BeLike '*no problems*'
    }

    It 'shows the cmdlet that produced the findings, like every other row here' {
        $text = @($script:warnRow.Field | Where-Object { $_.Label -eq 'Validation' })[0].Value

        # The pane is where somebody learns the command exists.
        $script:warnRow.Command | Should -Not -BeNullOrEmpty
        $text | Should -Not -BeNullOrEmpty
    }
}

Describe 'a sequence that will not import at all' {

    It 'stays red, because unreadable is not a lint finding' {
        $broken = @'
schemaVersion: 1
id: BROKEN
steps:
  - name: Apply OS
    type: [this is not a type]
'@

        $share = Get-HDTConsoleWorkspace -Path 'C:\ws' `
            -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml'                     = $script:workspaceYaml
                    'C:\ws\TaskSequences\BROKEN\sequence.yaml' = $broken
                } -Directory @('C:\ws\Logs\_active')) `
            -Clock (New-HDTFakeClock -UtcNow $script:now)

        $row = @(Get-HDTConsoleTreeNode -Workspace ([object[]] @($share)) |
                Where-Object { $_.Kind -eq 'TaskSequence' })[0]

        $row.Status | Should -BeExactly 'Error'
        $row.IconColor | Should -BeExactly '#FFC42B1C'
    }
}
