#Requires -Modules Pester

# THE PROOF THAT A FAKE-DRIVEN RUN TOUCHED NOTHING REAL, WITHOUT ASSERTING WHAT
# THE MACHINE HAD BEFORE IT STARTED.
#
# The end-to-end suites used to prove it by asserting that C:\HDT\Logs\HDT.jsonl
# does not exist. That is a fact about the machine, not about the run, and it
# stopped being true the day the gate moved onto GHRUNNER01 - a machine HDT
# ITSELF DEPLOYED, whose C:\HDT\Logs holds the log of the deployment that built
# it (run-20260907-072951, written 2026-09-07). The suite was green on the
# author's laptop and red on the runner for being a runner, which is the same
# defect fb3ef00 fixed in the lab-safety guards.
#
# So this tool reads what is there and says so in one comparable line per path.
# The test takes a reading before the run and the same reading after, and the
# assertion is that they are IDENTICAL - which is true on a bare machine, true
# on a machine HDT deployed a year ago, and false the instant a run writes,
# grows or creates any of them. Nothing in it says what a path ought to be.
#
# IT NEVER RETURNS A REGISTRY VALUE'S DATA, only its names. The keys these
# suites watch are Winlogon and RunOnce, and DefaultPassword is exactly the
# thing that must never reach a test failure message
# (tests/contract/SecretRedaction.Contract.Tests.ps1). A name set is enough to
# prove nothing was added.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTRealMachineState' {

    Context 'the filesystem' {

        BeforeAll {
            $script:filePath = Join-Path -Path $TestDrive -ChildPath 'reading.txt'
            $script:directoryPath = Join-Path -Path $TestDrive -ChildPath 'reading-tree'
            $script:absentPath = Join-Path -Path $TestDrive -ChildPath 'never-written.txt'

            Set-Content -LiteralPath $script:filePath -Value 'one' -Encoding ASCII -NoNewline
            [void] (New-Item -Path $script:directoryPath -ItemType Directory -Force)
        }

        It 'reports a path that does not exist as absent' {
            $state = @(Get-HDTRealMachineState -Path $script:absentPath)

            $state.Count | Should -Be 1
            $state[0].Path | Should -BeExactly $script:absentPath
            $state[0].State | Should -BeExactly 'absent'
        }

        It 'reports a file with its size, so a write that grows it shows' {
            $state = @(Get-HDTRealMachineState -Path $script:filePath)

            $state[0].State | Should -BeLike 'file, 3 bytes, modified *'
        }

        It 'reports a different reading once the file is appended to' {
            $before = @(Get-HDTRealMachineState -Path $script:filePath)[0].State

            Add-Content -LiteralPath $script:filePath -Value 'two' -Encoding ASCII -NoNewline

            $after = @(Get-HDTRealMachineState -Path $script:filePath)[0].State

            # THE WHOLE POINT OF THE TOOL. A reading that did not move when the
            # file did would pass every "it touched nothing real" assertion for
            # a run that wrote to the real disk.
            $after | Should -Not -BeExactly $before
        }

        It 'reports the same reading twice when nothing happened in between' {
            $first = @(Get-HDTRealMachineState -Path $script:directoryPath)[0].State
            $second = @(Get-HDTRealMachineState -Path $script:directoryPath)[0].State

            $second | Should -BeExactly $first
        }

        It 'tells a directory from a file' {
            $file = @(Get-HDTRealMachineState -Path $script:filePath)[0].State
            $directory = @(Get-HDTRealMachineState -Path $script:directoryPath)[0].State

            $file | Should -BeLike 'file,*'
            $directory | Should -BeLike 'directory,*'
        }

        It 'returns one reading per path, in the order it was given them' {
            $state = @(Get-HDTRealMachineState -Path @($script:absentPath, $script:filePath, $script:directoryPath))

            @($state | ForEach-Object { $_.Path }) | Should -Be @($script:absentPath, $script:filePath, $script:directoryPath)
            $state[0].State | Should -BeExactly 'absent'
        }

        It 'accepts paths from the pipeline' {
            $state = @(@($script:absentPath, $script:filePath) | Get-HDTRealMachineState)

            $state.Count | Should -Be 2
        }
    }

    Context 'a drive that is not on this machine' {

        It 'reports absent rather than throwing' {
            # X:\ IS THE ONE THAT MATTERS: the WinPE leg of every end-to-end
            # suite logs to X:\HDT\Logs, and X: is a RAM disk that exists in
            # WinPE and nowhere else. A tool that threw on an unmounted drive
            # could not be used to watch that path at all - and the free letter
            # is computed rather than named, because any letter is somebody's
            # mapped drive somewhere.
            $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
            $free = @([char[]] 'QRSTUVWXYZ' | Where-Object { $used -notcontains [string] $_ })[0]

            $free | Should -Not -BeNullOrEmpty -Because 'the machine cannot have every drive letter in use'

            $probe = '{0}:\HDT\Logs\HDT.jsonl' -f $free

            # Assigned OUTSIDE the scriptblock: a variable set inside the one
            # Should -Not -Throw runs belongs to that scriptblock's scope and is
            # still $null out here, which reads as a tool that returned nothing.
            { Get-HDTRealMachineState -Path $probe | Out-Null } | Should -Not -Throw

            $state = @(Get-HDTRealMachineState -Path $probe)

            $state[0].State | Should -BeExactly 'absent'
        }
    }

    Context 'the registry' {

        It 'reports a key by its value names' {
            # HKCU:\Environment, read-only: it exists on every Windows profile
            # and always carries TEMP. Nothing here writes to the real registry.
            $state = @(Get-HDTRealMachineState -Path 'HKCU:\Environment')

            $state[0].State | Should -BeLike 'registry key, values: *'
            $state[0].State | Should -BeLike '*TEMP*'
        }

        It 'never reports a registry value data' {
            # The keys the end-to-end suites watch are Winlogon and RunOnce, and
            # DefaultPassword is the value whose DATA must never reach a failure
            # message. Names prove a value was added; data would leak one.
            $data = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'TEMP').TEMP

            $state = @(Get-HDTRealMachineState -Path 'HKCU:\Environment')

            $data | Should -Not -BeNullOrEmpty
            $state[0].State | Should -Not -BeLike ('*{0}*' -f $data)
        }

        It 'reports a key that is not there as absent' {
            $state = @(Get-HDTRealMachineState -Path 'HKCU:\Software\HDT-No-Such-Key-For-A-Test')

            $state[0].State | Should -BeExactly 'absent'
        }
    }

    Context 'the contract of the tool itself' {

        It 'refuses an empty path list' {
            { Get-HDTRealMachineState -Path @() } | Should -Throw
        }
    }
}
