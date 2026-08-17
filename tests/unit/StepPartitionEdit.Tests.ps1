# Editing the partition table of a DiskPartition step, from a command.
#
# THE GRID CANNOT EXIST WITHOUT THESE. The console's rule is that a window may
# not do anything the cmdlets cannot, and MDT's Format and Partition Disk dialog
# is New / Edit / Delete plus up and down arrows over a list of volumes. Each of
# those is a command here first.
#
# THEY SPLICE LINES, like every other authoring command in this toolkit: a parse
# and re-emit hands back a correct document and none of the comments an
# administrator wrote beside their partitions.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:text = @'
# A sequence somebody wrote, comments and all.
schemaVersion: 1
id: DEMO-PART
name: partition editing
steps:
  - group: Preinstall
    steps:
      # The disk this machine ends up with.
      - name: Format and Partition
        type: DiskPartition
        wipe: true
        style: GPT
        partition:
          - name: System
            type: EFI
            size: 260MB
          - name: Windows
            type: Primary
            size: remainder
'@

    $script:line = [string[]] @($script:text -split "`r?`n")

    function Get-HDTTestPartition {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($Line -join "`r`n") }
        $sequence = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fs

        $step = @($sequence.Step | Where-Object { $_.Type -eq 'DiskPartition' })[0]

        return @($step.Property['partition'])
    }
}

Describe 'Add-HDTStepPartition' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Add-HDTStepPartition' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'appends a partition, because order is the on-disk order' {
        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size '50GB'

        $row = @(Get-HDTTestPartition -Line $after)

        @($row).Count | Should -Be 3
        [string] $row[2]['name'] | Should -BeExactly 'Data'
        [string] $row[2]['size'] | Should -BeExactly '50GB'
    }

    It 'puts one first when it is asked to' {
        # AN ESP ADDED AFTER WINDOWS IS A DISK THAT DOES NOT BOOT, so the same
        # -First the start commands have is the difference between a usable
        # command and one that needs a move straight afterwards.
        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Boot' -Type Primary -Size '500MB' -First

        [string] @(Get-HDTTestPartition -Line $after)[0]['name'] | Should -BeExactly 'Boot'
    }

    It 'leaves every other line byte-identical' {
        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size '50GB'

        @(Compare-Object -ReferenceObject $script:line -DifferenceObject $after |
                Where-Object { $_.SideIndicator -eq '<=' }) | Should -BeNullOrEmpty
    }

    It 'refuses a size the engine cannot read, at the moment it is typed' {
        # THE SAME REFUSAL ConvertTo-HDTDiskLayout MAKES, made earlier. A
        # document that authors cleanly and fails at the disk is a document
        # whose mistake is found by whoever is standing at the machine.
        { Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
                -Partition 'Data' -Type Primary -Size 'big' } | Should -Throw
    }

    It 'refuses a step that has no partition table' {
        $named = [string[]] @(
            'schemaVersion: 1'; 'id: X'; 'name: Y'
            'steps:'
            '  - name: Format and Partition'
            '    type: DiskPartition'
            '    layout: uefi-standard')

        { Add-HDTStepPartition -Line $named -Name 'Format and Partition' `
                -Partition 'Data' -Type Primary -Size '50GB' } |
            Should -Throw -ExpectedMessage '*layout*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size '50GB' -WhatIf

        ($after -join "`n") | Should -BeExactly ($script:line -join "`n")
    }
}

Describe 'Remove-HDTStepPartition' {

    It 'removes the one it is given' {
        $after = Remove-HDTStepPartition -Line $script:line -Name 'Format and Partition' -Partition 'System'

        $row = @(Get-HDTTestPartition -Line $after)

        @($row).Count | Should -Be 1
        [string] $row[0]['name'] | Should -BeExactly 'Windows'
    }

    It 'refuses to remove one the step does not have' {
        { Remove-HDTStepPartition -Line $script:line -Name 'Format and Partition' -Partition 'Nope' } |
            Should -Throw -ExpectedMessage '*Nope*'
    }

    It 'refuses to remove the last one' {
        # A DiskPartition STEP WITH AN EMPTY TABLE IS NOT A LAYOUT, and
        # ConvertTo-HDTDiskLayout refuses it at build time. Refusing here means
        # the document never reaches that state.
        $after = Remove-HDTStepPartition -Line $script:line -Name 'Format and Partition' -Partition 'System'

        { Remove-HDTStepPartition -Line $after -Name 'Format and Partition' -Partition 'Windows' } |
            Should -Throw -ExpectedMessage '*last*'
    }
}

Describe 'Move-HDTStepPartition' {

    It 'moves one <Direction>, one place' -ForEach @(
        @{ Direction = 'Up'; Subject = 'Windows'; Expected = @('Windows', 'System') }
        @{ Direction = 'Down'; Subject = 'System'; Expected = @('Windows', 'System') }
    ) {
        $after = Move-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition $Subject -Direction $Direction

        @(Get-HDTTestPartition -Line $after | ForEach-Object { [string] $_['name'] }) | Should -Be $Expected
    }

    It 'does nothing at the end of the list, which is a press and not a mistake' {
        $after = Move-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'System' -Direction Up

        @(Get-HDTTestPartition -Line $after | ForEach-Object { [string] $_['name'] }) |
            Should -Be @('System', 'Windows')
    }
}
