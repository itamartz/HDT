# Everything the editor window shows about a document it is part-way through
# editing.
#
# THIS EXISTS SO THE WINDOW CAN STAY BRANCH-FREE. Wiring the toolbar means
# deciding things - which buttons are live for the selected row, what the tree
# looks like after a splice, whether the edited text still parses - and
# CLAUDE.md rule 1 puts decisions in commands, not in the adapter. With this in
# place every handler in New-HDTConsoleHost is one call and one assignment.
#
# UP IS NOT ALWAYS AVAILABLE, AND THAT IS THE POINT. Move-HDTStep refuses
# to move the first step in a group past the group's own boundary, because
# "before the group" and "the last step of the group above" are both plausible.
# A toolbar that offered Up there would produce an error box on a press that
# looked ordinary; the button is dark instead.
#
# THE EDITED TEXT IS RE-READ THROUGH THE ENGINE, not tracked as a model. A
# splice that produced something Import-HDTSequenceDocument cannot read is
# reported here, with the file on the share still intact - which is the same
# check Save-HDTSequenceDocument makes, one press earlier.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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

    Context 'a group with nothing in it' {

        BeforeAll {
            # THE SHAPE THE NEW GROUP BUTTON PRODUCES, with a step on either side
            # of it so the ORDER is asserted and not just the presence of a row.
            $script:emptyGroupLine = @'
schemaVersion: 1
id: EMPTY
name: An unfilled shelf

steps:
  - name: Validate
    type: Validate

  - group: New Group
    steps: []

  - name: Apply OS
    type: ApplyImage
'@ -split "`r?`n"

            $script:emptyGroupState = Get-HDTConsoleEditorState -Line $script:emptyGroupLine -Path $script:path
        }

        It 'reads the document' {
            $script:emptyGroupState.Status | Should -BeExactly 'Ok' -Because $script:emptyGroupState.Message
        }

        It 'draws the group even though no step names it' {
            # EVERY OTHER GROUP ROW IS CREATED BY THE FIRST STEP INSIDE IT. An
            # empty one has no such step, so a tree built by walking the steps
            # alone drew nothing at all - and the New Group button looked like it
            # had done nothing.
            $row = @($script:emptyGroupState.Node | Where-Object { $_.Kind -eq 'StepGroup' -and $_.Name -eq 'New Group' })

            @($row).Count | Should -Be 1
            @($row)[0].Children.Count | Should -Be 0
        }

        It 'puts it where the document puts it, between the two steps' {
            @($script:emptyGroupState.Root | ForEach-Object { $_.Text }) |
                Should -Be @('1. Validate', 'New Group', '2. Apply OS')
        }

        It 'leaves the numbering to the steps' {
            $script:emptyGroupState.StepCount | Should -Be 2
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

    Context 'putting the selection back after an edit' {

        # THE BUG THIS FIXES: ticking "Disable this step" rebuilt the tree from
        # the edited lines and left nothing selected, so the highlight fell back
        # to the nearest container - the step's GROUP - and the panes followed
        # it. An administrator switching a step off then found themselves
        # looking at the group's properties.
        #
        # A ROW CARRIES ITS OWN SELECTION, the way it already carries
        # IsExpanded, and the window binds to it. That is what makes this
        # assertable at all: a host that walked ItemContainerGenerator to find
        # the row again could only be checked by looking at a screen.

        It 'marks the selected row selected' {
            $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'

            $state.Selected.IsSelected | Should -BeTrue
        }

        It 'marks only that one' {
            $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'

            @($state.Node | Where-Object { $_.IsSelected }).Count | Should -Be 1
        }

        It 'still finds the row when the edit changed how it reads' {
            # A disabled step's Text gains '(disabled)'. Name is what the row is
            # matched on, and it does not move.
            $off = @(Set-HDTStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $true)

            $state = Get-HDTConsoleEditorState -Line $off -Path $script:path -SelectedName 'Apply OS'

            $state.Selected | Should -Not -BeNullOrEmpty
            $state.Selected.Text | Should -BeLike '*(disabled)*'
            $state.Selected.IsSelected | Should -BeTrue
        }

        It 'selects nothing when nothing was selected' {
            $state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path

            @($state.Node | Where-Object { $_.IsSelected }) | Should -BeNullOrEmpty
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

Describe 'a property that is not a value' {

    BeforeAll {
        $script:tableText = @'
schemaVersion: 1
id: DEMO-TABLE
name: a step with a table on it

steps:
  - group: Preinstall
    steps:
      - name: Format and Partition
        type: DiskPartition
        wipe: true
        partition:
          - name: System
            type: EFI
            size: 260MB
          - name: Windows
            type: Primary
            size: remainder
'@

        $script:tableLine = $script:tableText -split "`r?`n"

        $script:tableState = Get-HDTConsoleEditorState -Line $script:tableLine `
            -Path $script:path -SelectedName 'Format and Partition'

        $script:tableField = @($script:tableState.Selected.Field |
                Where-Object { $_.Label -eq 'partition' })
    }

    It 'is not on the Properties tab at all, because the Disk page owns it' {
        # MDT NEVER SHOWS A SETTING ON TWO TABS of the same dialog: its Format
        # and Partition Disk page IS that step's Properties tab. Listing the
        # table here as well meant a row saying
        # 'System.Collections.Specialized.OrderedDictionary' - and it was
        # EDITABLE, so Apply properties would have written those words over a
        # two-volume disk layout.
        @($script:tableField).Count | Should -Be 0
    }

    It 'does not list the other keys that page owns either' {
        $label = @($script:tableState.Selected.Field | ForEach-Object { $_.Label })

        # A disk number in two boxes is a disk number that can disagree with
        # itself while both look authoritative.
        $label | Should -Not -Contain 'disk'
        $label | Should -Not -Contain 'wipe'
        $label | Should -Not -Contain 'style'
    }

    It 'carries none of the facts the rest of the window already shows' {
        # THE TAB IS THE STEP'S OWN SETTINGS AND NOTHING ELSE. The name is the
        # box above the tabs; the type and the group are the row that was
        # clicked in the tree; Enabled, Runs in, Condition and Continue on error
        # are the Options tab. Ten rows of which two were the step's own is why
        # it read as a data dump rather than a properties page.
        $label = @($script:tableState.Selected.Field | ForEach-Object { $_.Label })

        $label | Should -Not -Contain 'Name'
        $label | Should -Not -Contain 'Type'
        $label | Should -Not -Contain 'Runs'
        $label | Should -Not -Contain 'Enabled'
        $label | Should -Not -Contain 'Condition'
    }

    It 'leaves a step type with no page of its own its properties' {
        # The tab is not being emptied - it is the only editor most step types
        # have, and this is the assertion that keeps the exclusion narrow.
        # Validate is no longer the example: it has a page of its own now, and
        # its keys moved onto it.
        $generic = [string[]] @(@($script:tableLine) + @(
                '      - name: Run something'
                '        type: CommandLine'
                '        command: wpeutil.exe reboot'))

        $other = Get-HDTConsoleEditorState -Line $generic -Path $script:path -SelectedName 'Run something'
        $field = @($other.Selected.Field | Where-Object { $_.Label -eq 'command' })

        @($field).Count | Should -Be 1
        $field[0].Editable | Should -BeTrue
    }
}
