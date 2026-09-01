# The CommandLine step runs a native command, and it is where DESIGN 12.1's
# "native tool exit codes are checked explicitly; $LASTEXITCODE is never assumed
# to be zero" actually lives.
#
# Classification is DATA, not convention:
#
#   successCodes  default [0]      -> Completed
#   rebootCodes   default [3010]   -> RebootRequested
#   anything else                  -> Failed, naming the code
#
# rebootCodes WINS when a code is in both lists. That is stated as a decision
# here rather than left to whichever check happened to run first, because 3010
# from an installer that also lists it as success is a real configuration.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property, [int] $TimeoutMinutes)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'CommandLine'
            TimeoutMinutes = $TimeoutMinutes
            Log            = $null
            Property       = $bag
        }
    }

    $script:jsonlRecord = {
        param($FileSystem)

        $text = ''
        if ($FileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $FileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }

    # One context, built at whatever log level the test needs.
    $script:newContext = {
        param([string] $Level, $Process, $Environment)

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))

        $catalogArgument = @{
            FileSystem = $script:fileSystem
            Clock      = $script:clock
            Process    = $Process
        }
        if ($null -ne $Environment) {
            $catalogArgument['Environment'] = $Environment
        }

        $catalog = New-HDTServiceCatalog @catalogArgument

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level $Level

        $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
            -Variable $variable -Service $catalog -Log $log
        $context.SetStep(1, 'Install the thing', 'CommandLine', 'C:\HDT\Logs\Steps\001-Install.log')

        return $context
    }
}

