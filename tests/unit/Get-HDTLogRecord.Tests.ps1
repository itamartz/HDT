# Reading HDT.jsonl back out of a fake filesystem.
#
# Every 03-04 assertion about what the loop DID is an assertion about the JSONL
# stream - the ordered step names, the skip reasons, one reboot.arm record, the
# seq continuing across a leg. Each of those otherwise begins with the same four
# lines of split-and-parse, so it lives here once.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTLogRecord' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:00:00Z')
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock -Level Debug

        Write-HDTLog -Context $script:log -Message 'starting' -Event run.start
        Write-HDTLog -Context $script:log -Message 'a warning' -Severity Warning -Event step.skip
        Write-HDTLog -Context $script:log -Message 'ending' -Event run.end
    }

    It 'returns one record per line, in order' {
        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:log.JsonlPath)

        $record.Count | Should -Be 3
        @($record | ForEach-Object { $_.message }) | Should -Be @('starting', 'a warning', 'ending')
    }

    It 'parses the record fields' {
        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:log.JsonlPath)

        $record[0].event | Should -BeExactly 'run.start'
        $record[0].runId | Should -BeExactly 'run-0001'
        $record[0].seq | Should -Be 1
    }

    It 'filters by event' {
        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:log.JsonlPath -Event 'run.start', 'run.end')

        @($record | ForEach-Object { $_.event }) | Should -Be @('run.start', 'run.end')
    }

    It 'filters by severity' {
        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:log.JsonlPath -Severity Warning)

        $record.Count | Should -Be 1
        $record[0].message | Should -BeExactly 'a warning'
    }

    It 'returns nothing for a log that was never written' {
        Get-HDTLogRecord -FileSystem $script:fs -Path 'X:\HDT\Logs\Nothing.jsonl' | Should -BeNullOrEmpty
    }

    It 'returns the raw text as well, so a test can assert a secret is absent' {
        $text = Get-HDTLogRecord -FileSystem $script:fs -Path $script:log.JsonlPath -Raw

        $text | Should -BeLike '*starting*'
        $text | Should -BeLike '*ending*'
    }
}
