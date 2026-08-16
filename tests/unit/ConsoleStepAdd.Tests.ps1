# Adding a step, pasting one, and writing the result back to the share.
#
# ADD IS THE ONLY OPERATION THAT INVENTS TEXT, and it therefore has to invent it
# at the right indentation - a step written two columns out is a document the
# engine refuses, and the administrator's own edit is what broke it.
#
# SAVE IS THE ONLY OPERATION THAT TOUCHES THE SHARE. Everything else composes
# lines in memory, so an edit can be built up, looked at and abandoned without a
# file changing. That is also what makes Save the right place for the last
# check: the spliced text is handed to the ENGINE'S OWN reader before a byte is
# written, so a bad edit fails in the editor rather than leaving a task sequence
# on the share that no deployment can run.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'

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

    function Read-HDTTestDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($Line -join "`r`n") }

        return Import-HDTSequenceDocument -Path $script:path -FileSystem $fs
    }
}

Describe 'Add-HDTConsoleStep' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Add-HDTConsoleStep' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'puts a new step after the one it was told to follow' {
        $after = Add-HDTConsoleStep -Line $script:line -After 'Validate' -Name 'Check TPM' -Type 'Validate'

        Get-HDTTestStepName -Line $after |
            Should -Be @('Validate', 'Check TPM', 'Format and Partition', 'Apply OS', 'Prepare Boot')
    }

    It 'writes it at the indentation of its new neighbour' {
        # A step written two columns out is a document the engine refuses, and
        # the administrator's own edit is what broke it.
        $after = Add-HDTConsoleStep -Line $script:line -After 'Validate' -Name 'Check TPM' -Type 'Validate'
        $at = @($after | Select-String -Pattern '- name: Check TPM').LineNumber - 1

        $after[$at] | Should -BeExactly '      - name: Check TPM'
    }

    It 'lands in the same group as the step it follows' {
        $document = Read-HDTTestDocument -Line (Add-HDTConsoleStep -Line $script:line -After 'Validate' -Name 'Check TPM' -Type 'Validate')
        $step = @($document.Step | Where-Object { $_.Name -eq 'Check TPM' })[0]

        @($step.GroupPath) -join '/' | Should -BeExactly 'Preinstall'
    }

    It 'produces a step the engine reads back with the type it was given' {
        $document = Read-HDTTestDocument -Line (Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Name 'Reboot' -Type 'Restart')
        $step = @($document.Step | Where-Object { $_.Name -eq 'Reboot' })[0]

        $step.Type | Should -BeExactly 'Restart'
    }

    It 'refuses a step type the engine does not have' {
        # The authoring lint reports an unknown type as an Error finding; the
        # editor should not be able to create one in the first place.
        { Add-HDTConsoleStep -Line $script:line -After 'Validate' -Name 'X' -Type 'NoSuchType' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*NoSuchType*'
    }

    It 'leaves every other line byte-identical' {
        $after = Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Name 'Reboot' -Type 'Restart'

        @($after | Select-Object -First 18) | Should -Be @($script:line | Select-Object -First 18)
    }

    It 'keeps the document header' {
        $after = Add-HDTConsoleStep -Line $script:line -After 'Validate' -Name 'Check TPM' -Type 'Validate'

        ($after -join "`n") | Should -Match 'THE HEADER, which belongs to the document'
    }
}

Describe 'Add-HDTConsoleStep -Block (paste)' {

    It 'pastes a copied step after the named one' {
        $block = Copy-HDTConsoleStep -Line $script:line -Name 'Validate'
        $after = Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Block $block

        Get-HDTTestStepName -Line $after |
            Should -Be @('Validate', 'Format and Partition', 'Apply OS', 'Validate', 'Prepare Boot')
    }

    It 'brings the copied comment with it' {
        $block = Copy-HDTConsoleStep -Line $script:line -Name 'Validate'
        $after = Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Block $block

        (($after -join "`n") -split 'minRamMB is 2048').Count | Should -Be 3
    }

    It 'reindents a step pasted into a group at a different depth' {
        # Copy from a group and paste beside a top-level step and the block
        # arrives with the wrong indentation unless it is retargeted. YAML is
        # whitespace-significant, so that is the difference between a step and a
        # parse error.
        $block = @('      - name: Pasted', '        type: NoOp')
        $after = Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Block $block
        $at = @($after | Select-String -Pattern '- name: Pasted').LineNumber - 1

        $after[$at] | Should -BeExactly '      - name: Pasted'
    }

    It 'produces a document the engine still reads' {
        $block = Copy-HDTConsoleStep -Line $script:line -Name 'Format and Partition'
        $document = Read-HDTTestDocument -Line (Add-HDTConsoleStep -Line $script:line -After 'Apply OS' -Block $block)

        @($document.Step).Count | Should -Be 5
    }
}

Describe 'Save-HDTConsoleSequence' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Save-HDTConsoleSequence' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the document to the path it was given' {
        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($script:line -join "`r`n") }
        $after = Remove-HDTConsoleStep -Line $script:line -Name 'Apply OS'

        [void] (Save-HDTConsoleSequence -Path $script:path -Line $after -FileSystem $fs)

        $written = @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' })
        @($written).Count | Should -Be 1
        $written[0].Arguments[0] | Should -BeExactly $script:path
    }

    It 'writes what the editor produced, comments and all' {
        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($script:line -join "`r`n") }
        $after = Remove-HDTConsoleStep -Line $script:line -Name 'Apply OS'

        [void] (Save-HDTConsoleSequence -Path $script:path -Line $after -FileSystem $fs)

        $written = @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' })[0].Arguments[1]

        $written | Should -Match 'THE HEADER, which belongs to the document'
        $written | Should -Match 'minRamMB is 2048 rather than'
    }

    It 'keeps the file''s own line endings' {
        # A save that rewrote every line ending would show as a diff touching
        # every line of the file, which is the git-review problem DESIGN 12 is
        # about, arriving by a different route.
        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($script:line -join "`r`n") }

        [void] (Save-HDTConsoleSequence -Path $script:path -Line $script:line -FileSystem $fs)

        $written = @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' })[0].Arguments[1]

        $written | Should -Match "`r`n"
        ($written -split "`r`n").Count | Should -Be @($script:line).Count
    }

    It 'REFUSES to write a document the engine could not read' {
        # The whole point of doing this at the moment of writing: a bad edit
        # fails in the editor rather than leaving a task sequence on the share
        # that no deployment can run.
        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($script:line -join "`r`n") }
        $broken = @('schemaVersion: 1', 'id: DEMO-M4', '  name: not valid yaml at all')

        { Save-HDTConsoleSequence -Path $script:path -Line $broken -FileSystem $fs -ErrorAction Stop } |
            Should -Throw

        @($fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' }) | Should -BeNullOrEmpty
    }

    It 'says what it wrote, so a caller is not left guessing' {
        $fs = New-HDTFakeFileSystem -File @{ $script:path = ($script:line -join "`r`n") }

        $answer = Save-HDTConsoleSequence -Path $script:path -Line $script:line -FileSystem $fs

        $answer.Saved | Should -BeTrue
        $answer.Path | Should -BeExactly $script:path
        $answer.StepCount | Should -Be 4
    }
}
