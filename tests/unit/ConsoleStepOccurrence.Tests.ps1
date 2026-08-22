# TWO STEPS WITH THE SAME NAME, AND THE ROW SOMEBODY CLICKED.
#
# Watched in the console: a task sequence with two steps called 'Tattoo', a
# technician selecting the second one and pressing Remove, and this -
#
#   Tattoo: this task sequence holds 2 steps called 'Tattoo', so the one to act
#   on is ambiguous. Rename one of them first.
#
# THE REFUSAL IS RIGHT AND THE CALLER WAS WRONG. `Remove-HDTStep -Name 'Tattoo'`
# on a document with two of them genuinely is ambiguous, and CLAUDE.md rule 6
# says an ambiguous target is refused rather than guessed at. But the console had
# not asked an ambiguous question: a row in a tree was selected, and the console
# threw that away and passed a STRING.
#
# SO THE NAME GAINS AN ORDINAL. -Occurrence says which of the same-named blocks
# is meant, in document order, and the command line keeps its refusal untouched:
# no -Occurrence and two matches is still an error, because a person typing a
# name has still not said which.
#
# DUPLICATE NAMES ARE LEGITIMATE. MDT allows them, a sequence that tattoos twice
# is a real sequence, and "rename one of them first" is a toolkit telling an
# administrator to change their deployment to suit its own addressing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

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

      - name: Tattoo
        type: Tattoo

  - group: State Restore
    runIn: FullOS
    steps:
      - name: Install Applications
        type: InstallApplications

      - name: Tattoo
        type: Tattoo

      - name: Prepare Boot
        type: ConfigureBoot
'@

    $script:line = $script:text -split "`r?`n"

    # The names, in document order, so a move or a removal can be read off the
    # result rather than described.
    $script:namesOf = {
        param([string[]] $Line)

        return [string[]] @($Line | Where-Object { $_ -match '^\s*- name:\s*(.+)$' } |
                ForEach-Object { $Matches[1].Trim() })
    }
}

Describe 'addressing a step when two share a name' {

    Context 'the command line still refuses to guess' {

        It 'refuses Remove-HDTStep on an ambiguous name' {
            { Remove-HDTStep -Line $script:line -Name 'Tattoo' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*ambiguous*'
        }

        It 'refuses Move-HDTStep on an ambiguous name' {
            { Move-HDTStep -Line $script:line -Name 'Tattoo' -Direction Up } |
                Should -Throw -ExpectedMessage '*ambiguous*'
        }

        It 'still refuses a name that is not there at all' {
            { Remove-HDTStep -Line $script:line -Name 'Nowhere' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no step or group*'
        }
    }

    Context 'an occurrence says which one' {

        It 'removes the first Tattoo and leaves the second' {
            $after = @(Remove-HDTStep -Line $script:line -Name 'Tattoo' -Occurrence 1 -Confirm:$false)
            $names = @(& $script:namesOf $after)

            @($names | Where-Object { $_ -eq 'Tattoo' }).Count | Should -Be 1

            # The one that survived is the one after Install Applications.
            $names -join '|' | Should -BeExactly 'Apply OS|Install Applications|Tattoo|Prepare Boot'
        }

        It 'removes the second Tattoo and leaves the first' {
            $after = @(Remove-HDTStep -Line $script:line -Name 'Tattoo' -Occurrence 2 -Confirm:$false)
            $names = @(& $script:namesOf $after)

            $names -join '|' | Should -BeExactly 'Apply OS|Tattoo|Install Applications|Prepare Boot'
        }

        It 'moves the second Tattoo without touching the first' {
            $after = @(Move-HDTStep -Line $script:line -Name 'Tattoo' -Occurrence 2 -Direction Up)
            $names = @(& $script:namesOf $after)

            $names -join '|' | Should -BeExactly 'Apply OS|Tattoo|Tattoo|Install Applications|Prepare Boot'
        }

        It 'refuses an occurrence that is not there' {
            { Remove-HDTStep -Line $script:line -Name 'Tattoo' -Occurrence 3 -Confirm:$false } |
                Should -Throw -ExpectedMessage '*3*'
        }

        It 'accepts an occurrence of 1 on a name that appears once' {
            # So a caller that always passes one does not have to know whether
            # the name happens to be unique - which is exactly the console.
            $after = @(Remove-HDTStep -Line $script:line -Name 'Apply OS' -Occurrence 1 -Confirm:$false)

            @(& $script:namesOf $after) -join '|' |
                Should -BeExactly 'Tattoo|Install Applications|Tattoo|Prepare Boot'
        }
    }

    Context 'every command that addresses a step takes one' {

        It '<_> has an -Occurrence parameter' -ForEach @(
            'Remove-HDTStep', 'Move-HDTStep', 'Copy-HDTStep',
            'Set-HDTStepProperty', 'Set-HDTStepCondition', 'Set-HDTStepFlag') {

            (Get-Command -Name $PSItem).Parameters.Keys | Should -Contain 'Occurrence'
        }
    }

    Context 'the properties follow the same row' {

        It 'sets a property on the second Tattoo only' {
            $after = @(Set-HDTStepProperty -Line $script:line -Name 'Tattoo' -Occurrence 2 `
                    -Property 'description' -Value 'the second one')

            @($after | Where-Object { $_ -match 'the second one' }).Count | Should -Be 1

            # And it landed after Install Applications, not before it.
            $where = [array]::FindIndex([string[]] $after, [Predicate[string]] { param($l) $l -match 'the second one' })
            $apps = [array]::FindIndex([string[]] $after, [Predicate[string]] { param($l) $l -match 'Install Applications' })

            $where | Should -BeGreaterThan $apps
        }
    }
}
