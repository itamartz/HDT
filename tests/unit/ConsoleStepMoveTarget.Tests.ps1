# A STEP GOES WHERE THE TECHNICIAN PUTS IT, GROUPS INCLUDED.
#
# Move-HDTStep could only swap a block with a SIBLING - another block at the same
# indent under the same parent. The last step of a group had a dark Down button
# and the first had a dark Up, and Get-HDTConsoleEditorState's header defended
# it: "before the group" and "the last step of the group above" are both
# plausible, so the console must not guess.
#
# THE AMBIGUITY IS REAL AND REFUSING TO MOVE IS THE WRONG ANSWER TO IT. MDT lets
# an administrator put a step anywhere, and somebody looking at the tree knows
# which of those two they meant. The toolkit chose "do nothing" over "let them
# say".
#
# SO THEY SAY. -Target names the block to land beside and -Position says which
# side, so every destination in the document is expressible - including into a
# group, out of one, and across two group boundaries at once. Nothing is
# guessed, and nothing is refused for being near an edge.
#
# THE INDENTATION IS THE HARD PART. A block that changes depth has to be
# re-indented, and this repository splices YAML rather than re-serialising it -
# so the comments above a step, the blank lines between steps and the nested
# children of a group all have to come through the move byte-for-byte apart from
# their leading spaces.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:text = @'
schemaVersion: 1
id: DEMO-05
name: Windows 11 bare metal

steps:
  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        index: 1

      # Prepare Boot writes the boot files, and it must run after the apply.
      - name: Prepare Boot
        type: ConfigureBoot

  - group: State Restore
    runIn: FullOS
    steps:
      - name: Install Applications
        type: InstallApplications

      - name: Tattoo
        type: Tattoo
'@

    $script:line = $script:text -split "`r?`n"

    $script:namesOf = {
        param([string[]] $Line)

        return [string[]] @($Line |
                Where-Object { $_ -match '^\s*- (name|group):\s*(.+)$' } |
                ForEach-Object { $Matches[2].Trim() })
    }

    $script:indentOf = {
        param([string[]] $Line, [string] $Name)

        $found = @($Line | Where-Object { $_ -match ('^\s*- (name|group):\s*{0}\s*$' -f [regex]::Escape($Name)) })[0]
        if ($null -eq $found) { return -1 }

        return ($found.Length - $found.TrimStart(' ').Length)
    }
}

