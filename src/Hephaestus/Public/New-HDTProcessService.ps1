function New-HDTProcessService {
    <#
        .SYNOPSIS
            Creates the real IProcessService adapter, which starts a native
            process and returns its exit code and output.

        .DESCRIPTION
            The one place in HDT that starts a process. A native tool
            exit codes are checked explicitly; $LASTEXITCODE is never assumed to
            be zero" - so the exit code comes back as DATA on a result object
            rather than being left in an automatic variable somebody has to
            remember to read.

              Start($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond[, $onTick])
                -> ExitCode, StandardOutput, StandardError, TimedOut, DurationMs

            A TimeoutMillisecond of 0 waits indefinitely. On timeout the process
            is KILLED, TimedOut is $true and ExitCode is -1: a step that hung must
            not leave the process behind for the next step to trip over.

            IT POLLS RATHER THAN BLOCKS, AND THAT IS NOT AN IMPLEMENTATION
            DETAIL. The engine is single-threaded Windows PowerShell 5.1, so a
            bare WaitForExit() means the deployment can execute nothing at all
            for however long somebody else's installer takes - and every screen
            it drives freezes with it, elapsed clock included. Start waits in
            half-second slices and calls $onTick between them, so a step can say
            it is still alive. See the method for the measurement and for MDT's
            version of the same loop.

            $onTick IS OPTIONAL AND EVERY EXISTING FOUR-ARGUMENT CALL STILL
            WORKS. What it is for is New-HDTStepHeartbeat; what it must not be
            is anything that can throw.

            It is a ProcessStartInfo + WaitForExit(slice) adapter and nothing
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
            $process.Start('cmd.exe', '/c ver', $null, 0)

            Runs something and hands back its exit code. The engine never calls
            Start-Process itself: a step that shelled out directly could not be
            tested without running the thing it shells out to.

        .EXAMPLE
            @($process.GetOperationName())

            The commands this service was asked to run, in order. A test asserts on
            that list instead of on what happened to the machine.
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
        param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond,
            [scriptblock] $OnTick = $null)

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

            # POLLED, NOT BLOCKED, AND THAT IS THE WHOLE OF THE PROGRESS FIX.
            #
            # This was one WaitForExit() with no timeout, and the engine is
            # Windows PowerShell 5.1 and single-threaded - no runspace, no
            # ForEach-Object -Parallel in WinPE - so NOTHING in the deployment
            # could execute between the call and the exit. An Acrobat MSI over
            # SMB held it for one hundred and seventeen seconds on LT-7FJ45S2
            # (run-20260829-190105, 16:13:41 to 16:15:38) and the progress
            # card's elapsed clock, which is derived from log record timestamps,
            # did not advance once. A working machine was indistinguishable from
            # a hung one.
            #
            # MDT'S SHAPE. ZTIUtility.vbs's RunCommandLog launches with
            # WshShell.Exec and spins on oExec.Status with SafeSleep 100 (lines
            # 2173-2201) rather than blocking on oShell.Run(cmd, 0, True), and
            # that loop is where every LiteTouch progress repaint and its
            # five-minute heartbeat come from. PSD did the opposite -
            # Start-Process -Wait everywhere, PSDUtility.psm1:1170 - and has
            # this defect. Where they disagree MDT wins.
            #
            # FIVE HUNDRED MILLISECONDS. The tick is free but not weightless, and
            # nothing downstream needs finer: New-HDTStepHeartbeat rations
            # records to one every fifteen seconds regardless. A shorter poll
            # would burn a WinPE machine's CPU to no visible end.
            #
            # THE WAIT IS CLIPPED TO WHAT IS LEFT OF THE TIMEOUT, so a step
            # declaring a timeout still gets it to within the poll rather than
            # rounded up to the next half second.
            #
            # AND A PROCESS THAT HAS ALREADY EXITED IS NEVER TICKED: the wait
            # comes first and the tick only happens when it returns false. That
            # is what keeps a step which finishes in 200 ms from costing the log
            # anything at all.
            $exited = $false
            while (-not $exited) {

                $wait = 500
                if ($TimeoutMillisecond -gt 0) {
                    $remaining = $TimeoutMillisecond - [int] $stopwatch.ElapsedMilliseconds
                    if ($remaining -le 0) { break }
                    if ($remaining -lt $wait) { $wait = $remaining }
                }

                $exited = $process.WaitForExit($wait)

                # UNGUARDED, THE WAY ApplyImage INVOKES ITS $OnOutput. The
                # callers of this are engine code, and the one thing they pass -
                # New-HDTStepHeartbeat's tick - catches everything itself and is
                # documented never to fail a deployment. A try/catch here would
                # be a branch in an adapter that is not unit tested, hiding a
                # defect in a caller that IS.
                if (-not $exited -and $null -ne $OnTick) {
                    $null = $OnTick.Invoke()
                }
            }

            $timedOut = -not $exited

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

    # A PROCESS NOBODY WAITS FOR, AND WITH A WINDOW. Start above is right for a
    # command line step: both pipes redirected, CreateNoWindow, wait for exit.
    # Every one of those is wrong for MDT's "Exit to Command Prompt" - an
    # interactive prompt has no output to capture, MUST have a window, and must
    # not block the thread that opened it.
    #
    # UseShellExecute = $true IS WHAT GIVES IT A CONSOLE. With it false the
    # child inherits this process's handles and, in WinPE, opens into the
    # console the wizard hid - a prompt the technician cannot see.
    #
    # SO IT IS A SEPARATE VERB RATHER THAN A FLAG ON Start. A caller cannot then
    # get an interactive prompt by passing the wrong timeout, and neither method
    # has to branch on which kind of process it is running.
    $service | Add-Member -MemberType ScriptMethod -Name StartInteractive -Value {
        param([string] $FilePath, [string] $Argument, [string] $WorkingDirectory)

        $this.Record('StartInteractive', @($FilePath, $Argument, $WorkingDirectory))

        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $Argument
        $startInfo.UseShellExecute = $true
        $startInfo.CreateNoWindow = $false

        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $startInfo.WorkingDirectory = $WorkingDirectory
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)

        return [pscustomobject] @{
            ProcessId = [int] $process.Id
            FilePath  = $FilePath
        }
    }

    return $service
}
