function Start-HDTConsoleLog {
    <#
        .SYNOPSIS
            Opens the console's log for this session.

        .DESCRIPTION
            THE CONSOLE HAD NO LOG, so a crash left nothing to read and the only
            way to answer "what did it do" was to read the source and reason
            about it. This opens the same writer the engine uses - JSONL for a
            parser, CMTrace for the administrator who already has CMTrace open -
            against the console's own directory.

            IT IS HELD IN MODULE SCOPE, which is a deliberate exception. Every
            other context in this module is passed as a parameter, but the thing
            that needs it most is the scriptblock Get-HDTHandlerCall returns:
            that block is bound to the module and invoked by WPF from an event
            handler, with no route for a parameter to reach it. A module-scope
            context is the only channel that survives that trip.

            SO IT IS RESETTABLE, and Stop-HDTConsoleLog exists for the tests
            that would otherwise inherit a previous one. State that outlives a
            test is state that makes the next failure a mystery.

            IT NEVER THROWS. A console that refused to start because it could
            not open a log would be a worse defect than the missing log: the
            logging is there to explain failures, not to become one. A directory
            that cannot be created leaves the context null and every later write
            is a no-op.

        .PARAMETER FileSystem
            The IFileSystem to write through. Omitted, the real one.

        .PARAMETER Clock
            The IClock to stamp with. Omitted, the real one.

        .PARAMETER WorkspaceRoot
            The deployment share whose Logs folder the console writes into.
            Omitted or empty, no log is opened at all - which is the state a
            console is in before a share has been chosen.

        .PARAMETER Path
            The log directory, overriding the share. Mostly for tests.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the log context, or
            $null if one could not be opened.

        .EXAMPLE
            Start-HDTConsoleLog -WorkspaceRoot 'C:\HDTLab\Share'

            Opens C:\HDTLab\Share\Logs\Console.log for this session.

        .EXAMPLE
            $context = Start-HDTConsoleLog -Path 'C:\Temp\consolelog'
            Get-HDTRunLogRecord -Context $context

            Opens one somewhere else and reads it back, which is what a test does.

        .LINK
            Get-HDTConsoleLogPath

        .LINK
            Stop-HDTConsoleLog
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a log for the current session; it is not a change to the deployment share.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Clock = $null,

        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $WorkspaceRoot = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Path = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
        if ($null -eq $Clock) { $Clock = New-HDTClock }

        $folder = $Path

        if ([string]::IsNullOrWhiteSpace($folder)) {
            # NO SHARE, NO LOG. The console starts before one is chosen and can
            # be pointed at several; until there is a share there is nowhere the
            # log is meant to go, and inventing somewhere would put half a
            # session's records in a place nobody looks.
            if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
                $script:HDTConsoleLogContext = $null
                return $null
            }

            $folder = Get-HDTConsoleLogPath -WorkspaceRoot $WorkspaceRoot
        }

        # THE RUN ID IS THE SESSION, not a deployment. Two consoles open at once
        # write two streams into one directory, and without this they would
        # interleave into one file with no way to tell them apart.
        $runId = 'console-{0}' -f ([guid]::NewGuid().ToString('n').Substring(0, 8))

        # Console.log and Console.jsonl, beside the deployment's HDT.log rather
        # than mixed into it.
        # WHO, WHERE, AND WITH WHAT. Every one of these is a question asked of a
        # console that misbehaved, and every one is unanswerable after the fact:
        #
        #   user          two administrators append to one Console.log on one
        #                 share, and 'who ran this' has no other answer
        #   machine       which workstation - the share does not know, and a
        #                 console that works on one desk and not another is the
        #                 commonest report there is
        #   elevated      more console failures are this than anything else. A
        #                 window that cannot mount an image or write a share
        #                 looks broken and is unprivileged
        #   powerShell    5.1 or 7 changes YAML, JSON and encoding behaviour
        #   module        which build of HDT, so a report can be matched to a
        #                 commit rather than to a memory
        #   processId     two consoles open at once interleave into this file
        #
        # It is written ONCE per session rather than per line: the CMTrace
        # context column carries the user on every entry, and repeating the rest
        # eighty times would bury the actions somebody opened the log to read.
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity

        $who = [string] $identity.Name
        $elevated = [bool] $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

        $script:HDTConsoleLogContext = New-HDTLogContext -RunId $runId -Phase FullOS `
            -LogPath $folder -FileSystem $FileSystem -Clock $Clock -Level Debug `
            -BaseName 'Console' -User $who

        Write-HDTLog -Context $script:HDTConsoleLogContext -Event 'console.session' `
            -Component 'Console' `
            -Message ('console opened by {0} on {1}{2}, HDT {3}, PowerShell {4}, pid {5}, logging to {6}' -f
                $who, [string] $env:COMPUTERNAME,
                $(if ($elevated) { ' (elevated)' } else { ' (NOT elevated)' }),
                [string] (Get-HDTModuleVersion), [string] $PSVersionTable.PSVersion,
                [int] $PID, $folder) `
            -Data ([ordered] @{
                user       = $who
                machine    = [string] $env:COMPUTERNAME
                elevated   = $elevated
                module     = [string] (Get-HDTModuleVersion)
                powerShell = [string] $PSVersionTable.PSVersion
                edition    = [string] $PSVersionTable.PSEdition
                processId  = [int] $PID
                logPath    = [string] $folder
                workspace  = [string] $WorkspaceRoot
            })

        return $script:HDTConsoleLogContext
    } catch {
        # A CONSOLE THAT WOULD NOT OPEN BECAUSE ITS LOG WOULD NOT OPEN is the
        # defect this feature would have introduced. Kept where a debugger can
        # reach it rather than thrown away.
        $script:HDTConsoleLogContext = $null
        Write-Verbose ("the console log could not be opened: {0}" -f [string] $_.Exception.Message)

        return $null
    }
}
