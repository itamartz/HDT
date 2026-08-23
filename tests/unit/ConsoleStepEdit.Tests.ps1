# Editing a task sequence document without reformatting it.
#
# EVERY BUTTON IN THE EDITOR IS ONE OF THESE CMDLETS. DESIGN 12: "the console
# may not do anything the cmdlets can't. Every action it performs maps to a
# cmdlet invocation, and the console shows that invocation - so an admin can
# learn the automation surface by clicking around, and script anything they can
# do in the UI." Add, Remove, Up, Down, Copy and Paste are therefore commands
# first and buttons second.
#
# THEY ALL SPLICE LINES, AND NONE OF THEM PARSE YAML. ConvertFrom-HDTYaml yields
# a dictionary and a dictionary has no comments in it; the lab's DEMO-M4 is 107
# lines of which 51 are a header recording SPIKES findings. An edit that
# round-tripped through the parser would return a file with every comment gone
# and every key reordered, which is the thing DESIGN 12 forbids: "a UI that
# reformats the file breaks git review".
#
# THE BENCHMARK IS THEREFORE BYTE-EQUALITY OF EVERYTHING NOT EDITED. It is not
# enough that the result parses; the lines nobody touched must come back
# identical, including their blank lines and their indentation.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # ONE IMPORT, AND IT IS THE ENGINE'S. The console commands and the engine
    # ship in the same module now, so the benchmark for an edit - that the
    # deployment's own reader still accepts the result, not that it merely looks
    # right in a diff - is met by the same manifest that supplies the editor.

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

      # wipe: true declares the target expendable.
      - name: Format and Partition
        type: DiskPartition
        wipe: true

  - group: Install
    runIn: WinPE
    steps:
      - name: Apply OS
        type: ApplyImage
        index: 1

      - name: Prepare Boot
        type: ConfigureBoot
'@

    $script:line = $script:text -split "`r?`n"

    function Get-HDTTestStepName {
        [CmdletBinding()]
        [OutputType([string[]])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        return [string[]] @($Line | Where-Object { $_ -match '^\s*- name:\s*(.+)$' } |
                ForEach-Object { ($_ -replace '^\s*- name:\s*', '').Trim() })
    }
}

Describe 'Remove-HDTStep' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Remove-HDTStep' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'takes the step out' {
        $after = Remove-HDTStep -Line $script:line -Name 'Apply OS'

        Get-HDTTestStepName -Line $after |
            Should -Be @('Validate', 'Format and Partition', 'Prepare Boot')
    }

    It 'takes the comment that explained it with it' {
        # A comment left behind attaches itself to whatever now sits beneath it,
        # which is worse than deleting it: the file then states something untrue.
        $after = Remove-HDTStep -Line $script:line -Name 'Validate'

        ($after -join "`n") | Should -Not -Match 'minRamMB is 2048 rather than'
    }

    It 'leaves every other line byte-identical' {
        $after = Remove-HDTStep -Line $script:line -Name 'Apply OS'

        # Everything before the Install group is untouched, to the character.
        $before = @($script:line[0..($script:line.Count - 1)] | Select-Object -First 20)
        @($after | Select-Object -First 20) | Should -Be $before
    }

    It 'leaves the document header alone' {
        $after = Remove-HDTStep -Line $script:line -Name 'Validate'

        ($after -join "`n") | Should -Match 'THE HEADER, which belongs to the document'
    }

    It 'removes a whole group, steps and all' {
        $after = Remove-HDTStep -Line $script:line -Name 'Preinstall'

        Get-HDTTestStepName -Line $after | Should -Be @('Apply OS', 'Prepare Boot')
        ($after -join "`n") | Should -Not -Match 'Preinstall'
    }

    It 'refuses a name that is not there, rather than silently changing nothing' {
        { Remove-HDTStep -Line $script:line -Name 'No Such Step' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*No Such Step*'
    }

    It 'empties a group and leaves a document the engine still reads' {
        # IT USED TO REFUSE THIS. A group with no steps was not a document the
        # engine would load, so taking the last step out of one had to be
        # refused with "remove the group instead" - an administrator clearing a
        # group out to refill it was told to delete the group and type its name
        # again. An empty group is legal now, so the removal is just a removal.
        $single = @'
schemaVersion: 1
id: ONE
name: One step per group
steps:
  - group: Only
    steps:
      - name: Alone
        type: NoOp
  - group: Other
    steps:
      - name: Company
        type: NoOp
'@ -split "`r?`n"

        $after = Remove-HDTStep -Line $single -Name 'Alone'

        ($after -join "`n") | Should -Not -Match 'Alone'
        ($after -join "`n") | Should -Match 'group: Only'

        # The benchmark: what is left is still a document, and the emptied group
        # is still a row in the tree rather than something that vanished.
        $state = Get-HDTConsoleEditorState -Line $after -Path 'C:\ws\TaskSequences\ONE\sequence.yaml'

        $state.Status | Should -BeExactly 'Ok' -Because $state.Message
        @($state.Node | Where-Object { $_.Kind -eq 'StepGroup' -and $_.Name -eq 'Only' }).Count | Should -Be 1
    }

    It 'takes the whole GROUP, steps and all, when the group is what was named' {
        $single = @'
schemaVersion: 1
id: ONE
name: One step per group
steps:
  - group: Only
    steps:
      - name: Alone
        type: NoOp
  - group: Other
    steps:
      - name: Company
        type: NoOp
'@ -split "`r?`n"

        $after = Remove-HDTStep -Line $single -Name 'Only'

        ($after -join "`n") | Should -Not -Match 'Alone'
        ($after -join "`n") | Should -Match 'Company'
    }
}

