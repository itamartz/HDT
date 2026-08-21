# Turning a dead worker process into a sentence an operator can act on.
#
# WHY THIS EXISTS. A sharded ./build.ps1 -Task test run failed with
#
#   BUILD FAILED: worker 1 of 8 did not report a result. Its process died
#   before writing one, so part of the suite did not run.
#
# and the actual cause - an Import-Module that named a path one directory too
# shallow - was sitting in out/testShards/<pid>/err-0.log the whole time, in
# plain English, in every one of the eight logs. The parent captured the file
# and never read it. "Did not report a result" is the symptom; the stderr log is
# the cause, and the two must arrive together or the next failure costs another
# investigation.
#
# THE EXIT CODE IS PART OF THE ANSWER AND NOT A DUPLICATE OF THE LOG. A worker
# that threw writes stderr and exits 1. A worker that was killed - out of
# memory, stack overflow, access violation - writes NOTHING and exits with an
# NTSTATUS. Those are different defects and an empty log cannot tell them apart
# on its own, so the code is reported next to the log and in hex when it is one
# of those, because 0xC0000005 is searchable and -1073741819 is not.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTShardFailureReason' {

    Context 'a worker that threw' {

        It 'carries the standard error the worker wrote' {
            $log = Join-Path -Path $TestDrive -ChildPath 'err-0.log'
            Set-Content -LiteralPath $log -Encoding UTF8 -Value @(
                "Import-Module : The specified module 'C:\repo\tests\src\Hephaestus\Hephaestus.psd1' was not loaded",
                'At C:\repo\tests\helpers\HDTTestShard.ps1:65 char:9')

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode 1

            $reason | Should -BeLike '*tests\src\Hephaestus\Hephaestus.psd1*'
            $reason | Should -BeLike '*HDTTestShard.ps1:65*'
        }

        It 'names the log it read, so the untruncated copy can be opened' {
            $log = Join-Path -Path $TestDrive -ChildPath 'err-3.log'
            Set-Content -LiteralPath $log -Value 'boom' -Encoding UTF8

            Get-HDTShardFailureReason -ErrorPath $log -ExitCode 1 | Should -BeLike '*err-3.log*'
        }

        It 'reports the exit code' {
            $log = Join-Path -Path $TestDrive -ChildPath 'err-4.log'
            Set-Content -LiteralPath $log -Value 'boom' -Encoding UTF8

            Get-HDTShardFailureReason -ErrorPath $log -ExitCode 1 | Should -BeLike '*exit code 1*'
        }
    }

    Context 'a worker that was killed' {

        It 'says the log was empty rather than returning nothing' {
            # An empty stderr IS the diagnosis for a hard kill. Returning ''
            # here would put the build back to "did not report a result".
            $log = Join-Path -Path $TestDrive -ChildPath 'err-5.log'
            Set-Content -LiteralPath $log -Value '' -Encoding UTF8

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode -1073741819

            $reason | Should -BeLike '*empty*'
            $reason | Should -BeLike '*err-5.log*'
        }

        It 'reports an NTSTATUS exit code in hex as well as in decimal' {
            $log = Join-Path -Path $TestDrive -ChildPath 'err-6.log'
            Set-Content -LiteralPath $log -Value '' -Encoding UTF8

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode -1073741819

            $reason | Should -BeLike '*0xC0000005*'
            $reason | Should -BeLike '*-1073741819*'
        }

        It 'says the log was never written when the process never started' {
            $log = Join-Path -Path $TestDrive -ChildPath 'err-never.log'

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode $null

            $reason | Should -BeLike '*never written*'
            $reason | Should -BeLike '*err-never.log*'
        }

        It 'admits it does not know the exit code rather than printing a zero' {
            # A $null ExitCode means Start-Process handed back no process object
            # at all. Reporting that as "exit code 0" would read as a clean exit.
            $log = Join-Path -Path $TestDrive -ChildPath 'err-7.log'
            Set-Content -LiteralPath $log -Value 'boom' -Encoding UTF8

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode $null

            $reason | Should -BeLike '*exit code unknown*'
            $reason | Should -Not -BeLike '*exit code 0*'
        }
    }

    Context 'it stays inside a build log' {

        It 'keeps the tail of a long log and says how much it dropped' {
            # A worker that fails inside a BeforeAll can write one error per test
            # file. The tail is the part that matters - the first error is what
            # killed it only when the log is short.
            $log = Join-Path -Path $TestDrive -ChildPath 'err-long.log'
            Set-Content -LiteralPath $log -Encoding UTF8 -Value @(1..200 | ForEach-Object { 'line {0}' -f $_ })

            $reason = Get-HDTShardFailureReason -ErrorPath $log -ExitCode 1 -MaximumLine 5

            $reason | Should -BeLike '*line 200*'
            $reason | Should -Not -BeLike '*line 3*'
            $reason | Should -BeLike '*195*'
        }

        It 'never throws, whatever it is handed' {
            # It runs on the failure path. A helper that throws there replaces
            # the diagnosis with its own stack trace.
            { Get-HDTShardFailureReason -ErrorPath (Join-Path -Path $TestDrive -ChildPath 'nope\deeper\err.log') -ExitCode 3 } |
                Should -Not -Throw
        }
    }
}
