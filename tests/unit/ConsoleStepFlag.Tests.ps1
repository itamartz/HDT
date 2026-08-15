# Switching a step off, and giving it a condition - without reformatting the
# document.
#
# THESE ARE THE OPTIONS TAB'S CMDLETS. Deployment Workbench puts "Disable this
# step", "Continue on error" and the condition list on a second tab beside
# Properties, and DESIGN 12 says every button maps to a cmdlet invocation the
# console shows. Set-HDTConsoleStepFlag and Set-HDTConsoleStepCondition are
# those two controls, as commands.
#
# THEY SPLICE, LIKE EVERY OTHER EDIT HERE. See ConsoleStepEdit.Tests.ps1 for
# why: the lab's DEMO-M4 is half commentary, and a round trip through
# ConvertFrom-HDTYaml would return it with every comment gone.
#
# AN ABSENT KEY IS INSERTED, A PRESENT ONE IS REWRITTEN IN PLACE, AND CLEARING
# ONE TAKES ITS LINE OUT. The three cases are separate tests because they are
# three different splices and the middle one is the one that silently appends a
# second `disabled:` if it is got wrong - which YAML accepts and the engine
# then reads the wrong way round.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:text = @'
# THE HEADER, which belongs to the document and to no step in it.

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

      - name: Format and Partition
        type: DiskPartition
        disabled: true
        wipe: true

  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        condition: $Model -like 'Virtual*'
        index: 1

      - name: Prepare Boot
        type: ConfigureBoot
'@

    $script:line = $script:text -split "`r?`n"
}

Describe 'Set-HDTConsoleStepFlag' {

    Context 'a flag the step does not carry yet' {

        It 'inserts the key directly under type, at the step''s own indentation' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $true)

            $at = [array]::IndexOf($result, '        type: ApplyImage')
            $at | Should -BeGreaterThan 0
            $result[$at + 1] | Should -BeExactly '        disabled: true'
        }

        It 'leaves every other line byte-identical' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $true)

            $result.Count | Should -Be ($script:line.Count + 1)

            # Take out the ONE line that was added - by index, not by value:
            # 'Format and Partition' already carries a `disabled: true` of its
            # own, and a filter on the text would silently drop that one too and
            # then report the document unchanged.
            $added = [array]::IndexOf($result, '        type: ApplyImage') + 1

            $survivor = @($result[0..($added - 1)]) + @($result[($added + 1)..($result.Count - 1)])

            for ($i = 0; $i -lt $script:line.Count; $i++) {
                $survivor[$i] | Should -BeExactly $script:line[$i]
            }
        }

        It 'writes nothing at all when the flag is being set to the value it already means' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $false)

            $result.Count | Should -Be $script:line.Count
            ($result -join "`n") | Should -BeExactly ($script:line -join "`n")
        }

        It 'inserts continueOnError under type just the same' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Prepare Boot' -Flag ContinueOnError -Value $true)

            $at = [array]::IndexOf($result, '        type: ConfigureBoot')
            $result[$at + 1] | Should -BeExactly '        continueOnError: true'
        }
    }

    Context 'a flag the step already carries' {

        It 'rewrites the existing line rather than adding a second one' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Format and Partition' -Flag Disabled -Value $false)

            @($result | Where-Object { $_ -match '^\s*disabled:' }).Count | Should -Be 1
            $result | Should -Contain '        disabled: false'
            $result.Count | Should -Be $script:line.Count
        }

        It 'keeps the keys around it in their original order' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Format and Partition' -Flag Disabled -Value $false)

            $at = [array]::IndexOf($result, '        disabled: false')
            $result[$at - 1] | Should -BeExactly '        type: DiskPartition'
            $result[$at + 1] | Should -BeExactly '        wipe: true'
        }
    }

    Context 'a group' {

        It 'switches a whole group off without touching the steps inside it' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Install' -Flag Disabled -Value $true)

            $at = [array]::IndexOf($result, '  - group: Install')
            $result[$at + 1] | Should -BeExactly '    runIn: WinPE'
            $result[$at + 2] | Should -BeExactly '    disabled: true'

            # The step inside it still says exactly what it said.
            $result | Should -Contain '        type: ApplyImage'
            @($result | Where-Object { $_ -match '^\s*disabled:' }).Count | Should -Be 2
        }
    }

    Context 'the result the engine reads' {

        It 'produces a document Import-HDTSequenceDocument still accepts, with the step marked off' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $true)

            $path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
            $fs = New-HDTFakeFileSystem -File @{ $path = ($result -join "`r`n") }
            $document = Import-HDTSequenceDocument -Path $path -FileSystem $fs

            $step = @($document.Step | Where-Object { $_.Name -eq 'Apply OS' })[0]
            $step.Disabled | Should -BeTrue
        }
    }

    Context 'refusals' {

        It 'refuses a step that is not there' {
            { Set-HDTConsoleStepFlag -Line $script:line -Name 'Nowhere' -Flag Disabled -Value $true } |
                Should -Throw '*no step or group*'
        }

        It 'supports -WhatIf and changes nothing under it' {
            $result = @(Set-HDTConsoleStepFlag -Line $script:line -Name 'Apply OS' -Flag Disabled -Value $true -WhatIf)

            ($result -join "`n") | Should -BeExactly ($script:line -join "`n")
        }
    }
}