Describe 'Move-HDTStep' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Move-HDTStep' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'moves a step up past its sibling' {
        $after = Move-HDTStep -Line $script:line -Name 'Format and Partition' -Direction Up

        Get-HDTTestStepName -Line $after |
            Should -Be @('Format and Partition', 'Validate', 'Apply OS', 'Prepare Boot')
    }

    It 'moves a step down past its sibling' {
        $after = Move-HDTStep -Line $script:line -Name 'Apply OS' -Direction Down

        Get-HDTTestStepName -Line $after |
            Should -Be @('Validate', 'Format and Partition', 'Prepare Boot', 'Apply OS')
    }

    It 'carries the comment with the step it explains' {
        # The whole reason a move is a splice of Start..End rather than of the
        # dash line: DEMO-M4's comments are the record of what SPIKES proved.
        $after = Move-HDTStep -Line $script:line -Name 'Format and Partition' -Direction Up
        $joined = $after -join "`n"

        $joined | Should -Match 'wipe: true declares the target expendable\.[\s\S]{0,80}- name: Format and Partition'
    }

    It 'will not move the first step up out of its group' {
        # Up on the first step could mean "into the group above", which is a
        # different and much larger operation. Refusing is honest; guessing is
        # how an administrator loses a step.
        { Move-HDTStep -Line $script:line -Name 'Validate' -Direction Up -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*first*'
    }

    It 'will not move the last step down out of its group' {
        { Move-HDTStep -Line $script:line -Name 'Prepare Boot' -Direction Down -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*last*'
    }

    It 'keeps the line count identical, because a move creates and destroys nothing' {
        $after = Move-HDTStep -Line $script:line -Name 'Apply OS' -Direction Down

        @($after).Count | Should -Be @($script:line).Count
    }

    It 'moves whole groups too' {
        $after = Move-HDTStep -Line $script:line -Name 'Install' -Direction Up

        Get-HDTTestStepName -Line $after |
            Should -Be @('Apply OS', 'Prepare Boot', 'Validate', 'Format and Partition')
    }
}

Describe 'Copy-HDTStep' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Copy-HDTStep' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'returns the step''s own lines, comment included' {
        $block = Copy-HDTStep -Line $script:line -Name 'Validate'

        ($block -join "`n") | Should -Match 'minRamMB is 2048'
        ($block -join "`n") | Should -Match '- name: Validate'
    }

    It 'does not include the following step' {
        $block = Copy-HDTStep -Line $script:line -Name 'Validate'

        ($block -join "`n") | Should -Not -Match 'Format and Partition'
    }

    It 'changes nothing in the document' {
        [void] (Copy-HDTStep -Line $script:line -Name 'Validate')

        Get-HDTTestStepName -Line $script:line |
            Should -Be @('Validate', 'Format and Partition', 'Apply OS', 'Prepare Boot')
    }
}

# WHAT COMES OUT IS STILL A SEQUENCE DOCUMENT. Splicing lines is how the
# comments survive, but the result has to be a file the ENGINE can run - not
# merely one that looks right in a diff. Every edit is therefore checked by
# handing the result back to Import-HDTSequenceDocument, which is the same
# command the deployment uses.
Describe 'an edited document is still a task sequence' {

    BeforeAll {
        function Test-HDTEditedDocument {
            [CmdletBinding()]
            [OutputType([object])]
            param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

            $path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
            $fs = New-HDTFakeFileSystem -File @{ $path = ($Line -join "`r`n") }

            return Import-HDTSequenceDocument -Path $path -FileSystem $fs
        }
    }

    It 'still parses after a remove' {
        $document = Test-HDTEditedDocument -Line (Remove-HDTStep -Line $script:line -Name 'Apply OS')

        @($document.Step).Count | Should -Be 3
    }

    It 'still parses after a move, with the new order' {
        $document = Test-HDTEditedDocument -Line (Move-HDTStep -Line $script:line -Name 'Format and Partition' -Direction Up)

        @($document.Step | ForEach-Object { $_.Name })[0] | Should -BeExactly 'Format and Partition'
    }

    It 'keeps the groups a move did not touch' {
        $document = Test-HDTEditedDocument -Line (Move-HDTStep -Line $script:line -Name 'Apply OS' -Direction Down)

        @($document.Group | ForEach-Object { @($_.Path) -join '/' }) | Should -Be @('Preinstall', 'Install')
    }

    It 'still parses after a whole group is removed' {
        $document = Test-HDTEditedDocument -Line (Remove-HDTStep -Line $script:line -Name 'Preinstall')

        @($document.Step).Count | Should -Be 2
        @($document.Group).Count | Should -Be 1
    }
}


}
