# TASK SEQUENCE TEMPLATES - MDT'S Templates\Client.xml, IN THIS TOOLKIT.
#
# MDT's New Task Sequence wizard asks which template, then copies that file into
# the new sequence's Control folder. This is the same model: a template is a real
# sequence.yaml on disk, which means it can be opened, read, diffed and edited
# without running anything - and a shop that wants its own standard sequence
# writes one file rather than a plugin.
#
# THE TEMPLATES ARE VALIDATED LIKE ANY OTHER DOCUMENT. A template that does not
# import, or that names a step type the engine cannot run, is a defect that
# would otherwise surface on the first machine somebody deployed with it.

# THE MODULE IS IMPORTED AT DISCOVERY TOO. The -ForEach lists below are built by
# ASKING the toolkit which templates it ships - that is what makes a template
# added tomorrow validated by this suite without anybody editing it - and
# discovery runs before BeforeAll.
BeforeDiscovery {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:discovered = @(Get-HDTSequenceTemplate | ForEach-Object { @{ Id = $_.Id } })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:template = @(Get-HDTSequenceTemplate)
}

Describe 'Get-HDTSequenceTemplate' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTSequenceTemplate' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'offers at least the client one, which is what MDT leads with' {
        @($script:template).Count | Should -BeGreaterOrEqual 1
        @($script:template | ForEach-Object { $_.Id }) | Should -Contain 'client'
    }

    It 'describes each one, because the picker shows the description not the file' {
        foreach ($one in $script:template) {
            $one.Name | Should -Not -BeNullOrEmpty
            $one.Description | Should -Not -BeNullOrEmpty
            $one.Path | Should -Not -BeNullOrEmpty
        }
    }

    It 'reads one back as lines, which is what a new sequence is written from' {
        $line = @(Get-HDTSequenceTemplate -Id client -Line)

        @($line).Count | Should -BeGreaterThan 20
        ($line -join "`n") | Should -BeLike '*type: DiskPartition*'
    }

    It 'refuses a template it does not have, by name' {
        { Get-HDTSequenceTemplate -Id 'no-such-template' -Line } |
            Should -Throw -ExpectedMessage '*no-such-template*'
    }
}