Describe 'Set-HDTConsoleStepCondition' {

    Context 'a step with no condition' {

        It 'inserts one under type' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Prepare Boot' -Condition '$IsUEFI -eq $true')

            $at = [array]::IndexOf($result, '        type: ConfigureBoot')
            $result[$at + 1] | Should -BeExactly "        condition: `$IsUEFI -eq `$true"
        }

        It 'leaves the rest of the document byte-identical' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Prepare Boot' -Condition '$IsUEFI -eq $true')

            $survivor = @($result | Where-Object { $_ -notmatch '^\s*condition: \$IsUEFI' })
            ($survivor -join "`n") | Should -BeExactly ($script:line -join "`n")
        }
    }

    Context 'a step that already has one' {

        It 'rewrites it in place' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Apply OS' -Condition '$Make -eq "Dell Inc."')

            @($result | Where-Object { $_ -match '^\s*condition:' }).Count | Should -Be 1
            $result | Should -Contain '        condition: $Make -eq "Dell Inc."'
            $result.Count | Should -Be $script:line.Count
        }

        It 'takes the line out entirely when the condition is cleared' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Apply OS' -Condition '')

            @($result | Where-Object { $_ -match '^\s*condition:' }).Count | Should -Be 0
            $result.Count | Should -Be ($script:line.Count - 1)

            $at = [array]::IndexOf($result, '        type: ApplyImage')
            $result[$at + 1] | Should -BeExactly '        index: 1'
        }
    }

    Context 'the result the engine reads' {

        It 'round-trips through Import-HDTSequenceDocument' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Prepare Boot' -Condition '$IsUEFI -eq $true')

            $path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
            $fs = New-HDTFakeFileSystem -File @{ $path = ($result -join "`r`n") }
            $document = Import-HDTSequenceDocument -Path $path -FileSystem $fs

            $step = @($document.Step | Where-Object { $_.Name -eq 'Prepare Boot' })[0]
            $step.Condition | Should -BeExactly '$IsUEFI -eq $true'
        }
    }

    Context 'refusals' {

        It 'refuses a step that is not there' {
            { Set-HDTConsoleStepCondition -Line $script:line -Name 'Nowhere' -Condition '$true' } |
                Should -Throw '*no step or group*'
        }

        It 'supports -WhatIf and changes nothing under it' {
            $result = @(Set-HDTConsoleStepCondition -Line $script:line -Name 'Prepare Boot' -Condition '$true' -WhatIf)

            ($result -join "`n") | Should -BeExactly ($script:line -join "`n")
        }
    }
}
