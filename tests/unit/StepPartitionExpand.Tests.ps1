# A STEP THAT NAMES A BUILT-IN LAYOUT COULD NOT BE EDITED AT ALL.
#
# 'layout: uefi-standard' means "the standard layout, whatever it becomes" - the
# step carries no rows, so the editor's five partition buttons were dark on every
# sequence the standard client template produces, which is every sequence anybody
# makes. MDT's Format and Partition Disk grid is editable from the moment you
# open it, and this is the command that makes HDT's editable too.
#
# IT IS ONE DELIBERATE CONVERSION AND NOT A SIDE EFFECT. After it runs the step
# carries its own table and no longer tracks the built-in; DESIGN 9.1's rule that
# a step answers the question exactly once still holds, because the layout key is
# removed in the same splice that writes the rows.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

Describe 'Expand-HDTStepPartition' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $script:named = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: demo
steps:
  - group: Preinstall
    steps:
      # the one the firmware boots from
      - name: Format and Partition
        type: DiskPartition
        diskNumber: 0
        layout: uefi-standard
        wipe: true
      - name: Apply
        type: NoOp
'@ -split "`r?`n")

        $script:authored = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: demo
steps:
  - group: Preinstall
    steps:
      - name: Format and Partition
        type: DiskPartition
        diskNumber: 0
        wipe: true
        partition:
          - name: System
            type: EFI
            size: 260MB
'@ -split "`r?`n")
    }

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Expand-HDTStepPartition' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'a step that names a built-in' {

        BeforeAll {
            $script:grown = @(Expand-HDTStepPartition -Line $script:named -Name 'Format and Partition' -Confirm:$false)
            $script:text = ($script:grown -join "`n")
        }

        It 'writes the layout out as the step''s own table' {
            $script:text | Should -BeLike '*partition:*'
            $script:text | Should -BeLike '*- name: System*'
            $script:text | Should -BeLike '*- name: Windows*'
            $script:text | Should -BeLike '*- name: Recovery*'
        }

        It 'stops naming the layout, so the step answers the question once' {
            # DESIGN 9.1: declaring both is refused, because they are two
            # different answers about the same disk. The conversion has to REMOVE
            # the key, not sit beside it.
            $script:text | Should -Not -BeLike '*layout: uefi-standard*'
        }

        It 'writes the sizes the built-in would have used' {
            $script:text | Should -BeLike '*size: 260MB*'
            $script:text | Should -BeLike '*size: remainder*'
            $script:text | Should -BeLike '*size: 1GB*'
        }

        It 'writes the types as the words an authored table uses' {
            $script:text | Should -BeLike '*type: EFI*'
            $script:text | Should -BeLike '*type: Recovery*'
        }

        It 'keeps the file system the built-in chose for the ESP' {
            $script:text | Should -BeLike '*filesystem: FAT32*'
        }

        It 'leaves every other line of the document alone' {
            # A COMMENT DIES AT PARSE TIME, which is why every edit in this
            # toolkit splices. The step above and the step below have to come
            # back exactly as they went in.
            $script:text | Should -BeLike '*# the one the firmware boots from*'
            $script:text | Should -BeLike '*- name: Apply*'
            $script:text | Should -BeLike '*diskNumber: 0*'
            $script:text | Should -BeLike '*wipe: true*'
        }

        It 'reads back as a sequence the engine can still run' {
            $reader = New-HDTFakeFileSystem -File @{
                'C:\ws\sequence.yaml' = ($script:grown -join [System.Environment]::NewLine)
            }
            $sequence = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $reader

            @($sequence.Step | Where-Object { $_.Name -eq 'Format and Partition' }).Count | Should -Be 1
        }

        It 'still publishes the volume variables, because the role IS the name' {
            # THE ONE THING THAT COULD BREAK A DEPLOYMENT SILENTLY.
            # Invoke-HDTDiskPartitionStep writes HDTSystemVolume, HDTOSVolume and
            # HDTRecoveryVolume by ROLE, and ConvertTo-HDTDiskLayout takes an
            # authored row's role from its name - so a conversion that renamed
            # Windows to anything else would apply the image to nowhere.
            $reader = New-HDTFakeFileSystem -File @{
                'C:\ws\sequence.yaml' = ($script:grown -join [System.Environment]::NewLine)
            }
            $sequence = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $reader

            $step = @($sequence.Step | Where-Object { $_.Name -eq 'Format and Partition' })[0]
            $rows = @($step.Property['partition'])

            $layout = ConvertTo-HDTDiskLayout -Style GPT -Partition $rows

            @($layout.Partition | ForEach-Object { $_.Role }) | Should -Be @('System', 'Windows', 'Recovery')
        }
    }

    Context 'what it refuses' {

        It 'refuses a step that already writes its own table' {
            # NOT AN ERROR TO BE HELPFUL ABOUT - there is nothing to expand, and
            # overwriting the rows somebody authored would be the worst possible
            # reading of "expand".
            { Expand-HDTStepPartition -Line $script:authored -Name 'Format and Partition' -Confirm:$false } |
                Should -Throw '*already*'
        }

        It 'refuses a layout name that is a variable, by saying so' {
            # AN MDT-SHAPED SEQUENCE PARAMETERISES IT - DEMO-M4 carries
            # layout: "%HDTDiskLayout%" - and the console edits the DOCUMENT,
            # where that token has not been expanded and never will be. There is
            # no table to write, because nobody yet knows which one.
            $token = [string[]] @($script:named | ForEach-Object {
                    $_ -replace 'layout: uefi-standard', 'layout: "%HDTDiskLayout%"'
                })

            { Expand-HDTStepPartition -Line $token -Name 'Format and Partition' -Confirm:$false } |
                Should -Throw '*%HDTDiskLayout%*'
        }

        It 'refuses a layout this engine does not have' {
            $wrong = [string[]] @($script:named | ForEach-Object {
                    $_ -replace 'layout: uefi-standard', 'layout: uefi-deluxe'
                })

            { Expand-HDTStepPartition -Line $wrong -Name 'Format and Partition' -Confirm:$false } |
                Should -Throw '*uefi-deluxe*'
        }

        It 'refuses a step that is not a DiskPartition one' {
            { Expand-HDTStepPartition -Line $script:named -Name 'Apply' -Confirm:$false } |
                Should -Throw '*DiskPartition*'
        }
    }

    It 'writes nothing under -WhatIf' {
        $same = @(Expand-HDTStepPartition -Line $script:named -Name 'Format and Partition' -WhatIf)

        ($same -join "`n") | Should -BeExactly ($script:named -join "`n")
    }
}
