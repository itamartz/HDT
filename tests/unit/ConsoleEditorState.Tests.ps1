# Everything the editor window shows about a document it is part-way through
# editing.
#
# THIS EXISTS SO THE WINDOW CAN STAY BRANCH-FREE. Wiring the toolbar means
# deciding things - which buttons are live for the selected row, what the tree
# looks like after a splice, whether the edited text still parses - and
# CLAUDE.md rule 1 puts decisions in commands, not in the adapter. With this in
# place every handler in New-HDTConsoleHost is one call and one assignment.
#
# UP IS NOT ALWAYS AVAILABLE, AND THAT IS THE POINT. Move-HDTConsoleStep refuses
# to move the first step in a group past the group's own boundary, because
# "before the group" and "the last step of the group above" are both plausible.
# A toolbar that offered Up there would produce an error box on a press that
# looked ordinary; the button is dark instead.
#
# THE EDITED TEXT IS RE-READ THROUGH THE ENGINE, not tracked as a model. A
# splice that produced something Import-HDTSequenceDocument cannot read is
# reported here, with the file on the share still intact - which is the same
# check Save-HDTConsoleSequence makes, one press earlier.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'

    $script:text = @'
schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal

steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      - name: Validate
        type: Validate
        minRamMB: 2048

      - name: Format and Partition
        type: DiskPartition
        disabled: true

  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        condition: $Model -like 'Virtual*'
'@

    $script:line = $script:text -split "`r?`n"
}

Describe 'Get-HDTConsoleEditorState' {

    Context 'the tree it rebuilds' {

        BeforeAll { $script:state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path }

        It 'reads the edited lines rather than the file on disk' {
            $edited = @($script:line | ForEach-Object { $_ -replace 'Apply OS', 'Apply Windows' })

            $result = Get-HDTConsoleEditorState -Line $edited -Path $script:path

            @($result.Node | ForEach-Object { $_.Text }) | Should -Contain '3. Apply Windows'
        }

        It 'hands back the groups as roots, with their steps beneath them' {
            @($script:state.Root | ForEach-Object { $_.Text }) | Should -Be @('Preinstall', 'Install')
            @($script:state.Root[0].Children | ForEach-Object { $_.Text })[0] | Should -BeExactly '1. Validate'
        }

        It 'still marks a disabled step as disabled' {
            $row = @($script:state.Node | Where-Object { $_.Text -like '*Format and Partition*' })[0]

            $row.Text | Should -BeLike '*(disabled)*'
        }

        It 'reports the document as readable' {
            $script:state.Status | Should -BeExactly 'Ok'
        }
    }

    Context 'a document the splice broke' {

        It 'says so, and does not throw at the window' {
            $broken = @('steps:', '  - name: Validate', '   type: Validate', 'id: [unclosed')

            $result = Get-HDTConsoleEditorState -Line $broken -Path $script:path

            $result.Status | Should -BeExactly 'Error'
            $result.Message | Should -Not -BeNullOrEmpty
            @($result.Root).Count | Should -Be 0
        }

        It 'offers no action on a document it could not read' {
            $broken = @('steps:', '  - name: Validate', '   type: Validate', 'id: [unclosed')

            $result = Get-HDTConsoleEditorState -Line $broken -Path $script:path

            $result.CanRemove | Should -BeFalse
            $result.CanSave | Should -BeFalse
        }
    }

    Context 'what the selected row makes possible' {

        It 'offers nothing when nothing is selected' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path

            $result.Selected | Should -BeNullOrEmpty
            $result.CanRemove | Should -BeFalse
            $result.CanCopy | Should -BeFalse
            $result.CanMoveUp | Should -BeFalse
            $result.CanMoveDown | Should -BeFalse
        }

        It 'offers Remove and Copy on any row' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'

            $result.CanRemove | Should -BeTrue
            $result.CanCopy | Should -BeTrue
        }

        It 'refuses Up on the first step in a group, because Move refuses it too' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Validate'

            $result.CanMoveUp | Should -BeFalse
            $result.CanMoveDown | Should -BeTrue
        }

        It 'refuses Down on the last step in a group' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Format and Partition'

            $result.CanMoveUp | Should -BeTrue
            $result.CanMoveDown | Should -BeFalse
        }

        It 'counts a group against its fellow groups, not against the steps inside it' {
            $first = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Preinstall'
            $last = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Install'

            $first.CanMoveUp | Should -BeFalse
            $first.CanMoveDown | Should -BeTrue
            $last.CanMoveUp | Should -BeTrue
            $last.CanMoveDown | Should -BeFalse
        }

        It 'refuses Down on the only step in a group' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'

            $result.CanMoveUp | Should -BeFalse
            $result.CanMoveDown | Should -BeFalse
        }
    }

    Context 'the Options tab for the selected row' {

        It 'is built for the selected step, with its flags as the file has them' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Format and Partition'

            $result.Option.Name | Should -BeExactly 'Format and Partition'
            $result.Option.Flag[0].Checked | Should -BeTrue
        }

        It 'carries the condition the step actually has' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'

            $result.Option.HasCondition | Should -BeTrue
            $result.Option.Condition | Should -BeExactly '$Model -like ''Virtual*'''
        }

        It 'is built for a group too' {
            $result = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Install'

            $result.Option.Kind | Should -BeExactly 'Group'
            @($result.Option.Flag).Count | Should -Be 1
        }

        It 'is empty when nothing is selected' {
            (Get-HDTConsoleEditorState -Line $script:line -Path $script:path).Option | Should -BeNullOrEmpty
        }
    }

    Context 'Paste and Save, which are about the window rather than the row' {

        It 'offers Paste only when something has been copied' {
            (Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS').CanPaste |
                Should -BeFalse

            (Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS' -HasClipboard).CanPaste |
                Should -BeTrue
        }

        It 'offers Save only once something has changed' {
            (Get-HDTConsoleEditorState -Line $script:line -Path $script:path).CanSave | Should -BeFalse
            (Get-HDTConsoleEditorState -Line $script:line -Path $script:path -Dirty).CanSave | Should -BeTrue
        }

        It 'says in the title bar that there are unsaved edits' {
            $clean = Get-HDTConsoleEditorState -Line $script:line -Path $script:path
            $dirty = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -Dirty

            $clean.Dirty | Should -BeFalse
            $dirty.Dirty | Should -BeTrue
            $dirty.StatusText | Should -BeLike '*unsaved*'
        }
    }
}
