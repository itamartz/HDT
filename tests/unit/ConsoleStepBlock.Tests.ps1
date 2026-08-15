# Finding the exact lines a step occupies in sequence.yaml.
#
# THIS IS THE FOUNDATION OF EVERY EDIT THE CONSOLE MAKES. Add, Remove, Up and
# Down are all splices of whole line ranges, and Save is then writing the string
# back. Nothing round-trips through the YAML parser, because ConvertFrom-HDTYaml
# produces a dictionary and a dictionary has no comments in it - DEMO-M4 on the
# lab share is 107 lines of which about 60 are a comment header recording SPIKES
# findings, and a save that re-serialised the model would delete every one.
# DESIGN 12: "a UI that reformats the file breaks git review, which is one of the
# reasons config-as-code fails in practice."
#
# A COMMENT ABOVE A STEP BELONGS TO THAT STEP. Every comment in DEMO-M4 explains
# the step beneath it - why minRamMB is 2048, why wipe: true is the sequence
# declaring the disk expendable, what ConfigureBoot does to the firmware boot
# order. Moving a step and leaving its explanation behind, attached to whatever
# now sits there, would be worse than not moving it at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop

    # DEMO-M4's shape, comments and all, at a size a test can reason about.
    $script:document = @'
# THE HEADER, which belongs to the document and to no step in it.
#
# It survives every edit.

schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal
variables:
  HDTOSImage: Win11-LTSC-2024

steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      # minRamMB is 2048 rather than 4096 ON PURPOSE: a 4 GB VM reports
      # slightly under 4096 because the firmware keeps some of it.
      - name: Validate
        type: Validate
        minRamMB: 2048
        minDiskGB: 60

      # wipe: true is the sequence declaring the target expendable.
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
'@ -split "`r?`n"
}

Describe 'Get-HDTConsoleStepBlock' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'has comment-based help' {
            InModuleScope HDT.Console {
                (Get-Help -Name 'Get-HDTConsoleStepBlock').Synopsis | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'what it finds' {

        BeforeAll {
            $script:block = InModuleScope HDT.Console -Parameters @{ Line = $script:document } {
                param($Line)
                @(Get-HDTConsoleStepBlock -Line $Line)
            }
        }

        It 'finds every step and every group' {
            @($script:block | Where-Object { $_.Kind -eq 'Step' }).Count | Should -Be 4
            @($script:block | Where-Object { $_.Kind -eq 'Group' }).Count | Should -Be 2
        }

        It 'names them' {
            @($script:block | Where-Object { $_.Kind -eq 'Step' } | ForEach-Object { $_.Name }) |
                Should -Be @('Validate', 'Format and Partition', 'Apply OS', 'Prepare Boot')
        }

        It 'reports them in document order' {
            $order = @($script:block | ForEach-Object { $_.Name })

            $order | Should -Be @(
                'Preinstall', 'Validate', 'Format and Partition',
                'Install', 'Apply OS', 'Prepare Boot')
        }

        It 'records the indentation each one sits at, which is what an insert has to match' {
            $validate = @($script:block | Where-Object { $_.Name -eq 'Validate' })[0]
            $group = @($script:block | Where-Object { $_.Name -eq 'Preinstall' })[0]

            $group.Indent | Should -Be 2
            $validate.Indent | Should -Be 6
        }
    }

    Context 'the span of a step' {

        BeforeAll {
            $script:block = InModuleScope HDT.Console -Parameters @{ Line = $script:document } {
                param($Line)
                @(Get-HDTConsoleStepBlock -Line $Line)
            }
        }

        It 'runs from the dash line to the last property line' {
            $step = @($script:block | Where-Object { $_.Name -eq 'Format and Partition' })[0]

            $script:document[$step.Entry] | Should -Match '^\s*- name: Format and Partition$'
            $script:document[$step.End] | Should -Match 'wipe: true'
        }

        It 'does not swallow the blank line that follows it' {
            # A splice that took trailing blank lines would collapse the spacing
            # of the file a little more with every edit.
            $step = @($script:block | Where-Object { $_.Name -eq 'Validate' })[0]

            $script:document[$step.End].Trim() | Should -Not -BeNullOrEmpty
        }

        It 'takes the comment above a step as part of it' {
            $step = @($script:block | Where-Object { $_.Name -eq 'Validate' })[0]

            $script:document[$step.Start] | Should -Match 'minRamMB is 2048'
        }

        It 'still points at the dash line separately, because an insert needs it' {
            $step = @($script:block | Where-Object { $_.Name -eq 'Validate' })[0]

            $step.Start | Should -BeLessThan $step.Entry
            $script:document[$step.Entry] | Should -Match '^\s*- name: Validate$'
        }

        It 'gives a step with no comment a Start that is its dash line' {
            $step = @($script:block | Where-Object { $_.Name -eq 'Apply OS' })[0]

            $step.Start | Should -Be $step.Entry
        }
    }

    Context 'the span of a group' {

        BeforeAll {
            $script:block = InModuleScope HDT.Console -Parameters @{ Line = $script:document } {
                param($Line)
                @(Get-HDTConsoleStepBlock -Line $Line)
            }
        }

        It 'covers the whole group, its steps included' {
            $group = @($script:block | Where-Object { $_.Name -eq 'Preinstall' })[0]

            $script:document[$group.Entry] | Should -Match '^\s*- group: Preinstall$'
            $script:document[$group.End] | Should -Match 'wipe: true'
        }

        It 'ends the last group at the last line of the document' {
            $group = @($script:block | Where-Object { $_.Name -eq 'Install' })[0]

            $script:document[$group.End] | Should -Match 'ConfigureBoot'
        }
    }

    Context 'what it refuses to touch' {

        It 'leaves the document header outside every block' {
            # The header explains the document, not any step in it. An edit that
            # could move or delete it would be the edit that loses the reasoning
            # DEMO-M4 exists to record.
            $block = InModuleScope HDT.Console -Parameters @{ Line = $script:document } {
                param($Line)
                @(Get-HDTConsoleStepBlock -Line $Line)
            }

            $first = @($block | Sort-Object Start)[0]

            $first.Start | Should -BeGreaterThan 4
        }

        It 'finds nothing in a document with no steps at all' {
            $block = InModuleScope HDT.Console -Parameters @{ Line = @('schemaVersion: 1', 'id: EMPTY') } {
                param($Line)
                @(Get-HDTConsoleStepBlock -Line $Line)
            }

            @($block) | Should -BeNullOrEmpty
        }
    }
}