Describe 'Invoke-HDTCommandLineStep' {

    BeforeEach {
        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }
        $script:process = New-HDTFakeProcessService -Result @{
            'setup.exe /q /norestart'                   = @{ ExitCode = 0; StandardOutput = 'installed cleanly' }
            'setup.exe /reboot'                         = @{ ExitCode = 3010 }
            'setup.exe /broken'                         = @{ ExitCode = 87 }
            'setup.exe /slow'                           = @{ ExitCode = -1; TimedOut = $true }
            'cmd.exe /c echo hello'                     = @{ ExitCode = 0; StandardOutput = 'hello' }
            'cmd.exe /c setup.exe /secret-argument'     = @{ ExitCode = 0 }
        }

        $script:context = & $script:newContext 'Info' $script:process $script:environment
    }

    Context 'starting the process' {

        It 'starts the file and arguments it was given' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations[0].Arguments)[0] | Should -BeExactly 'setup.exe'
            @($script:process.Operations[0].Arguments)[1] | Should -BeExactly '/q /norestart'
        }

        It 'runs a command property through the comspec' {
            # MDT's Run Command Line behaviour: `command:` is a shell line, so
            # redirection and built-ins work the way an administrator expects.
            $step = & $script:newStep 'Say hello' ([ordered] @{ command = 'echo hello' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations[0].Arguments)[0] | Should -BeExactly 'cmd.exe'
            @($script:process.Operations[0].Arguments)[1] | Should -BeExactly '/c echo hello'
        }

        It 'falls back to cmd.exe when the catalog has no environment provider' {
            $context = & $script:newContext 'Info' $script:process $null
            $step = & $script:newStep 'Say hello' ([ordered] @{ command = 'echo hello' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $context | Out-Null

            @($script:process.Operations[0].Arguments)[0] | Should -BeExactly 'cmd.exe'
        }

        It 'passes the working directory' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{
                    file = 'setup.exe'; arguments = '/q /norestart'; workingDirectory = 'C:\Deploy\Applications'
                }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations[0].Arguments)[2] | Should -BeExactly 'C:\Deploy\Applications'
        }

        It 'converts timeoutMinutes into milliseconds' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 2

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations[0].Arguments)[3] | Should -Be 120000
        }

        It 'passes zero for no timeout' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations[0].Arguments)[3] | Should -Be 0
        }

        It 'starts no real process' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            @($script:process.Operations).Count | Should -Be 1
        }
    }

    Context 'exit code classification' {

        It 'returns Completed for exit code zero' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'returns Completed for a code in successCodes' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{
                    file = 'setup.exe'; arguments = '/broken'; successCodes = @(0, 87)
                }) 0

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'returns RebootRequested for a code in rebootCodes' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/reboot' }) 0

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Status | Should -BeExactly 'RebootRequested'
        }

        It 'prefers rebootCodes when a code is in both lists' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{
                    file = 'setup.exe'; arguments = '/reboot'; successCodes = @(0, 3010); rebootCodes = @(3010)
                }) 0

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Status | Should -BeExactly 'RebootRequested'
        }

        It 'returns Failed naming the exit code for anything else' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/broken' }) 0

            $result = Invoke-HDTCommandLineStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.ExitCode | Should -Be 87
            $result.Message | Should -BeLike '*87*'
        }

        It 'returns the exit code on a successful result too' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/reboot' }) 0

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).ExitCode | Should -Be 3010
        }

        It 'returns Failed when the process timed out' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/slow' }) 1

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Status | Should -BeExactly 'Failed'
        }

        It 'says it timed out in the message' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/slow' }) 1

            (Invoke-HDTCommandLineStep -Step $step -Context $script:context).Message | Should -BeLike '*timed out*'
        }

        It 'fails rather than throwing when no command was given' {
            $step = & $script:newStep 'Install nothing' $null 0

            $result = $null
            $record = $null
            try { $result = Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $record = $_ }

            $record | Should -BeNullOrEmpty
            $result.Status | Should -BeExactly 'Failed'
        }
    }

    Context 'logging' {

        It 'logs a native.exec record with the exit code' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/broken' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'native.exec' })

            $record.Count | Should -BeGreaterThan 0
            $record[0].data.exitCode | Should -Be 87
        }

        It 'logs the full command line only at Debug level' {
            # DESIGN 4.4.5: Debug adds every native command line executed in
            # full. At Info the arguments stay out of the log, because they
            # routinely carry credentials.
            $step = & $script:newStep 'Install the thing' ([ordered] @{ command = 'setup.exe /secret-argument' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null
            [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl'] | Should -Not -BeLike '*secret-argument*'

            $debugContext = & $script:newContext 'Debug' $script:process $script:environment
            Invoke-HDTCommandLineStep -Step $step -Context $debugContext | Out-Null
            [string] $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl'] | Should -BeLike '*secret-argument*'
        }

        It 'writes the captured output into the step log' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            Invoke-HDTCommandLineStep -Step $step -Context $script:context | Out-Null

            [string] $script:fileSystem.File['C:\HDT\Logs\Steps\001-Install.log'] |
                Should -BeLike '*installed cleanly*'
        }

        It 'asks the catalog for the process service by name' {
            $bareFileSystem = New-HDTFakeFileSystem
            $bareClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))
            $bare = New-HDTServiceCatalog -FileSystem $bareFileSystem -Clock $bareClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $bareFileSystem -Clock $bareClock
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
                -Variable $variable -Service $bare -Log $log

            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            $record = $null
            try { Invoke-HDTCommandLineStep -Step $step -Context $context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Process*'
            $record.Exception.Message | Should -BeLike '*CommandLine step*'
        }
    }

    Context 'variable expansion' {

        # THE STEP USED TO BE ONE OF TWO THAT DID NOT EXPAND ANYTHING. Every
        # other step type reads its properties through Get-HDTStepProperty
        # -Expand, so `command: echo %HDTOSVolume%` was measured reaching the
        # process service as the literal string - an author who had written a
        # dozen sequences against the other eighteen step types had no reason to
        # expect it.

        It 'expands %Var% in command' {
            $script:context.Variable['HDTOSVolume'] = 'W:'
            $step = & $script:newStep 'Stamp the volume' ([ordered] @{ command = 'echo %HDTOSVolume%' }) 0

            # The fake refuses a command line nobody seeded, which is what a real
            # Process.Start does for a missing executable. It records the call
            # before it throws, and the recorded call is the whole point here.
            try { Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $null = $_ }

            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/c echo W:'
        }

        It 'expands %Var% in file' {
            $script:context.Variable['HDTApplicationRoot'] = 'D:\Applications'
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = '%HDTApplicationRoot%\setup.exe' }) 0

            # The fake refuses a command line nobody seeded, which is what a real
            # Process.Start does for a missing executable. It records the call
            # before it throws, and the recorded call is the whole point here.
            try { Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $null = $_ }

            @($script:process.Operations)[0].Arguments[0] | Should -BeExactly 'D:\Applications\setup.exe'
        }

        It 'expands %Var% in arguments' {
            $script:context.Variable['HDTComputerName'] = 'PC-0001'
            $step = & $script:newStep 'Install the thing' `
                ([ordered] @{ file = 'setup.exe'; arguments = '/name:%HDTComputerName%' }) 0

            # The fake refuses a command line nobody seeded, which is what a real
            # Process.Start does for a missing executable. It records the call
            # before it throws, and the recorded call is the whole point here.
            try { Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $null = $_ }

            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/name:PC-0001'
        }

        It 'expands %Var% in workingDirectory' {
            $script:context.Variable['HDTApplicationRoot'] = 'D:\Applications'
            $step = & $script:newStep 'Install the thing' `
                ([ordered] @{ file = 'setup.exe'; workingDirectory = '%HDTApplicationRoot%' }) 0

            # The fake refuses a command line nobody seeded, which is what a real
            # Process.Start does for a missing executable. It records the call
            # before it throws, and the recorded call is the whole point here.
            try { Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $null = $_ }

            @($script:process.Operations)[0].Arguments[2] | Should -BeExactly 'D:\Applications'
        }

        # A TOKEN NOBODY SET STAYS STANDING, and that is the rule this step must
        # not quietly improve on. Expand-HDTVariableToken leaves it verbatim so
        # the log names the variable that was never resolved; blanking it would
        # send `echo ` to a shell and call it success.
        It 'leaves a token nobody set standing verbatim' {
            $step = & $script:newStep 'Stamp the volume' ([ordered] @{ command = 'echo %HDTNobodySetThis%' }) 0

            try { Invoke-HDTCommandLineStep -Step $step -Context $script:context } catch { $null = $_ }

            @($script:process.Operations)[0].Arguments[1] | Should -BeExactly '/c echo %HDTNobodySetThis%'
        }
    }

    Context 'the step contract' {

        It 'is discovered as a step type' {
            @(Get-HDTStepType -Name 'CommandLine')[0].Source | Should -BeExactly 'Hephaestus'
        }

        It 'describes the command it will run' {
            $step = & $script:newStep 'Install the thing' ([ordered] @{ file = 'setup.exe'; arguments = '/q /norestart' }) 0

            Get-HDTStepDescription -Step $step | Should -BeLike '*setup.exe*'
        }
    }
}