Describe 'Move-HDTStep -Target' {

    Context 'the parameter is there' {

        It 'takes -Target, -TargetOccurrence and -Position' {
            $parameter = (Get-Command -Name 'Move-HDTStep').Parameters.Keys

            $parameter | Should -Contain 'Target'
            $parameter | Should -Contain 'TargetOccurrence'
            $parameter | Should -Contain 'Position'
        }

        It 'still takes -Direction, so nothing that used it breaks' {
            (Get-Command -Name 'Move-HDTStep').Parameters.Keys | Should -Contain 'Direction'
        }
    }

    Context 'within one group, which -Direction could already do' {

        It 'moves a step after another' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Apply OS' `
                    -Target 'Prepare Boot' -Position After)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Prepare Boot|Apply OS|State Restore|Install Applications|Tattoo'
        }

        It 'moves a step before another' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Apply OS' -Position Before)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Prepare Boot|Apply OS|State Restore|Install Applications|Tattoo'
        }
    }

    Context 'across a group boundary, which is the whole point' {

        It 'moves the last step of a group into the next one' {
            # Prepare Boot is last in Install. Down was dark here.
            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install Applications' -Position Before)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Apply OS|State Restore|Prepare Boot|Install Applications|Tattoo'
        }

        It 'indents it to its new group' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install Applications' -Position Before)

            (& $script:indentOf $after 'Prepare Boot') |
                Should -Be (& $script:indentOf $after 'Install Applications')
        }

        It 'moves a step out to the top level, beside the groups' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Tattoo' `
                    -Target 'State Restore' -Position After)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Apply OS|Prepare Boot|State Restore|Install Applications|Tattoo'

            (& $script:indentOf $after 'Tattoo') |
                Should -Be (& $script:indentOf $after 'State Restore')
        }

        It 'moves a whole group, and its children come with it' {
            $after = @(Move-HDTStep -Line $script:line -Name 'State Restore' `
                    -Target 'Install' -Position Before)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'State Restore|Install Applications|Tattoo|Install|Apply OS|Prepare Boot'
        }
    }

    Context 'what it keeps' {

        It 'brings the comment above a step with it' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install Applications' -Position Before)

            @($after | Where-Object { $_ -match 'writes the boot files' }).Count | Should -Be 1

            # And it is still directly above its step.
            $comment = [array]::FindIndex([string[]] $after,
                [Predicate[string]] { param($l) $l -match 'writes the boot files' })
            $step = [array]::FindIndex([string[]] $after,
                [Predicate[string]] { param($l) $l -match '- name: Prepare Boot' })

            $step | Should -Be ($comment + 1)
        }

        It 'keeps every step of the document, and no more' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Tattoo' `
                    -Target 'Apply OS' -Position Before)

            @(& $script:namesOf $after).Count | Should -Be 6
        }

        It 'leaves a document the engine still reads, with the step in its new group' {
            # THE BENCHMARK IS THE DEPLOYMENT'S OWN READER, not a diff that looks
            # right: a move that re-indents a block into a group has to produce
            # YAML that Import-HDTSequenceDocument agrees is that group's child.
            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install Applications' -Position After)

            $path = 'C:\ws\TaskSequences\DEMO-05\sequence.yaml'
            $fs = New-HDTFakeFileSystem -File @{ $path = ($after -join "`r`n") }

            $document = Import-HDTSequenceDocument -Path $path -FileSystem $fs

            @($document.Step).Count | Should -Be 4

            $moved = @($document.Step | Where-Object { $_.Name -eq 'Prepare Boot' })[0]
            @($moved.GroupPath) -join '/' | Should -BeExactly 'State Restore'
        }
    }

    Context 'a group with nothing left in it' {

        # THE COMPLAINT THIS CAME FROM. A technician moved both steps out of a
        # group and then could not put either back: Before and After name a
        # block to land beside, and an empty group has none - so the row simply
        # hopped over the group in both directions. Into is the way in.

        BeforeAll {
            $script:emptied = @'
schemaVersion: 1
id: DEMO-05
name: Windows 11

steps:
  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        index: 1

  - group: State Restore
    runIn: FullOS
    steps:

  - name: Tattoo
    type: Tattoo
'@ -split "`r?`n"
        }

        It 'puts a step into a group that has no children' {
            $after = @(Move-HDTStep -Line $script:emptied -Name 'Tattoo' `
                    -Target 'State Restore' -Position Into)

            $path = 'C:\ws\TaskSequences\DEMO-05\sequence.yaml'
            $fs = New-HDTFakeFileSystem -File @{ $path = ($after -join "`r`n") }
            $document = Import-HDTSequenceDocument -Path $path -FileSystem $fs

            $moved = @($document.Step | Where-Object { $_.Name -eq 'Tattoo' })[0]
            @($moved.GroupPath) -join '/' | Should -BeExactly 'State Restore'
        }

        It 'indents it the way the document indents its other children' {
            # NOT A CONSTANT. A share written at a different nesting width would
            # otherwise put every step at the wrong column - and the file would
            # still parse, so nothing would notice until a diff looked wrong.
            $after = @(Move-HDTStep -Line $script:emptied -Name 'Tattoo' `
                    -Target 'State Restore' -Position Into)

            $tattoo = @($after | Where-Object { $_ -match '- name: Tattoo' })[0]
            $applyOs = @($after | Where-Object { $_ -match '- name: Apply OS' })[0]

            ($tattoo.Length - $tattoo.TrimStart(' ').Length) |
                Should -Be ($applyOs.Length - $applyOs.TrimStart(' ').Length)
        }

        It 'refuses Into on a step, because a step has no inside' {
            { Move-HDTStep -Line $script:emptied -Name 'Tattoo' `
                    -Target 'Apply OS' -Position Into } |
                Should -Throw -ExpectedMessage '*not a group*'
        }
    }

    Context 'what it refuses' {

        It 'refuses to move a group inside itself' {
            { Move-HDTStep -Line $script:line -Name 'Install' `
                    -Target 'Apply OS' -Position After } |
                Should -Throw -ExpectedMessage '*itself*'
        }

        It 'refuses a target that is not there' {
            { Move-HDTStep -Line $script:line -Name 'Tattoo' `
                    -Target 'Nowhere' -Position After } |
                Should -Throw -ExpectedMessage '*no step or group*'
        }

        It 'refuses to move a block onto itself' {
            { Move-HDTStep -Line $script:line -Name 'Tattoo' `
                    -Target 'Tattoo' -Position After } |
                Should -Throw -ExpectedMessage '*itself*'
        }
    }

    Context 'duplicates are addressed the same way everything else is' {

        BeforeAll {
            $script:twice = @'
schemaVersion: 1
id: DEMO-05
name: Windows 11

steps:
  - group: Install
    runIn: WinPE
    steps:
      - name: Tattoo
        type: Tattoo

  - group: State Restore
    runIn: FullOS
    steps:
      - name: Install Applications
        type: InstallApplications

      - name: Tattoo
        type: Tattoo
'@ -split "`r?`n"
        }

        It 'moves the second Tattoo and leaves the first' {
            $after = @(Move-HDTStep -Line $script:twice -Name 'Tattoo' -Occurrence 2 `
                    -Target 'Install Applications' -Position Before)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Tattoo|State Restore|Tattoo|Install Applications'
        }

        It 'lands beside the target occurrence that was asked for' {
            $after = @(Move-HDTStep -Line $script:twice -Name 'Install Applications' `
                    -Target 'Tattoo' -TargetOccurrence 1 -Position Before)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Install|Install Applications|Tattoo|State Restore|Tattoo'
        }
    }
}
