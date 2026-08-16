function New-HDTProcessService {
    <#
        .SYNOPSIS
            Creates the real IProcessService adapter, which starts a native
            process and returns its exit code and output.

        .DESCRIPTION
            The one place in HDT that starts a process. DESIGN 12.1: "native tool
            exit codes are checked explicitly; $LASTEXITCODE is never assumed to
            be zero" - so the exit code comes back as DATA on a result object
            rather than being left in an automatic variable somebody has to
            remember to read.

              Start($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond)
                -> ExitCode, StandardOutput, StandardError, TimedOut, DurationMs

            A TimeoutMillisecond of 0 waits indefinitely. On timeout the process
            is KILLED, TimedOut is $true and ExitCode is -1: a step that hung must
            not leave the process behind for the next step to trip over.

            It is a ProcessStartInfo + WaitForExit(timeout) adapter and nothing
            more - no branching on what the tool was or what it returned, which
            is what keeps the untested surface bounded. Deciding
            whether an exit code means success belongs to the CommandLine step,
            which is unit tested against the fake.

            OUTPUT IS READ ASYNCHRONOUSLY, before WaitForExit. A process that
            fills the 4 KB pipe buffer while the parent waits on exit deadlocks -
            the classic redirect trap - so both streams are drained by handler
            into a builder as they arrive.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .OUTPUTS
            System.Management.Automation.PSCustomObject with a Start
            ScriptMethod. Note that Get-Member -MemberType Method does NOT list a
            ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $process = New-HDTProcessService
            $process.Start('cmd.exe', '/c echo hello', '', 30000)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    $service = [pscustomobject] @{
        ServiceName = 'ProcessService'
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $null
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name Start -Value {
        param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond)

        $this.Record('Start', @($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond))

        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $Argument
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startInfo.WorkingDirectory = $WorkingDirectory
        }

        $standardOutput = New-Object -TypeName System.Text.StringBuilder
        $standardError = New-Object -TypeName System.Text.StringBuilder

        $process = New-Object -TypeName System.Diagnostics.Process
        $process.StartInfo = $startInfo

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            [void] $process.Start()

            # Drained asynchronously: waiting on exit while the child fills the
            # pipe buffer is the classic redirect deadlock.
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()

            $timedOut = $false
            if ($TimeoutMillisecond -gt 0) {
                $timedOut = -not $process.WaitForExit($TimeoutMillisecond)
            } else {
                $process.WaitForExit()
            }

            if ($timedOut) {
                $process.Kill()
                [void] $process.WaitForExit(5000)
            }

            [void] $standardOutput.Append($outputTask.Result)
            [void] $standardError.Append($errorTask.Result)

            $exitCode = -1
            if (-not $timedOut) {
                $exitCode = $process.ExitCode
            }

            return [pscustomobject] @{
                ExitCode       = $exitCode
                StandardOutput = $standardOutput.ToString()
                StandardError  = $standardError.ToString()
                TimedOut       = $timedOut
                DurationMs     = [long] $stopwatch.ElapsedMilliseconds
            }
        } finally {
            $stopwatch.Stop()
            $process.Dispose()
        }
    }

    return $service
}
