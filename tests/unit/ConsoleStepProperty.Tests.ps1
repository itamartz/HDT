# Editing what a step DOES, which is the Properties tab.
#
# THE OTHER TAB WRITES ALREADY. Options - disabled, continueOnError, condition -
# went in first because those are the three an administrator changes while
# working out why a deployment did something surprising. Properties is the other
# half: the index ApplyImage installs, the minRamMB Validate insists on, the name
# on the row. Until now the boxes were the right shape and threw typing away.
#
# A PROPERTY IS SPLICED LIKE EVERY OTHER EDIT. Same reason as always: the lab's
# DEMO-M4 is half commentary and a round trip through ConvertFrom-HDTYaml would
# return it with every comment gone (DESIGN 12: a UI that reformats the file
# breaks git review).
#
# TYPE IS NOT EDITABLE, DELIBERATELY. A step's properties belong to its type -
# 'index' means something to ApplyImage and nothing to Restart - so retyping
# ApplyImage as Restart leaves a step carrying keys the new type has never heard
# of. Workbench does not offer it either; the answer there and here is to delete
# the step and add the one you meant.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:text = @'
schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal

steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      # minRamMB is 2048 rather than 4096 ON PURPOSE.
      - name: Validate
        type: Validate
        minRamMB: 2048

  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        index: 1
'@

    $script:line = $script:text -split "`r?`n"
    $script:path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
}

Describe 'Set-HDTConsoleStepProperty' {

    Context 'a property the step already carries' {

        It 'rewrites it in place, keeping the comment above the step' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Validate' -Property 'minRamMB' -Value '4096')

            $result | Should -Contain '        minRamMB: 4096'
            $result | Should -Contain '      # minRamMB is 2048 rather than 4096 ON PURPOSE.'
            $result.Count | Should -Be $script:line.Count
        }

        It 'leaves every other byte as it was' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Validate' -Property 'minRamMB' -Value '4096')

            $expected = @($script:line | ForEach-Object { $_ -replace 'minRamMB: 2048$', 'minRamMB: 4096' })
            ($result -join "`n") | Should -BeExactly ($expected -join "`n")
        }
    }

    Context 'a property it does not carry yet' {

        It 'inserts it under type, where the engine''s own documents put it' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'edition' -Value 'Enterprise')

            $at = [array]::IndexOf($result, '        type: ApplyImage')
            $result[$at + 1] | Should -BeExactly '        edition: Enterprise'
        }
    }

    Context 'clearing one' {

        It 'takes the line out rather than leaving a key with nothing after it' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'index' -Value '')

            @($result | Where-Object { $_ -match '^\s*index:' }).Count | Should -Be 0
            $result.Count | Should -Be ($script:line.Count - 1)
        }
    }

    Context 'the name on the row' {

        It 'renames the step on its own entry line, dash and all' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'name' -Value 'Apply Windows 11')

            $result | Should -Contain '      - name: Apply Windows 11'
            @($result | Where-Object { $_ -match '^\s*- name: Apply OS$' }).Count | Should -Be 0
            $result.Count | Should -Be $script:line.Count
        }

        It 'renames a group the same way' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Install' -Property 'group' -Value 'Install the OS')

            $result | Should -Contain '  - group: Install the OS'

            # Its steps are untouched, and still inside it.
            $result | Should -Contain '      - name: Apply OS'
        }

        It 'refuses to empty a name, because a step with none cannot be found again' {
            { Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'name' -Value '' } |
                Should -Throw '*cannot be cleared*'
        }
    }

    Context 'the type, which is not editable' {

        It 'refuses, and says what to do instead' {
            { Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'type' -Value 'Restart' } |
                Should -Throw '*type*'
        }
    }

    Context 'the result the engine reads' {

        It 'round-trips through Import-HDTSequenceDocument' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'index' -Value '2')

            $fs = New-HDTFakeFileSystem -File @{ $script:path = ($result -join "`r`n") }
            $document = Import-HDTSequenceDocument -Path $script:path -FileSystem $fs

            $step = @($document.Step | Where-Object { $_.Name -eq 'Apply OS' })[0]
            [string] $step.Property['index'] | Should -BeExactly '2'
        }
    }

    Context 'refusals' {

        It 'refuses a step that is not there' {
            { Set-HDTConsoleStepProperty -Line $script:line -Name 'Nowhere' -Property 'index' -Value '2' } |
                Should -Throw '*no step or group*'
        }

        It 'supports -WhatIf and changes nothing under it' {
            $result = @(Set-HDTConsoleStepProperty -Line $script:line -Name 'Apply OS' -Property 'index' -Value '9' -WhatIf)

            ($result -join "`n") | Should -BeExactly ($script:line -join "`n")
        }
    }
}

