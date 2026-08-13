# The IProcessService contract (PROJECT constraint 4, DESIGN 12.2.1).
#
# DESIGN 12.1: "native tool exit codes are checked explicitly; $LASTEXITCODE is
# never assumed to be zero". Every native invocation in HDT therefore goes
# through this one method, which returns the exit code as DATA rather than
# leaving it in an automatic variable somebody has to remember to read.
#
#   Start($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond)
#     -> ExitCode, StandardOutput, StandardError, TimedOut, DurationMs
#
#   TimeoutMillisecond 0 = unbounded. On timeout the process is KILLED, TimedOut
#   is $true and ExitCode is -1, because a step that hung must not leave the
#   process behind for the next one to trip over.
#
# Both implementations pass this file unchanged. The real row runs cmd.exe, which
# exists on every Windows machine the engine will ever run on, including WinPE.

$script:HDTImplementation = @(
    @{
        Name    = 'FakeProcessService'
        Factory = {
            New-HDTFakeProcessService -Result @{
                'cmd.exe /c exit 3'                = @{ ExitCode = 3 }
                'cmd.exe /c echo hdt-ok'           = @{ ExitCode = 0; StandardOutput = 'hdt-ok' }
                'cmd.exe /c ping -n 5 127.0.0.1'   = @{ ExitCode = -1; TimedOut = $true }
                'cmd.exe /c exit 0'                = @{ ExitCode = 0 }
            }
        }
        Skip    = $false
    }
    @{
        Name    = 'ProcessService'
        Factory = { New-HDTProcessService }
        Skip    = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }
)

Describe 'IProcessService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    # -Skip goes on the Context, never on the Describe: -Skip is bound where
    # Describe is called, before -ForEach binds the row's keys, so a row marked
    # Skip = $true would run anyway and silently (README F9).
    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:process = & $Factory $script:repoRoot
        }

        It 'exposes Start' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            @($script:process | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name }) |
                Should -Contain 'Start'
        }

        It 'returns ExitCode, StandardOutput, StandardError, TimedOut and DurationMs' {
            $result = $script:process.Start('cmd.exe', '/c exit 0', '', 0)

            $name = @($result.PSObject.Properties.Name)
            foreach ($expected in @('ExitCode', 'StandardOutput', 'StandardError', 'TimedOut', 'DurationMs')) {
                $name | Should -Contain $expected
            }
        }

        It 'returns the exit code of a command that fails' {
            $script:process.Start('cmd.exe', '/c exit 3', '', 0).ExitCode | Should -Be 3
        }

        It 'captures standard output' {
            $script:process.Start('cmd.exe', '/c echo hdt-ok', '', 0).StandardOutput.Trim() |
                Should -BeExactly 'hdt-ok'
        }

        It 'treats a zero timeout as unbounded' {
            $result = $script:process.Start('cmd.exe', '/c exit 0', '', 0)

            $result.TimedOut | Should -BeFalse
            $result.ExitCode | Should -Be 0
        }

        It 'reports TimedOut for a command that outruns its timeout' {
            $result = $script:process.Start('cmd.exe', '/c ping -n 5 127.0.0.1', '', 300)

            $result.TimedOut | Should -BeTrue
            $result.ExitCode | Should -Be -1
        }

        It 'records Start before it can throw' {
            $script:process.Start('cmd.exe', '/c exit 0', '', 0) | Out-Null

            @($script:process.GetOperationName()) | Should -Be @('Start')
        }

        It 'records the arguments of each Start' {
            $script:process.Start('cmd.exe', '/c exit 0', 'C:\', 0) | Out-Null

            @($script:process.Operations[0].Arguments) | Should -Be @('cmd.exe', '/c exit 0', 'C:\', 0)
        }
    }

    Context 'the journal' -Skip:$Skip {

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $service = & $Factory $script:repoRoot
            $service.Journal = $journal

            $service.Start('cmd.exe', '/c exit 0', '', 0) | Out-Null

            @($journal).Count | Should -Be 1
            $journal[0].Service | Should -BeExactly 'ProcessService'
            $journal[0].Operation | Should -BeExactly 'Start'
        }
    }
}
