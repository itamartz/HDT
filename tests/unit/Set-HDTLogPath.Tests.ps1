# DESIGN 4.4.1's relocation - the piece phase 04 deliberately deferred and
# recorded in commit 3979b26.
#
# WHY IT MATTERS, IN ONE SENTENCE: a deployment that dies in WinPE loses its log
# at the reboot, and dying in WinPE is exactly when the log is wanted. X: is a
# RAM disk. The moment a real volume is formatted there is somewhere for the log
# to live that will still exist tomorrow, and DESIGN 4.4.1 says the log goes
# there.
#
# IT IS A MIRROR, NOT A MOVE. The RAM-disk copy stays: a relocation that deleted
# the only log and then failed would be worse than no relocation at all.
#
# AND IT NEVER THROWS. A target volume that cannot be written - full, not
# formatted after all, a letter that went away - produces a warning through the
# OLD context and leaves everything pointing at X:. Losing the logs is not an
# acceptable price for moving the logs.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winPeLog = 'X:\HDT\Logs'
    $script:targetLog = 'W:\HDT\Logs'

    # A log context that has already written a run's worth of records, with the
    # tree DESIGN 4.4.2's directory listing describes.
    $script:newContext = {
        param([hashtable] $WriteFailure)

        $argument = @{}
        if ($null -ne $WriteFailure) { $argument['WriteFailure'] = $WriteFailure }

        $fileSystem = New-HDTFakeFileSystem @argument
        $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:09:26Z')

        $context = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath $script:winPeLog `
            -FileSystem $fileSystem -Clock $clock -Level Debug -ThreadId 1

        # Written, not seeded, so the tree is the one the engine would have left.
        Write-HDTLog -Context $context -Event 'run.start' -Message 'Run run-0001 starting'
        Write-HDTLog -Context $context -Message 'partitioning'

        $fileSystem.WriteAllText('X:\HDT\Logs\status.json', '{"status":"Running"}')
        $fileSystem.WriteAllText('X:\HDT\Logs\Steps\003-ApplyImage.dism.log', 'DISM 100%')
        $fileSystem.WriteAllText('X:\HDT\Logs\Gather\facts.json', '{"HDTModel":"Virtual Machine"}')
        $fileSystem.WriteAllText('X:\HDT\Logs\Native\bcdboot.log', 'exit 0')

        return [pscustomobject] @{
            Log        = $context
            FileSystem = $fileSystem
            Clock      = $clock
        }
    }

    $script:recordOf = {
        param([object] $FileSystem, [string] $Path)

        return @(Get-HDTLogRecord -FileSystem $FileSystem -Path $Path)
    }
}

Describe 'Set-HDTLogPath' {

    Context 'the move' {

        It 'returns the path Get-HDTLogPath computes for the target volume' {
            $harness = & $script:newContext

            $moved = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $moved | Should -BeExactly (Get-HDTLogPath -Phase WinPE -TargetVolume 'W:')
            $moved | Should -BeExactly $script:targetLog
        }

        It 'accepts W: and W:\ as the same volume' {
            $harness = & $script:newContext

            Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:\' | Should -BeExactly $script:targetLog
        }

        It 'accepts the bare drive letter the partition step publishes' {
            # HDTOSVolume IS 'W', NOT 'W:'. Invoke-HDTDiskPartitionStep publishes
            # a bare letter and the imaging benchmark asserts exactly that, so a
            # relocation that took the value literally would write its logs to a
            # RELATIVE path called W - on the RAM disk, which is the one place
            # they must not stay.
            $harness = & $script:newContext

            Set-HDTLogPath -Context $harness.Log -TargetVolume 'W' | Should -BeExactly $script:targetLog
        }

        It 'creates the destination' {
            $harness = & $script:newContext

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $harness.FileSystem.TestPath($script:targetLog) | Should -BeTrue
        }

        It 'repoints LogPath, JsonlPath and MasterLogPath' {
            $harness = & $script:newContext

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $harness.Log.LogPath | Should -BeExactly $script:targetLog
            $harness.Log.JsonlPath | Should -BeExactly 'W:\HDT\Logs\HDT.jsonl'
            $harness.Log.MasterLogPath | Should -BeExactly 'W:\HDT\Logs\HDT.log'
        }

        It 'repoints the step log so a step mid-flight keeps one log, not two' {
            $harness = & $script:newContext
            $harness.Log.SetStep(2, 'Format and Partition', 'DiskPartition', 'X:\HDT\Logs\Steps\002-Format-and-Partition.log')

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $harness.Log.StepLogPath | Should -BeExactly 'W:\HDT\Logs\Steps\002-Format-and-Partition.log'
        }

        It 'sets _HDTLogPath in the variable dictionary when one is given' {
            # DESIGN 4.4.1: the engine variable is read-only TO SEQUENCES AND
            # RULES; the engine itself is what sets it, which is what the leading
            # underscore means.
            $harness = & $script:newContext
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:' -Variable $variable

            [string] $variable['_HDTLogPath'] | Should -BeExactly $script:targetLog
        }

        It 'does not touch Seq' {
            # DESIGN 4.4.2's counter is monotonic across the WHOLE run, and a
            # reset here would be exactly the ambiguity it exists to prevent.
            $harness = & $script:newContext
            $before = [long] $harness.Log.Seq

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            # One record for the relocation itself, and not one number more.
            [long] $harness.Log.Seq | Should -Be ($before + 1)
        }

        It 'is idempotent when the context is already there' {
            $harness = & $script:newContext
            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $seqAfterFirst = [long] $harness.Log.Seq
            $countAfterFirst = @($harness.FileSystem.Operations).Count

            Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:' | Should -BeExactly $script:targetLog

            [long] $harness.Log.Seq | Should -Be $seqAfterFirst
            @($harness.FileSystem.Operations).Count | Should -Be $countAfterFirst
        }

        It 'writes a message record naming both paths' {
            $harness = & $script:newContext

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $record = & $script:recordOf $harness.FileSystem 'W:\HDT\Logs\HDT.jsonl'
            $relocation = @($record | Where-Object { $_.msg -like '*W:\HDT\Logs*' })

            $relocation.Count | Should -BeGreaterOrEqual 1
            [string] $relocation[-1].msg | Should -BeLike '*X:\HDT\Logs*'
            [string] $relocation[-1].msg | Should -BeLike '*W:\HDT\Logs*'
        }

        It 'writes that record into the NEW file' {
            # The first line in the new file explains why the file exists.
            $harness = & $script:newContext
            $before = @(& $script:recordOf $harness.FileSystem 'X:\HDT\Logs\HDT.jsonl').Count

            $null = Set-HDTLogPath -Context $harness.Log -TargetVolume 'W:'

            $old = @(& $script:recordOf $harness.FileSystem 'X:\HDT\Logs\HDT.jsonl')
            $new = @(& $script:recordOf $harness.FileSystem 'W:\HDT\Logs\HDT.jsonl')

            # The RAM disk copy is frozen at the moment of the mirror.
            $old.Count | Should -Be $before
            $new.Count | Should -Be ($before + 1)
        }
    }

    Context 'what it carries across' {

        BeforeEach {
            $script:harness = & $script:newContext
            $null = Set-HDTLogPath -Context $script:harness.Log -TargetVolume 'W:'
        }

        It 'copies HDT.jsonl and HDT.log' {
            $script:harness.FileSystem.TestPath('W:\HDT\Logs\HDT.jsonl') | Should -BeTrue
            $script:harness.FileSystem.TestPath('W:\HDT\Logs\HDT.log') | Should -BeTrue
        }

        It 'copies status.json' {
            $script:harness.FileSystem.ReadAllText('W:\HDT\Logs\status.json') | Should -BeExactly '{"status":"Running"}'
        }

        It 'copies the Steps folder with its structure' {
            # Steps\003-ApplyImage.dism.log arrives at the same RELATIVE path,
            # not flattened into a directory of clashing names.
            $script:harness.FileSystem.ReadAllText('W:\HDT\Logs\Steps\003-ApplyImage.dism.log') |
                Should -BeExactly 'DISM 100%'
        }

        It 'copies Gather and Native' {
            $script:harness.FileSystem.TestPath('W:\HDT\Logs\Gather\facts.json') | Should -BeTrue
            $script:harness.FileSystem.TestPath('W:\HDT\Logs\Native\bcdboot.log') | Should -BeTrue
        }

        It 'leaves the RAM disk copy in place' {
            # IT IS A MIRROR. A move that failed halfway would have destroyed the
            # only copy of the log it was called to preserve.
            foreach ($path in @('X:\HDT\Logs\HDT.jsonl', 'X:\HDT\Logs\HDT.log',
                    'X:\HDT\Logs\status.json', 'X:\HDT\Logs\Steps\003-ApplyImage.dism.log')) {

                $script:harness.FileSystem.TestPath($path) | Should -BeTrue -Because "$path is the copy that must not be destroyed"
            }
        }

        It 'carries the history, so the WinPE records are on the volume that survives' {
            $new = @(& $script:recordOf $script:harness.FileSystem 'W:\HDT\Logs\HDT.jsonl')

            @($new | Where-Object { $_.event -eq 'run.start' }).Count | Should -Be 1
            @($new | Where-Object { $_.msg -eq 'partitioning' }).Count | Should -Be 1
        }
    }

    Context 'when it cannot' {

        BeforeEach {
            # The destination that cannot be written: full, not formatted after
            # all, or a letter that went away.
            $script:broken = & $script:newContext -WriteFailure @{
                'W:\HDT\Logs\HDT.jsonl' = 'There is not enough space on the disk.'
            }
        }

        It 'never throws when the destination cannot be written' {
            { Set-HDTLogPath -Context $script:broken.Log -TargetVolume 'W:' -WarningAction SilentlyContinue } |
                Should -Not -Throw
        }

        It 'returns the old path' {
            $moved = Set-HDTLogPath -Context $script:broken.Log -TargetVolume 'W:' -WarningAction SilentlyContinue

            $moved | Should -BeExactly $script:winPeLog
        }

        It 'keeps logging to the old path' {
            $null = Set-HDTLogPath -Context $script:broken.Log -TargetVolume 'W:' -WarningAction SilentlyContinue

            $script:broken.Log.LogPath | Should -BeExactly $script:winPeLog
            $script:broken.Log.JsonlPath | Should -BeExactly 'X:\HDT\Logs\HDT.jsonl'
            $script:broken.Log.MasterLogPath | Should -BeExactly 'X:\HDT\Logs\HDT.log'
        }

        It 'writes a warning naming the target volume and the reason' {
            $null = Set-HDTLogPath -Context $script:broken.Log -TargetVolume 'W:' -WarningAction SilentlyContinue

            $record = @(& $script:recordOf $script:broken.FileSystem 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' })

            $record.Count | Should -BeGreaterOrEqual 1
            [string] $record[-1].msg | Should -BeLike '*W:\HDT\Logs*'
            [string] $record[-1].msg | Should -BeLike '*not enough space*'
        }

        It 'leaves _HDTLogPath alone' {
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $null = Set-HDTLogPath -Context $script:broken.Log -TargetVolume 'W:' `
                -Variable $variable -WarningAction SilentlyContinue

            $variable.Contains('_HDTLogPath') | Should -BeFalse
        }
    }

    Context 'the command itself' {

        It 'is exported with comment-based help' {
            $help = Get-Help -Name Set-HDTLogPath -ErrorAction Stop

            $help.Name | Should -BeExactly 'Set-HDTLogPath'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'is listed beside Get-HDTLogPath' {
            @(Get-Command -Module Hephaestus | Where-Object { $_.Name -like '*HDTLogPath' } |
                    ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be @('Get-HDTLogPath', 'Set-HDTLogPath')
        }
    }
}
