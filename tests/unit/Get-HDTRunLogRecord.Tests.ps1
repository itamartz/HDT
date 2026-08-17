# ONE READER FOR THE JSONL, because the progress window and the failure window
# are both derived from it and two copies of "read the log" is two answers about
# a half-written line.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newContext = {
        param([string] $Text)

        $fs = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 18, 9, 0, 0, [System.DateTimeKind]::Utc))

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -FileSystem $fs -Clock $clock

        if ($null -ne $Text) { $fs.WriteAllText([string] $log.JsonlPath, $Text) }

        return $log
    }
}

Describe 'Get-HDTRunLogRecord' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTRunLogRecord' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'reads every line as a record, oldest first' {
        $context = & $script:newContext "{`"seq`":1,`"event`":`"run.start`"}`n{`"seq`":2,`"event`":`"step.start`"}`n"

        $record = @(Get-HDTRunLogRecord -Context $context)

        $record.Count | Should -Be 2
        [int] $record[0].seq | Should -Be 1
        [string] $record[1].event | Should -BeExactly 'step.start'
    }

    It 'skips a half-written last line rather than throwing' {
        # WHAT A MACHINE THAT DIED MID-STEP LEAVES BEHIND, and precisely the run
        # somebody wants to read.
        $context = & $script:newContext "{`"seq`":1,`"event`":`"run.start`"}`n{`"seq`":2,`"eve"

        $record = @(Get-HDTRunLogRecord -Context $context)

        $record.Count | Should -Be 1
    }

    It 'returns nothing for a log that was never written' {
        @(Get-HDTRunLogRecord -Context (& $script:newContext $null)) | Should -BeNullOrEmpty
    }

    It 'returns nothing rather than throwing for no context at all' {
        # A run that failed before the log context existed still has to reach
        # the tail.
        { Get-HDTRunLogRecord -Context $null } | Should -Not -Throw
        @(Get-HDTRunLogRecord -Context $null) | Should -BeNullOrEmpty
    }

    It 'returns nothing for an object that is not a log context' {
        @(Get-HDTRunLogRecord -Context ([pscustomobject] @{ Nothing = 'here' })) | Should -BeNullOrEmpty
    }
}
