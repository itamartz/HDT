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

                # A PROCESS THAT TAKES ABOUT THREE SECONDS. ping -n 4 sends four
                # packets a second apart, which is the cheapest wait that exists
                # on every Windows machine including WinPE - and long enough that
                # a 500 ms poll ticks several times.
                #
                # TickCount IS WHAT THE FAKE CANNOT OTHERWISE KNOW. The real
                # adapter ticks because time passes; a fake returns instantly, so
                # the number of ticks a real WaitForExit would have produced has
                # to be seeded. Six is the conservative floor for three seconds
                # at two hertz.
                'cmd.exe /c ping -n 4 127.0.0.1'   = @{ ExitCode = 0; TickCount = 6 }
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

    # THE HALF OF THE HEARTBEAT THAT A FAKE CANNOT PROVE.
    #
    # THE ENGINE IS WINDOWS POWERSHELL 5.1 AND SINGLE-THREADED. ForEach-Object
    # -Parallel is forbidden in WinPE and there is no second thread to write from,
    # so a step that BLOCKS on a child process cannot emit anything while it
    # blocks - and Start blocked, on a bare WaitForExit(), for the whole of every
    # MSI a deployment ever ran. That is the defect: "Install Applications" wrote
    # "installing 1 of 2" at 16:13:41 and its next record at 16:15:38, and for
    # those one hundred and seventeen seconds the progress card's elapsed clock -
    # which is derived from record timestamps - did not move at all.
    #
    # SO Start POLLS RATHER THAN BLOCKS, which is exactly MDT's shape:
    # ZTIUtility.vbs's RunCommandLog launches with WshShell.Exec and spins on
    # oExec.Status with SafeSleep 100 (lines 2173-2201) rather than calling
    # oShell.Run(cmd, 0, True). MDT was right, and PSD - which uses
    # Start-Process -Wait everywhere (PSDUtility.psm1:1170) - has the freeze this
    # is fixing.
    #
    # AND IT IS PINNED HERE, ON THE REAL ADAPTER, AGAINST A REAL CHILD PROCESS.
    # A unit test in which a hand-written fake calls a callback proves that the
    # callback is called; it proves nothing whatever about whether a real
    # WaitForExit would ever have let it. The row below runs cmd.exe and waits
    # for it, on the machine running the suite.
    Context 'the tick that keeps a long process from looking hung' -Skip:$Skip {

        It 'invokes OnTick repeatedly while the process is still running' {
            # A HASHTABLE, NOT A CLOSED-OVER INTEGER. GetNewClosure captures by
            # value, so a scriptblock invoked from inside a ScriptMethod cannot
            # assign to the caller's [int] - the count would read zero and the
            # test would fail for a reason that is not the one it is about.
            $counted = @{ Tick = 0 }
            $counter = { $counted['Tick'] = [int] $counted['Tick'] + 1 }.GetNewClosure()

            $result = $script:process.Start('cmd.exe', '/c ping -n 4 127.0.0.1', '', 0, $counter)

            $result.ExitCode | Should -Be 0
            [int] $counted['Tick'] | Should -BeGreaterOrEqual 2 -Because (
                'a process that runs for three seconds must give the engine several chances to say so. ' +
                'Zero here means Start is blocking again, and every long step is silent for its whole duration.')
        }

        It 'does not invoke OnTick for a process that returns at once' {
            $counted = @{ Tick = 0 }
            $counter = { $counted['Tick'] = [int] $counted['Tick'] + 1 }.GetNewClosure()

            $script:process.Start('cmd.exe', '/c exit 0', '', 0, $counter) | Out-Null

            # A STEP THAT TAKES 200 ms MUST COST THE LOG NOTHING. The poll waits
            # a full interval before it looks, so a process that has already gone
            # is never ticked at all.
            [int] $counted['Tick'] | Should -Be 0
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
