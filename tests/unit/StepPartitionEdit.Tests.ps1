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

Describe 'Set-HDTStepPartition' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Set-HDTStepPartition' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'rewrites the row without moving it' {
        # DELETE AND ADD AGAIN WOULD PUT IT AT THE BOTTOM, which is a change to
        # the disk rather than to the volume. This is why Edit is its own
        # command and not two of the others.
        $after = Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'System' -Type EFI -Size 512MB

        $row = @(Get-HDTTestPartition -Line $after)

        @($row | ForEach-Object { [string] $_['name'] }) | Should -Be @('System', 'Windows')
        [string] $row[0]['size'] | Should -BeExactly '512MB'
    }

    It 'renames one, keeping its place' {
        $after = Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Windows' -NewName 'OS' -Type Primary -Size remainder

        @(Get-HDTTestPartition -Line $after | ForEach-Object { [string] $_['name'] }) |
            Should -Be @('System', 'OS')
    }

    It 'writes the whole row, so a cleared field is cleared' {
        # A MERGE WOULD LEAVE THE OLD FILESYSTEM BEHIND and no combination of
        # parameters could remove it again. The dialog has every field on
        # screen and OK writes all of them; so does this.
        $with = Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Windows' -Type Primary -Size remainder -FileSystem NTFS -Variable OSDisk

        @(Get-HDTTestPartition -Line $with)[1]['filesystem'] | Should -BeExactly 'NTFS'

        $without = Set-HDTStepPartition -Line $with -Name 'Format and Partition' `
            -Partition 'Windows' -Type Primary -Size remainder

        @(Get-HDTTestPartition -Line $without)[1].Contains('filesystem') | Should -BeFalse
        @(Get-HDTTestPartition -Line $without)[1].Contains('variable') | Should -BeFalse
    }

    It 'keeps the comment written above the row it rewrites' {
        # The fixture's own comment sits above the STEP. This one has to sit
        # above the partition, or the assertion passes without the code being
        # asked anything.
        $noted = [string[]] @(@($script:line) | ForEach-Object {
                if ($_ -eq '          - name: Windows') { '          # the volume the OS lands on'; $_ } else { $_ }
            })

        $after = Set-HDTStepPartition -Line $noted -Name 'Format and Partition' `
            -Partition 'Windows' -Type Primary -Size remainder

        @($after) -join "`n" | Should -BeLike '*the volume the OS lands on*'

        # And still directly above it, rather than pushed anywhere else.
        $at = [array]::IndexOf(@($after), '          # the volume the OS lands on')
        $after[$at + 1] | Should -BeExactly '          - name: Windows'
    }

    It 'refuses a size the engine cannot read, before the disk sees it' {
        { Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
                -Partition 'Windows' -Type Primary -Size 'about half' } |
            Should -Throw
    }

    It 'refuses one the step does not have' {
        { Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
                -Partition 'Nope' -Type Primary -Size 1GB } |
            Should -Throw -ExpectedMessage '*Nope*'
    }

    It 'changes nothing under -WhatIf' {
        $after = Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'System' -Type EFI -Size 512MB -WhatIf

        @($after) | Should -Be @($script:line)
    }
}

Describe 'quick format and bootable' {

    # MDT'S "Quick format" AND "Make this a boot partition" CHECKBOXES. The
    # engine already reads both keys; before this the commands could not write
    # either, so the two boxes on that dialog had nothing behind them.
    #
    # THEY TAKE A BOOLEAN RATHER THAN BEING SWITCHES, because unspecified and
    # false are different answers. The engine makes the FIRST partition bootable
    # when nothing says otherwise, so a row that means "not this one" has to be
    # able to say `bootable: false` out loud.

    It 'writes nothing when neither is named, so the engine defaults stand' {
        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size 1GB

        $row = @(Get-HDTTestPartition -Line $after)[-1]

        $row.Contains('quickFormat') | Should -BeFalse
        $row.Contains('bootable') | Should -BeFalse
    }

    It 'writes <Key>: <Written> when told to' -ForEach @(
        @{ Key = 'quickFormat'; Argument = 'QuickFormat'; Value = $false; Written = 'False' }
        @{ Key = 'bootable'; Argument = 'Bootable'; Value = $true; Written = 'True' }
        @{ Key = 'bootable'; Argument = 'Bootable'; Value = $false; Written = 'False' }
    ) {
        $wantedKey = $Key
        $wantedValue = $Value

        $argument = @{ $Argument = $Value }

        $after = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size 1GB @argument

        $row = @(Get-HDTTestPartition -Line $after)[-1]

        $row.Contains($wantedKey) | Should -BeTrue
        [bool] $row[$wantedKey] | Should -Be $wantedValue
    }

    It 'lets Edit clear one that was set' {
        $with = Add-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size 1GB -Bootable $true

        @(Get-HDTTestPartition -Line $with)[-1].Contains('bootable') | Should -BeTrue

        $without = Set-HDTStepPartition -Line $with -Name 'Format and Partition' `
            -Partition 'Data' -Type Primary -Size 1GB

        @(Get-HDTTestPartition -Line $without)[-1].Contains('bootable') | Should -BeFalse
    }

    It 'still refuses two bootable partitions, at authoring time' {
        # The build refuses it - the firmware picks one and which one is then
        # not the author's decision - so authoring has to refuse it too, or the
        # window writes a document that cannot run.
        $first = Set-HDTStepPartition -Line $script:line -Name 'Format and Partition' `
            -Partition 'System' -Type EFI -Size 260MB -Bootable $true

        { Set-HDTStepPartition -Line $first -Name 'Format and Partition' `
                -Partition 'Windows' -Type Primary -Size remainder -Bootable $true } |
            Should -Throw -ExpectedMessage '*bootable*'
    }
}
