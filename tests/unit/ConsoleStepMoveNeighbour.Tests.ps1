# WHAT UP AND DOWN MEAN ONCE A STEP CAN GO ANYWHERE.
#
# They used to mean "swap with a sibling", so a step at the edge of a group had a
# dark button and nowhere to go. They now mean what a technician looking at the
# tree thinks they mean: the row moves one place in the list they can SEE,
# crossing group boundaries when the list does.
#
# THE DECISION IS PURE AND LIVES HERE. The console's click handler passes the
# answer to Move-HDTStep and decides nothing, which is the same split the rest of
# the editor uses - a WPF handler is the one place in this repository nothing can
# be tested.
#
# DOWN ONTO A GROUP IS THE INTERESTING ONE. The next VISIBLE row below a step
# that sits above a group is the group's own header, and "after the group" would
# make one keypress jump the step over everything inside it. Down puts it in as
# the group's first child instead, which is where the eye expects it to land.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:text = @'
schemaVersion: 1
id: DEMO-05
name: Windows 11

steps:
  - name: Gather
    type: Gather

  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        index: 1

      - name: Prepare Boot
        type: ConfigureBoot

  - group: State Restore
    runIn: FullOS
    steps:
      - name: Install Applications
        type: InstallApplications
'@

    $script:line = $script:text -split "`r?`n"

    # The display order the tree shows, which is what Up and Down walk.
    #   Gather
    #   Install
    #     Apply OS
    #     Prepare Boot
    #   State Restore
    #     Install Applications

    $script:namesOf = {
        param([string[]] $Line)

        return [string[]] @($Line |
                Where-Object { $_ -match '^\s*- (name|group):\s*(.+)$' } |
                ForEach-Object { $Matches[2].Trim() })
    }

    $script:groupOf = {
        param([string[]] $Line, [string] $Name)

        $path = 'C:\ws\TaskSequences\DEMO-05\sequence.yaml'
        $fs = New-HDTFakeFileSystem -File @{ $path = ($Line -join "`r`n") }
        $document = Import-HDTSequenceDocument -Path $path -FileSystem $fs

        $step = @($document.Step | Where-Object { $_.Name -eq $Name })[0]
        if ($null -eq $step) { return '(not a step)' }

        return (@($step.GroupPath) -join '/')
    }
}

