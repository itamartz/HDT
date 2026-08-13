# Behaviour that belongs to the fake IProcessService itself rather than to the
# contract: seeding by command line, key normalisation, recording, and the
# guarantee that no real process is ever started.
#
# THE SEED KEY IS THE COMMAND LINE, 'file arguments' joined by one space, so a
# test reads the way the sequence.yaml it stands for reads:
#
#   New-HDTFakeProcessService -Result @{ 'cmd.exe /c exit 3010' = @{ ExitCode = 3010 } }
#
# AN UNSEEDED COMMAND THROWS System.ComponentModel.Win32Exception, which is what
# Process.Start throws for a missing executable - the error-parity rule in
# tests/helpers/README.md section 5. A fake that returned exit 0 for a command
# nobody seeded would make a typo in a step look like success.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakeProcessService' {

    It 'returns the seeded exit code' {
        $process = New-HDTFakeProcessService -Result @{ 'cmd.exe /c exit 3010' = @{ ExitCode = 3010 } }

        $process.Start('cmd.exe', '/c exit 3010', '', 0).ExitCode | Should -Be 3010
    }

    It 'returns the seeded standard output and error' {
        $process = New-HDTFakeProcessService -Result @{
            'setup.exe /q' = @{ ExitCode = 0; StandardOutput = 'installed'; StandardError = 'a warning' }
        }

        $result = $process.Start('setup.exe', '/q', '', 0)

        $result.StandardOutput | Should -BeExactly 'installed'
        $result.StandardError | Should -BeExactly 'a warning'
    }

    It 'defaults TimedOut to false' {
        $process = New-HDTFakeProcessService -Result @{ 'setup.exe /q' = @{ ExitCode = 0 } }

        $process.Start('setup.exe', '/q', '', 0).TimedOut | Should -BeFalse
    }

    It 'returns a seeded TimedOut' {
        $process = New-HDTFakeProcessService -Result @{
            'ping.exe -n 5 127.0.0.1' = @{ ExitCode = -1; TimedOut = $true }
        }

        $result = $process.Start('ping.exe', '-n 5 127.0.0.1', '', 300)

        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -Be -1
    }

    It 'returns a DurationMs' {
        $process = New-HDTFakeProcessService -Result @{ 'setup.exe /q' = @{ ExitCode = 0; DurationMs = 1500 } }

        $process.Start('setup.exe', '/q', '', 0).DurationMs | Should -Be 1500
    }

    It 'matches the seed key case-insensitively' {
        $process = New-HDTFakeProcessService -Result @{ 'CMD.EXE /c exit 0' = @{ ExitCode = 0 } }

        $process.Start('cmd.exe', '/c exit 0', '', 0).ExitCode | Should -Be 0
    }

    It 'matches on file and arguments joined by one space' {
        $process = New-HDTFakeProcessService -Result @{ 'setup.exe /q /norestart' = @{ ExitCode = 0 } }

        $process.Start('setup.exe', '/q /norestart', 'C:\ws', 0).ExitCode | Should -Be 0
    }

    It 'trims a trailing space when there are no arguments' {
        $process = New-HDTFakeProcessService -Result @{ 'notepad.exe' = @{ ExitCode = 0 } }

        $process.Start('notepad.exe', '', '', 0).ExitCode | Should -Be 0
    }

    It 'throws Win32Exception for a command that was not seeded' {
        $process = New-HDTFakeProcessService

        { $process.Start('nosuchtool.exe', '', '', 0) } |
            Should -Throw -ExceptionType ([System.ComponentModel.Win32Exception])
    }

    It 'names the command in that error' {
        $process = New-HDTFakeProcessService

        { $process.Start('nosuchtool.exe', '/x', '', 0) } | Should -Throw -ExpectedMessage '*nosuchtool.exe /x*'
    }

    It 'records Start with all four arguments' {
        $process = New-HDTFakeProcessService -Result @{ 'setup.exe /q' = @{ ExitCode = 0 } }

        $process.Start('setup.exe', '/q', 'C:\ws', 120000) | Out-Null

        $process.GetOperationName() | Should -Be @('Start')
        @($process.Operations[0].Arguments) | Should -Be @('setup.exe', '/q', 'C:\ws', 120000)
    }

    It 'records Start before it can throw' {
        # Query order is evidence about what the code under test TRIED
        # (tests/helpers/README.md section 4).
        $process = New-HDTFakeProcessService

        try { $process.Start('nosuchtool.exe', '', '', 0) } catch { $null = $_ }

        $process.GetOperationName() | Should -Be @('Start')
    }

    It 'never starts a real process' {
        $before = @(Get-Process -Name notepad -ErrorAction SilentlyContinue).Count
        $process = New-HDTFakeProcessService

        $threw = $false
        try { $process.Start('notepad.exe', '', '', 0) } catch { $threw = $true }

        $threw | Should -BeTrue
        @(Get-Process -Name notepad -ErrorAction SilentlyContinue).Count | Should -Be $before
    }
}
