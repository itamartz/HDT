function Start-HDTAgentRemoval {
    <#
        .SYNOPSIS
            Copies the deleter out of the doomed folder and starts it detached.

        .DESCRIPTION
            THE HALF OF THE CLEANUP THIS PROCESS CANNOT DO. C:\HDT cannot be
            deleted by the leg running out of it: Start-HDTResume.ps1 prepends
            C:\HDT\Modules to PSModulePath, powershell-yaml LoadFile()s
            YamlDotNet.dll from there, and Windows PowerShell 5.1 cannot unload
            an assembly for the life of a process. A recursive delete from
            inside throws part way and leaves a half-deleted tree.

            SO THE DELETER IS COPIED OUT FIRST. It is staged INSIDE the folder
            being removed - beside Start-HDTResume.ps1, which is where
            Copy-HDTResumeAgent puts it - so it has to be moved to %TEMP% before
            it can outlive its own target. The copy goes through IFileSystem
            like everything else, and the process goes through IProcessService,
            so the whole handoff is provable against fakes with nothing on disk
            and no process started.

            IT DOES NOT WAIT, AND IT MUST NOT. The first thing the deleter does
            is stop the process that started it; a caller that waited would be
            waiting for its own death, and StartInteractive is the one verb on
            IProcessService that starts a process nobody waits for.

            NOTHING HERE THROWS AT THE CALLER. A shell that will not launch or a
            deleter that was never staged - a boot image built before this
            existed - is a machine with a stale C:\HDT on it, which is a far
            smaller problem than a successful deployment reported as a failure.
            The reason comes back on the result, the way Start-HDTCommandPrompt
            hands back its own.

            DERIVED FROM PSD (MIT). PSDStart.ps1:1005 copies PSDFinal.ps1 to
            $env:TEMP and :1033 starts it with -ParentPID; see NOTICE.md.

        .PARAMETER Path
            The staged agent folder to be removed. C:\HDT on a deployed machine.

        .PARAMETER FinishAction
            What the machine does once the folder is gone. It travels with the
            deleter because the parent will not be alive to produce it.

        .PARAMETER DelaySecond
            How long the finish action waits before acting.

        .PARAMETER ProcessId
            The process the deleter must stop first.

        .PARAMETER FileSystem
            An IFileSystem.

        .PARAMETER Process
            An IProcessService.

        .PARAMETER Environment
            An IEnvironmentProvider, read for TEMP and SystemRoot.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Started, ScriptPath,
            Shell, Argument, ProcessId and Message.

        .EXAMPLE
            Start-HDTAgentRemoval -Path 'C:\HDT' -FinishAction 'Restart' -DelaySecond 30 `
                -ProcessId $PID -FileSystem $fs -Process $process -Environment $environment
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller owns the ShouldProcess decision and has already made it; the deleter this starts asks again on its own command line.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowEmptyString()]
        [string] $FinishAction = 'None',

        # The staged driver folder, named by the caller and never worked out
        # here. Empty means there is nothing to remove.
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $DriverPath,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $DelaySecond = 0,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $ProcessId = $PID,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Process,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $root = $Path.TrimEnd('\', '/')
    $leaf = 'Remove-HDTAgentTree.ps1'

    # Argument IS ON THE RESULT SO IT CAN BE EXECUTED IN A TEST. Asserting the
    # string is what missed the -File defect above; running it is what caught it.
    $answer = [ordered] @{
        Started    = $false
        ScriptPath = ''
        Shell      = ''
        Argument   = ''
        ProcessId  = 0
        Message    = ''
    }

    # A DEFAULT THAT IS NOT INSIDE WHAT IS ABOUT TO BE DELETED. An environment
    # with no TEMP is a service account nobody has profiled, and %WINDIR%\Temp
    # exists on every Windows install there has ever been.
    $systemRoot = [string] $Environment.GetVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }

    $temp = [string] $Environment.GetVariable('TEMP')
    if ([string]::IsNullOrWhiteSpace($temp)) { $temp = '{0}\Temp' -f $systemRoot }

    $source = [System.IO.Path]::Combine($root, $leaf)
    $staged = [System.IO.Path]::Combine($temp.TrimEnd('\', '/'), $leaf)

    $answer['ScriptPath'] = $staged

    if (-not $FileSystem.TestPath($source)) {
        $answer['Message'] = ("'{0}' is not staged beside the resume agent, so nothing can remove '{1}' once this process ends. It is staged by Copy-HDTResumeAgent from a boot image built by Update-HDTBootImage; rebuild the boot image." -f
            $source, $root)

        return [pscustomobject] $answer
    }

    # A SHELL, AND THE 64-BIT ONE THIS PROCESS IS ALREADY IN. Naming
    # powershell.exe alone would resolve against PATH, which the deleter is
    # about to outlive the setting of.
    $shell = '{0}\System32\WindowsPowerShell\v1.0\powershell.exe' -f $systemRoot.TrimEnd('\', '/')

    # -Command AND NOT -File, AND THIS IS THE ONE THAT ONLY FAILS ON IRON.
    # powershell.exe -File passes every argument after the script as a LITERAL
    # STRING: '-Confirm:$false' arrives as the four characters $false, which
    # cannot convert to a SwitchParameter, and the deleter dies on argument
    # binding with exit 1 before it runs a line. Every unit test passed - they
    # asserted the string, not what a shell does with it - and the folder would
    # have survived on every machine. -Command hands the line to the PARSER, so
    # $false is the boolean it reads as.
    #
    # AND -Confirm:$false IS NOT OPTIONAL. The deleter declares
    # ConfirmImpact High because it is a recursive delete and a human running it
    # by hand should be asked; this process is not a human, has no window and is
    # started -NonInteractive, so an unanswered prompt is a folder that is never
    # removed.
    #
    # SINGLE QUOTES INSIDE, DOUBLED TO ESCAPE THEM. The whole command is one
    # double-quoted argument, so the paths within it are quoted the other way -
    # and a directory may legally contain an apostrophe.
    $quoted = {
        param([string] $Value)

        return ("'{0}'" -f ([string] $Value).Replace("'", "''"))
    }

    # -WindowStyle Hidden, BECAUSE THE LAST THING A TECHNICIAN SEES SHOULD BE
    # THE DEPLOYMENT SUMMARY. PSD shows this window only in debug.
    # OMITTED WHEN THERE IS NOTHING TO REMOVE, rather than passed empty. An
    # empty -DriverPath would still bind, and the deleter's guard would still
    # refuse it, but a command line that names a folder it is not going to touch
    # is one more thing to explain to whoever reads it in a log.
    $driverArgument = ''
    if (-not [string]::IsNullOrWhiteSpace($DriverPath)) {
        $driverArgument = ' -DriverPath {0}' -f (& $quoted $DriverPath)
    }

    $argument = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& {0} -Path {1}{5} -ParentProcessId {2} -FinishAction {3} -DelaySecond {4} -Confirm:$false"' -f
        (& $quoted $staged), (& $quoted $root), $ProcessId, (& $quoted $FinishAction), $DelaySecond, $driverArgument)

    $answer['Shell'] = $shell
    $answer['Argument'] = $argument

    try {
        $FileSystem.CopyItem($source, $staged)

        # THE WORKING DIRECTORY IS %TEMP%, AND THAT IS LOAD BEARING. A process
        # whose current directory is inside C:\HDT holds that directory open,
        # and the delete it was started to perform then fails on the folder
        # itself after emptying it.
        $started = $Process.StartInteractive($shell, $argument, $temp)

        $answer['Started'] = $true
        $answer['ProcessId'] = [int] $started.ProcessId
    } catch {
        $answer['Message'] = ("the cleanup process could not be started, so '{0}' stays on this machine: {1}" -f
            $root, [string] $_.Exception.Message)
    }

    return [pscustomobject] $answer
}