Describe 'the Properties rows, which now say what may be typed into them' {

    BeforeAll {
        $script:state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'
        $script:field = @($script:state.Selected.Field)
        $script:byLabel = @{}
        foreach ($row in $script:field) { $script:byLabel[$row.Label] = $row }
    }

    It 'marks the per-type properties editable, and names the key each one writes' {
        $script:byLabel['index'].Editable | Should -BeTrue
        $script:byLabel['index'].Property | Should -BeExactly 'index'
    }

    It 'marks the name editable' {
        $script:byLabel['Name'].Editable | Should -BeTrue
        $script:byLabel['Name'].Property | Should -BeExactly 'name'
    }

    It 'leaves the type read-only' {
        $script:byLabel['Type'].Editable | Should -BeFalse
    }

    It 'leaves the derived rows read-only, because there is nothing in the file to write' {
        # 'Runs' is 'step 3 of 5' - a position, not a key.
        $script:byLabel['Runs'].Editable | Should -BeFalse
    }

    It 'remembers what each row said when it was built' {
        # Original is what the diff is taken against when Apply is pressed. A row
        # that compared against itself would never look changed.
        $script:byLabel['index'].Original | Should -BeExactly $script:byLabel['index'].Value
    }

    It 'marks a group''s name editable too, under its own key' {
        $group = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Install'
        $row = @($group.Selected.Field | Where-Object { $_.Label -eq 'Group' })[0]

        $row.Editable | Should -BeTrue
        $row.Property | Should -BeExactly 'group'
    }

    It 'puts a nested group''s own leg in the box, and its path beside it read-only' {
        # `group:` holds one leg. A box showing 'Install \ Drivers' would write
        # that whole string as the name the moment anybody touched it.
        $nested = @'
schemaVersion: 1
id: NEST
name: Nested
steps:
  - group: Install
    steps:
      - group: Drivers
        steps:
          - name: Apply OS
            type: ApplyImage
'@ -split "`r?`n"

        $state = Get-HDTConsoleEditorState -Line $nested -Path $script:path -SelectedName 'Drivers'

        $own = @($state.Selected.Field | Where-Object { $_.Label -eq 'Group' })[0]
        $own.Value | Should -BeExactly 'Drivers'
        $own.Editable | Should -BeTrue

        $path = @($state.Selected.Field | Where-Object { $_.Label -eq 'Path' })[0]
        $path.Value | Should -BeExactly 'Install \ Drivers'
        $path.Editable | Should -BeFalse
    }
}

Describe 'Get-HDTConsoleStepChange' {

    # A FRESH SET PER TEST. These rows are what the window binds to, so a test
    # that types into one is mutating the same objects the next test would read
    # - which is how 'ignores a read-only row' first failed on a value the test
    # before it had typed.
    BeforeEach {
        $script:state = Get-HDTConsoleEditorState -Line $script:line -Path $script:path -SelectedName 'Apply OS'
    }

    It 'finds nothing when nothing was typed' {
        @(Get-HDTConsoleStepChange -Field $script:state.Selected.Field -Name 'Apply OS') | Should -BeNullOrEmpty
    }

    It 'finds the row that was edited, and only that one' {
        $field = @($script:state.Selected.Field)
        @($field | Where-Object { $_.Label -eq 'index' })[0].Value = '2'

        $change = @(Get-HDTConsoleStepChange -Field $field -Name 'Apply OS')

        @($change).Count | Should -Be 1
        $change[0].Property | Should -BeExactly 'index'
        $change[0].Value | Should -BeExactly '2'
    }

    It 'shows the cmdlet each change would run' {
        $field = @($script:state.Selected.Field)
        @($field | Where-Object { $_.Label -eq 'index' })[0].Value = '3'

        $change = @(Get-HDTConsoleStepChange -Field $field -Name 'Apply OS')

        $change[0].Command | Should -BeLike '*Set-HDTConsoleStepProperty*'
        $change[0].Command | Should -BeLike "*-Name 'Apply OS'*"
        $change[0].Command | Should -BeLike "*-Property index*"
    }

    It 'ignores a read-only row even if something changed its value' {
        $field = @($script:state.Selected.Field)
        @($field | Where-Object { $_.Label -eq 'Type' })[0].Value = 'Restart'

        @(Get-HDTConsoleStepChange -Field $field -Name 'Apply OS') | Should -BeNullOrEmpty
    }

    It 'puts a rename last, so the other edits still find the step by its old name' {
        # Every editing cmdlet takes the NAME. Renaming first would leave the
        # remaining changes looking for a step that no longer answers to it.
        $field = @($script:state.Selected.Field)
        @($field | Where-Object { $_.Label -eq 'index' })[0].Value = '4'
        @($field | Where-Object { $_.Label -eq 'Name' })[0].Value = 'Apply Windows 11'

        $change = @(Get-HDTConsoleStepChange -Field $field -Name 'Apply OS')

        @($change).Count | Should -Be 2
        $change[0].Property | Should -BeExactly 'index'
        $change[1].Property | Should -BeExactly 'name'
    }

    It 'says what the step answers to after each change, so the caller need not know which keys are names' {
        $field = @($script:state.Selected.Field)
        @($field | Where-Object { $_.Label -eq 'index' })[0].Value = '4'
        @($field | Where-Object { $_.Label -eq 'Name' })[0].Value = 'Apply Windows 11'

        $change = @(Get-HDTConsoleStepChange -Field $field -Name 'Apply OS')

        $change[0].Renames | Should -BeFalse
        $change[0].NameAfter | Should -BeExactly 'Apply OS'

        $change[1].Renames | Should -BeTrue
        $change[1].NameAfter | Should -BeExactly 'Apply Windows 11'
    }
}
