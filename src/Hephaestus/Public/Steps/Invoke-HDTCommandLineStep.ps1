function Invoke-HDTCommandLineStep {
    <#
        .SYNOPSIS
            Runs a native command and classifies its exit code.

        .DESCRIPTION
            Runs one native command out of a sequence, on an injected
            IProcessService rather than on the machine directly.

              - name: Install the agent
                type: CommandLine
                file: setup.exe
                arguments: /q /norestart
                workingDirectory: C:\Deploy\Applications
                successCodes: [0, 1641]
                rebootCodes: [3010]
                timeoutMinutes: 30

            or `command:` for a single shell line, which is run through
            %ComSpec% /c so redirection, chaining and built-ins behave the way an
            administrator expects. The comspec comes from the injected
            IEnvironmentProvider where the catalog has one, and defaults to
            cmd.exe otherwise - never from $env:, which a step may not read.

            EXIT CODES ARE CLASSIFIED AS DATA, which is the rule "native tool
            exit codes are checked explicitly; $LASTEXITCODE is never assumed to
            be zero" made into a property of the step:

              in rebootCodes  (default 3010) -> RebootRequested
              in successCodes (default 0)    -> Completed
              anything else                  -> Failed, naming the code

            REBOOTCODES WINS A TIE. An installer that reports 3010 and is also
            listed as successful is a real configuration, and treating it as
            success would drop the reboot the installer asked for. Stated here so
            the precedence is a decision rather than an artefact of check order.

            A TIMEOUT IS A FAILURE, not a success with no output. The process
            service kills the process, reports TimedOut and returns -1, and this
            step says so in the message.

            LOGGING IS THE STANDARD SHAPE. The native.exec record carries the file
            and the exit code at Info; the FULL command line is logged only at
            Debug, because arguments routinely carry credentials and a log that
            leaked them by default would be worse than no log. Captured output
            goes through Write-HDTLog, which places it in the step's own file
 as well as the master.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Its TimeoutMinutes
            becomes the process timeout.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult. Data carries the process result.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CommandLine' })[0]

            Invoke-HDTCommandLineStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTCommandLineStep -Step $step -Context $context
            $result.Data.ExitCode

            The exit code as the process returned it. Whether that code counts as
            success is the step's successCodes, not this number.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    $filePath = ''
    $argument = ''

    if ($null -ne $property -and $property.Contains('command') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['command'])) {

        $comSpec = 'cmd.exe'
        if ($null -ne $Context.Service.Environment) {
            $fromEnvironment = [string] $Context.Service.Environment.GetVariable('ComSpec')
            if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
                $comSpec = $fromEnvironment
            }
        }

        $filePath = $comSpec
        $argument = '/c {0}' -f $property['command']
    } elseif ($null -ne $property -and $property.Contains('file') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['file'])) {

        $filePath = [string] $property['file']
        if ($property.Contains('arguments')) {
            $argument = [string] $property['arguments']
        }
    }

    if ([string]::IsNullOrWhiteSpace($filePath)) {
        $message = "step '{0}' declares neither command nor file. A CommandLine step names one or the other." -f $Step.Name

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'CommandLine'

        return (New-HDTStepResult -Status Failed -Message $message)
    }

    $workingDirectory = ''
    if ($null -ne $property -and $property.Contains('workingDirectory')) {
        $workingDirectory = [string] $property['workingDirectory']
    }

    $successCode = @(0)
    if ($null -ne $property -and $property.Contains('successCodes')) {
        $successCode = @(@($property['successCodes']) | ForEach-Object { [int] $_ })
    }

    $rebootCode = @(3010)
    if ($null -ne $property -and $property.Contains('rebootCodes')) {
        $rebootCode = @(@($property['rebootCodes']) | ForEach-Object { [int] $_ })
    }

    $timeoutMillisecond = 0
    if ([int] $Step.TimeoutMinutes -gt 0) {
        $timeoutMillisecond = [int] $Step.TimeoutMinutes * 60000
    }

    $commandLine = ('{0} {1}' -f $filePath, $argument).Trim()

    # DESIGN 4.4.5: the full command line is a Debug-only detail.
    Write-HDTLog -Context $Context.Log -Severity Debug -Event 'native.exec' -Component 'CommandLine' `
        -Message ('running {0}' -f $commandLine) `
        -Data ([ordered] @{ commandLine = $commandLine; workingDirectory = $workingDirectory; timeoutMs = $timeoutMillisecond })

    $process = $Context.Service.GetRequired('Process', 'CommandLine')

    # THE ONE THING THIS STEP CAN HONESTLY REPORT. It runs an operator's own
    # command and cannot know how far through it is - a percentage invented from
    # elapsed time would be a bar that lied, which is why this step type is
    # classified quiet in StepProgress.Contract.Tests.ps1 and stays that way.
    #
    # BUT "STILL RUNNING, AND FOR HOW LONG" IS NOT AN INVENTION. It is the only
    # fact in hand, it is true, and it changes - and without it the progress
    # card's elapsed clock, derived from record timestamps, stops dead for the
    # entire length of whatever the operator asked for. An install script that
    # runs for four minutes looked exactly like a hung machine.
    #
    # THE STEP'S NAME, NOT THE COMMAND LINE. DESIGN 4.4.5 keeps the command at
    # Debug because it routinely carries a licence key; the heartbeat is written
    # at Info, and the name is what a technician recognises anyway.
    $heartbeat = New-HDTStepHeartbeat -Context $Context -Component 'CommandLine' `
        -Activity ([string] $Step.Name)

    $result = $process.Start($filePath, $argument, $workingDirectory, $timeoutMillisecond, $heartbeat)

    foreach ($stream in @($result.StandardOutput, $result.StandardError)) {
        foreach ($line in @([string] $stream -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            Write-HDTLog -Context $Context.Log -Message $line -Component 'CommandLine' -Source $filePath
        }
    }

    if ([bool] $result.TimedOut) {
        $message = "'{0}' timed out after {1} minute(s) and was stopped." -f $filePath, $Step.TimeoutMinutes

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event 'native.exec' `
            -Component 'CommandLine' `
            -Data ([ordered] @{ file = $filePath; exitCode = [int] $result.ExitCode; timedOut = $true; durationMs = [long] $result.DurationMs })

        return (New-HDTStepResult -Status Failed -ExitCode ([int] $result.ExitCode) -Message $message -Data $result)
    }

    $exitCode = [int] $result.ExitCode

    $data = [ordered] @{
        file       = $filePath
        exitCode   = $exitCode
        timedOut   = $false
        durationMs = [long] $result.DurationMs
    }

    # rebootCodes is checked FIRST, deliberately: see the description.
    if ($rebootCode -contains $exitCode) {
        $message = "'{0}' returned {1} and asked for a restart." -f $filePath, $exitCode

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' -Component 'CommandLine' -Data $data

        return (New-HDTStepResult -Status RebootRequested -ExitCode $exitCode -Message $message -Data $result)
    }

    if ($successCode -contains $exitCode) {
        $message = "'{0}' returned {1}." -f $filePath, $exitCode

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' -Component 'CommandLine' -Data $data

        return (New-HDTStepResult -Status Completed -ExitCode $exitCode -Message $message -Data $result)
    }

    $message = "'{0}' returned {1}, which is not in successCodes ({2}) or rebootCodes ({3})." -f
    $filePath, $exitCode, ($successCode -join ', '), ($rebootCode -join ', ')

    Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event 'native.exec' `
        -Component 'CommandLine' -Data $data

    return (New-HDTStepResult -Status Failed -ExitCode $exitCode -Message $message -Data $result)
}