Describe 'Get-HDTStepNeighbourTarget' {

    Context 'the command exists' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTStepNeighbourTarget' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'walking the list a technician can see' {

        It 'moving Gather down lands it inside the group below' {
            # The next visible row is the Install group's header. Landing AFTER
            # the group would jump Gather over both its steps in one press.
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Gather' -Direction Down

            $answer.Target | Should -BeExactly 'Apply OS'
            $answer.Position | Should -BeExactly 'Before'
        }

        It 'moving Apply OS up lands it above its own group' {
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Apply OS' -Direction Up

            $answer.Target | Should -BeExactly 'Install'
            $answer.Position | Should -BeExactly 'Before'
        }

        It 'moving Prepare Boot down leaves its group for the next one' {
            # This is the move that used to be refused outright.
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Prepare Boot' -Direction Down

            $answer.Target | Should -BeExactly 'Install Applications'
            $answer.Position | Should -BeExactly 'Before'
        }

        It 'says nothing when the row is already first' {
            Get-HDTStepNeighbourTarget -Line $script:line -Name 'Gather' -Direction Up |
                Should -BeNullOrEmpty
        }

        It 'moves the last step of the last group OUT of it, rather than nowhere' {
            # THE CASE A TECHNICIAN ASKED FOR. Install Applications is the last
            # step of the last group, so there is no block below it - but there
            # IS somewhere below it: out of the group, at the top level, after
            # the group itself. A slot is a position AND a depth, and the end of
            # the document has two of them.
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Install Applications' -Direction Down

            $answer | Should -Not -BeNullOrEmpty
            $answer.Target | Should -BeExactly 'State Restore'
            $answer.Position | Should -BeExactly 'After'
        }

        It 'and then says nothing, because the top level really is the end' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Install Applications' `
                    -Target 'State Restore' -Position After)

            & $script:groupOf $after 'Install Applications' | Should -BeExactly ''

            Get-HDTStepNeighbourTarget -Line $after -Name 'Install Applications' -Direction Down |
                Should -BeNullOrEmpty
        }

        It 'entering a group from below joins it at the END, not the top' {
            # A step sitting below a group, moving up, should become that group's
            # LAST step - it is directly under the group's last child on screen,
            # and one press moves it one place.
            #
            # LANDING "BEFORE" THAT CHILD WOULD JUMP IT OVER THE WHOLE GROUP'S
            # CONTENTS. Watched in the console: step 11 moved up into the group
            # and came out as step 10, with the step that had been 10 renumbered
            # to 11 - it had overtaken it rather than fallen in behind it.
            # THE GROUP ABOVE MUST STILL HOLD SOMETHING. Emptying it would make
            # the row above a same-level group header, which is an ordinary swap
            # and not this case at all.
            $out = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install' -Position After)

            # Prepare Boot is now a top-level step below Install, and Install
            # still holds Apply OS.
            & $script:groupOf $out 'Prepare Boot' | Should -BeExactly ''

            $answer = Get-HDTStepNeighbourTarget -Line $out -Name 'Prepare Boot' -Direction Up

            $answer.Position | Should -BeExactly 'After' -Because 'it joins the group behind its last step'
            $answer.Target | Should -BeExactly 'Apply OS'
        }

        It 'and the row keeps its place on screen, only its depth changes' {
            # THE COMPLAINT THIS CAME FROM. A step moved up into the group came
            # back renumbered: it had become step 10 and the step that was 10
            # had become 11. Its position in the list must not move at all - it
            # is already directly below that step - only its indentation.
            $out = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target 'Install' -Position After)

            $before = @(& $script:namesOf $out)

            $answer = Get-HDTStepNeighbourTarget -Line $out -Name 'Prepare Boot' -Direction Up

            $back = @(Move-HDTStep -Line $out -Name 'Prepare Boot' `
                    -Target $answer.Target -TargetOccurrence $answer.TargetOccurrence -Position $answer.Position)

            & $script:groupOf $back 'Prepare Boot' | Should -BeExactly 'Install'

            @(& $script:namesOf $back) -join '|' | Should -BeExactly ($before -join '|') -Because (
                'joining the group behind its last step is the same place in the list')
        }

        It 'skips a group its own children, so a group does not move into itself' {
            # Install moving down must clear the whole of itself, not land on
            # Apply OS - which is inside it.
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Install' -Direction Down

            $answer.Target | Should -Not -BeExactly 'Apply OS'
            $answer.Target | Should -Not -BeExactly 'Prepare Boot'
        }
    }

    Context 'and the move it names actually works' {

        It 'moves Prepare Boot into State Restore' {
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Prepare Boot' -Direction Down

            $after = @(Move-HDTStep -Line $script:line -Name 'Prepare Boot' `
                    -Target $answer.Target -TargetOccurrence $answer.TargetOccurrence -Position $answer.Position)

            & $script:groupOf $after 'Prepare Boot' | Should -BeExactly 'State Restore'
        }

        It 'moves Gather into Install' {
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Gather' -Direction Down

            $after = @(Move-HDTStep -Line $script:line -Name 'Gather' `
                    -Target $answer.Target -TargetOccurrence $answer.TargetOccurrence -Position $answer.Position)

            & $script:groupOf $after 'Gather' | Should -BeExactly 'Install'
        }

        It 'moves Apply OS out of Install to the top level' {
            $answer = Get-HDTStepNeighbourTarget -Line $script:line -Name 'Apply OS' -Direction Up

            $after = @(Move-HDTStep -Line $script:line -Name 'Apply OS' `
                    -Target $answer.Target -TargetOccurrence $answer.TargetOccurrence -Position $answer.Position)

            & $script:groupOf $after 'Apply OS' | Should -BeExactly ''
            @(& $script:namesOf $after)[0] | Should -BeExactly 'Gather'
        }
    }
}
