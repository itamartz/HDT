function Get-HDTShardFailureReason {
    <#
        .SYNOPSIS
            Says why a worker process of a sharded build did not report.

        .DESCRIPTION
            A sharded ./build.ps1 run starts child processes, redirects each
            one's standard error to its own log, and judges the run by the
            artefacts they leave behind. When one leaves none, the build knows
            only that it is missing - and "worker 1 of 8 did not report a
            result" is the symptom, not the cause.

            THE CAUSE IS ALREADY ON DISK. This turns the two things the parent
            holds - the error log it captured and the exit code the process left
            - into one sentence it can print. It cost an investigation to learn
            that it has to: eight workers died on an Import-Module that named a
            path one directory too shallow, all eight wrote it to their err-N.log
            in plain English, and the build printed none of it.

            AN EMPTY LOG IS A DIAGNOSIS, NOT A BLANK. A process that threw writes
            to standard error and exits 1. A process that was killed - out of
            memory, access violation, a stack overflow in a deep recursion -
            writes nothing at all and exits with an NTSTATUS. Those are different
            defects, so the exit code is reported beside the log and in hex when
            it is one of those: 0xC0000005 is a searchable string and
            -1073741819 is not.

            IT NEVER THROWS. It runs only on the failure path, where a helper
            that throws replaces the diagnosis with its own stack trace.

        .PARAMETER ErrorPath
            The file the worker's standard error was redirected to. It is named
            in the result whether or not it exists, because the operator's next
            move is to open it.

        .PARAMETER ExitCode
            The worker's exit code, or $null when there is no process to ask -
            which is itself worth saying, since "exit code 0" would read as a
            clean exit.

        .PARAMETER MaximumLine
            How many trailing lines of the log to quote. A worker that fails
            inside a BeforeAll can write one error per test file; the tail is the
            part that still matters, and the count of what was dropped points at
            the rest.

        .OUTPUTS
            System.String - one multi-line sentence, safe to append to a throw.

        .EXAMPLE
            Get-HDTShardFailureReason -ErrorPath $log -ExitCode $process.ExitCode
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ErrorPath,

        [Parameter()]
        [AllowNull()]
        [object] $ExitCode,

        [Parameter()]
        [ValidateRange(1, 100000)]
        [int] $MaximumLine = 40
    )

    $code = 'exit code unknown'
    if ($null -ne $ExitCode) {
        $value = [int] $ExitCode

        if ($value -lt 0 -or $value -gt 255) {
            # An NTSTATUS, which is how a killed process reports itself.
            $code = 'exit code {0} (0x{1})' -f $value, ('{0:X8}' -f $value)
        } else {
            $code = 'exit code {0}' -f $value
        }
    }

    $line = @()
    $readable = $false

    try {
        if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) {
            $readable = $true
            $line = @(Get-Content -LiteralPath $ErrorPath -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
        }
    } catch {
        return ('{0}; its standard error log ''{1}'' could not be read: {2}' -f $code, $ErrorPath, $_.Exception.Message)
    }

    if (-not $readable) {
        return ('{0}; its standard error log ''{1}'' was never written, so the process did not get far enough to fail - or was never started.' -f
            $code, $ErrorPath)
    }

    if ($line.Count -eq 0) {
        return ('{0}; its standard error log ''{1}'' is empty, so it was killed rather than having thrown.' -f $code, $ErrorPath)
    }

    $dropped = 0
    if ($line.Count -gt $MaximumLine) {
        $dropped = $line.Count - $MaximumLine
        $line = @($line[($line.Count - $MaximumLine)..($line.Count - 1)])
    }

    $head = '{0}; the last of its standard error (''{1}''):' -f $code, $ErrorPath
    if ($dropped -gt 0) {
        $head = '{0}; the last {1} line(s) of its standard error (''{2}'', {3} earlier line(s) not shown):' -f
        $code, $line.Count, $ErrorPath, $dropped
    }

    return (@($head) + $line) -join [Environment]::NewLine
}