Describe 'every template this toolkit ships' {

    It '<Id> imports as a sequence the engine can read' -ForEach $script:discovered {
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }

        { Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem } |
            Should -Not -Throw
    }

    It '<Id> names only step types the engine can run' -ForEach $script:discovered {
        # A TEMPLATE THAT NAMES A TYPE NOTHING IMPLEMENTS fails on the machine,
        # after the disk has been wiped - which is the worst possible place to
        # discover a typo in a file that ships with the product.
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }
        $document = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem

        $known = @(Get-HDTStepType | ForEach-Object { $_.Type })

        foreach ($step in @($document.Step)) {
            $known | Should -Contain ([string] $step.Type)
        }
    }

    It '<Id> names only disk layouts the engine has' -ForEach $script:discovered {
        # The same failure that shipped in the DiskPartition step template:
        # 'layout: UEFI' parses, looks finished, and refuses on the machine.
        $wanted = $Id

        foreach ($line in @(Get-HDTSequenceTemplate -Id $wanted -Line)) {
            if ($line -notmatch '^\s*layout:\s*(.+?)\s*$') { continue }

            $named = [string] $Matches[1]
            if ($named -match '^["'']?%') { continue }

            { Get-HDTDiskLayout -Name ($named -replace '^["'']|["'']$', '') } | Should -Not -Throw
        }
    }

    It '<Id> writes conditions the engine actually evaluates' -ForEach $script:discovered {
        # A CONDITION THAT CANNOT BE PARSED IS WORSE THAN NONE. It looks
        # deliberate, and the step it guards silently never runs.
        $wanted = $Id
        $line = @(Get-HDTSequenceTemplate -Id $wanted -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($line -join "`n") }
        $document = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem

        foreach ($step in @($document.Step)) {
            if ([string]::IsNullOrWhiteSpace([string] $step.Condition)) { continue }

            { Test-HDTStepCondition -Condition ([string] $step.Condition) `
                    -Variable @{ HDTIsUEFI = $true } } | Should -Not -Throw
        }
    }
}

Describe 'the client template in particular' {

    BeforeAll {
        $script:clientLine = @(Get-HDTSequenceTemplate -Id client -Line)

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\ws\sequence.yaml' = ($script:clientLine -join "`n") }
        $script:client = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fileSystem
    }

    It "carries MDT's phases, in MDT's order" {
        # A technician arriving from Workbench knows which half of a deployment
        # failed from the group it stopped inside.
        $group = @($script:client.Group | Where-Object { @($_.Path).Count -eq 1 } |
                ForEach-Object { $_.Path[0] })

        $group | Should -Be @('Initialization', 'Validation', 'Preinstall', 'Install', 'Postinstall', 'State Restore')
    }

    It 'carries both partition steps, one per firmware' {
        $disk = @($script:client.Step | Where-Object { $_.Type -eq 'DiskPartition' })

        @($disk).Count | Should -Be 2

        # AND EXACTLY ONE OF THEM RUNS on any given machine, which is the whole
        # reason a sequence carries two.
        foreach ($firmware in @($true, $false)) {
            $running = @($disk | Where-Object {
                    Test-HDTStepCondition -Condition ([string] $_.Condition) `
                        -Variable @{ HDTIsUEFI = $firmware }
                })

            @($running).Count | Should -Be 1
        }
    }

    It 'names a disk, as MDT does, so a one-disk machine needs no editing' {
        # MDT's Client.xml sets OSDDiskIndex 0 on both partition steps. A
        # template that named none would leave the commonest machine - one
        # disk - failing at the first destructive step with "which disk".
        $disk = @($script:client.Step | Where-Object { $_.Type -eq 'DiskPartition' })

        foreach ($one in $disk) {
            $one.Property.Contains('diskNumber') | Should -BeTrue
            [string] $one.Property['diskNumber'] | Should -BeExactly '0'
        }
    }

    It 'gathers before anything conditions on what was gathered' {
        # EVERY CONDITION IN THIS SEQUENCE READS A FACT: the firmware that picks
        # a partition step, the TPM the validation checks. A gather that ran
        # after them would be describing a machine whose decisions were already
        # made.
        $order = @($script:client.Step | ForEach-Object { $_.Type })

        [array]::IndexOf($order, 'Gather') | Should -Be 0
    }

    It 'restarts before anything expects Windows to be running' {
        $order = @($script:client.Step | ForEach-Object { $_.Type })

        $restart = [array]::IndexOf($order, 'Restart')
        $apps = [array]::IndexOf($order, 'InstallApplications')

        $restart | Should -BeGreaterThan -1
        $apps | Should -BeGreaterThan $restart
    }
}

Describe 'New-HDTTaskSequence' {

    BeforeEach {
        $script:ws = 'C:\ws'

        $script:fs = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab share`ndeployRoot: \host\share"
        }
    }

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTTaskSequence' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the sequence where the engine looks for it' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $script:fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeTrue
    }

    It 'gives it the id and name it was asked for, not the template''s' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        $document.Id | Should -BeExactly 'WIN11'
        $document.Name | Should -BeExactly 'Windows 11'
    }

    It "keeps the template's comments, which are what a new sequence is read for" {
        # A PARSE AND RE-EMIT WOULD HAND BACK A CORRECT DOCUMENT AND NONE OF THE
        # PROSE. Half the value of MDT's Client.xml is that somebody opening it
        # can see why the steps are in that order - and this file is the first
        # thing an author of a new sequence reads.
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $text = [string] $script:fs.ReadAllText('C:\ws\TaskSequences\WIN11\sequence.yaml')

        $text | Should -BeLike '*THE PAIR, AND ONLY ONE OF THEM RUNS*'
    }

    It 'carries the steps over, so a new sequence is not empty' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        $document = Import-HDTSequenceDocument -Path 'C:\ws\TaskSequences\WIN11\sequence.yaml' `
            -FileSystem $script:fs

        @($document.Step).Count | Should -BeGreaterOrEqual 6
    }

    It 'refuses to write over one that already exists' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -Confirm:$false)

        # A SEQUENCE IS SOMEBODY'S WORK. Recreating one over the top of an
        # edited sequence is the single destructive thing this command could do,
        # and there is no reading of "new" that means "replace".
        { New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Again' `
                -FileSystem $script:fs -Confirm:$false } |
            Should -Throw -ExpectedMessage '*WIN11*'
    }

    It 'refuses a template it does not have' {
        { New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -Template 'no-such-template' -FileSystem $script:fs -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no-such-template*'
    }

    It 'writes nothing under -WhatIf' {
        [void] (New-HDTTaskSequence -Workspace $script:ws -Id 'WIN11' -Name 'Windows 11' `
                -FileSystem $script:fs -WhatIf)

        $script:fs.TestPath('C:\ws\TaskSequences\WIN11\sequence.yaml') | Should -BeFalse
    }
}
