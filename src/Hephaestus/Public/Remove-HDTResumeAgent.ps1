function Remove-HDTResumeAgent {
    <#
        .SYNOPSIS
            Keeps the logs, destroys the share credential, and hands the staged
            agent to something that can actually delete it.

        .DESCRIPTION
            WHAT A DEPLOYED MACHINE WAS STILL HOLDING. Watched on 2026-08-21:
            the deployment succeeded, the Deployment Summary said so - and the
            machine still had the deployment share on a mapped drive, still had
            C:\HDT with the engine and the share credential's bootstrap document
            in it, and its only record of how it had been built was inside that
            same folder.

            IT RUNS AT THE END OF STATE RESTORE, and it is the last thing a
            deployment owes the machine. (MDT's LTICleanup runs there too, and
            so does the reference implementation's.)

            THE LOGS MOVE FIRST, AND THE ORDER IS THE WHOLE COMMAND. They live
            under the folder being removed, so a version that deleted first
            would be a deployment with no account of itself - strictly worse
            than a machine with a stale folder on it. Nothing is removed if the
            copy throws.

            AND THEY ARE A TREE, WHICH IS WHAT THE FIRST VERSION GOT WRONG.
            C:\HDT\Logs holds exactly one entry on a real machine and it is a
            DIRECTORY - the run folder, with Steps\ and Gather\ under it.
            IFileSystem.GetChildItem is Directory.GetFileSystemEntries, which
            returns directories, and IFileSystem.CopyItem is File.Copy, which
            throws when handed one. The pair threw on the first iteration of
            every deployment ever cleaned up, the caller's catch reported "the
            resume agent could not be removed", and the whole folder survived
            with the credential in it. Copy-HDTContentTree is what recurses.

            WHERE THEY GO IS THE CALLER'S ANSWER, and the payload's default is
            %WINDIR%\Logs\HDT rather than %WINDIR%\TEMP\DeploymentLogs - a
            directory Windows itself cleans out, which is a poor home for the
            only record of how a machine was built. DESIGN 14 carries the
            reason. state.json goes with them: it lives beside the agent rather
            than under Logs\, and it is the engine's own account of which step
            the run reached.

            THEN THE CREDENTIAL, IN THIS PROCESS, BEFORE ANYTHING IS HANDED
            OVER. bootstrap.json carries the deployment share's account and its
            password, AES-encrypted under a key that is a MODULE CONSTANT -
            neither user- nor machine-bound (see Unprotect-HDTShareSecret), so
            anybody holding the file holds the credential. Nothing locks that
            file, so it is deleted here rather than left to the detached step
            below: a process that fails to start must not be the difference
            between a destroyed credential and a recoverable one.

            AND THE TREE ITSELF GOES TO A SECOND PROCESS, because it cannot go
            to this one. This leg runs FROM the folder: Start-HDTResume.ps1
            prepends C:\HDT\Modules to PSModulePath and powershell-yaml
            LoadFile()s YamlDotNet.dll out of it, which Windows PowerShell 5.1
            cannot unload for the life of a process. A recursive delete from
            here throws part way and leaves a half-deleted tree. So
            Remove-HDTAgentTree.ps1 is copied OUT of the doomed folder into
            %TEMP% and started detached with this process's id; it stops this
            process, removes the tree, and performs the finish action - which
            has to move with it, because by then there is nobody left to restart
            the machine. PSD does exactly this, and MDT before it; see NOTICE.md.

            IT DOES NOT DECIDE WHEN. On a FAILED deployment none of this should
            happen: that is precisely the machine somebody walks up to with
            questions, and every one of those questions is answered by the
            things this removes. The caller owns that rule - cleanup runs on
            success only - and this command runs when it is called.

            AND IT REFUSES A PATH THAT IS NOT AN AGENT. CLAUDE.md's rule is that
            nothing passes a variable to a recursive delete without asserting
            first that it is the thing it meant. A bug upstream must not turn
            this into a machine with no C:\Windows, so the path has to CONTAIN A
            STAGED AGENT - Start-HDTResume.ps1, the file Copy-HDTResumeAgent
            puts there - before anything is removed. A folder merely named HDT is
            somebody else's. The detached deleter asserts the same thing again
            on its own command line, because it is the one that does the delete.

            THE MAPPED DRIVE IS NOT THIS COMMAND'S. The content provider owns it
            and Disconnect is what drops it; a second answer to "who unmaps the
            share" is a second thing to get wrong.

        .PARAMETER Path
            The staged agent folder. C:\HDT on a deployed machine.

        .PARAMETER LogDestination
            Where the logs and the state document are kept before the folder
            goes.

    .PARAMETER DriverPath
            The staged driver folder to remove with the agent - <os volume>\Drivers,
            4.2 GB of it on a real Latitude. Named by the caller because the
            deleter runs detached and elevated and must never guess a path.

        .PARAMETER FinishAction
            What the machine does once the folder is gone - Restart, Stop,
            Logoff or None - passed straight to the detached deleter, which is
            the only thing still running by then. Get-HDTFinishAction resolves
            MDT's REBOOT / SHUTDOWN / LOGOFF spellings to these.

        .PARAMETER DelaySecond
            How long the finish action waits before acting.

        .PARAMETER ProcessId
            The process the deleter must stop before it can remove the tree.
            Defaults to this one, which is the leg holding the folder open.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Process
            An IProcessService, which is what starts the detached deleter.
            Defaults to the real adapter.

        .PARAMETER Environment
            An IEnvironmentProvider, read for TEMP - the one directory the
            deleter can live in that is not the one being deleted.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path,
            LogDestination, LogFileCount, SecretRemoved, RemovalStarted and
            RemovalProcessId.

        .EXAMPLE
            Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination "$env:WinDir\Logs\HDT" -FinishAction 'Restart'

            What Start-HDTResume.ps1 calls once the technician has pressed
            Finish on a deployment that worked.

        .EXAMPLE
            Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' -WhatIf

            What it would keep and what it would remove, and neither.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $LogDestination,

        [Parameter()]
        [AllowEmptyString()]
        [string] $FinishAction = 'None',

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

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Process,

        [Parameter()]
        [AllowNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Process) { $Process = New-HDTProcessService }
    if ($null -eq $Environment) { $Environment = New-HDTEnvironmentProvider }

    $root = $Path.TrimEnd('\', '/')

    $result = [ordered] @{
        Path             = $root
        LogDestination   = $LogDestination.TrimEnd('\', '/')
        LogFileCount     = 0
        SecretRemoved    = [string[]] @()
        RemovalStarted   = $false
        RemovalProcessId = 0
        Message          = ''
    }

    # NOTHING THERE IS NOT AN ERROR. A second Finish press, or a leg that has
    # already cleaned up, must not turn a finished deployment into a failure.
    if (-not $FileSystem.TestPath($root)) {
        return [pscustomobject] $result
    }

    # THE ASSERTION THE HEADER PROMISES, AND IT IS BEFORE EVERYTHING. A path that
    # does not carry the agent is not the agent, whatever it is called.
    $agent = '{0}\Start-HDTResume.ps1' -f $root

    if (-not $FileSystem.TestPath($agent)) {
        throw ("HDTCleanupRefused: '{0}' does not hold a staged resume agent - there is no '{1}' in it - so it will not be removed. This command deletes a directory tree and only ever deletes one Copy-HDTResumeAgent wrote." -f
            $root, 'Start-HDTResume.ps1')
    }

    if (-not $PSCmdlet.ShouldProcess($root, 'Keep the logs, destroy the share credential and remove the staged resume agent')) {
        return [pscustomobject] $result
    }

    # -- the logs, before anything is removed ---------------------------------

    $destination = $result['LogDestination']
    $logRoot = '{0}\Logs' -f $root

    if ($FileSystem.TestPath($logRoot)) {
        # A TREE, NOT A LIST OF FILES - see the description. Copy-HDTContentTree
        # creates the destination and recurses, and it tells a directory from a
        # file the one way IFileSystem allows.
        $result['LogFileCount'] += [int] (Copy-HDTContentTree -Source $logRoot `
                -Destination $destination -FileSystem $FileSystem)
    } else {
        $FileSystem.CreateDirectory($destination)
    }

    # THE STATE DOCUMENT LIVES BESIDE THE AGENT, NOT UNDER Logs\, because the
    # boot reconcile reads it there. It is the only account of which step the
    # run reached, so a sweep that took Logs\ alone threw it away.
    $state = '{0}\state.json' -f $root

    if ($FileSystem.TestPath($state)) {
        $FileSystem.CopyItem($state, ('{0}\state.json' -f $destination))
        $result['LogFileCount']++
    }

    # -- the credential, in this process --------------------------------------
    #
    # NOTHING HOLDS THESE OPEN, so they go now rather than depending on a
    # detached process that may never start. This is the security guarantee and
    # it is not allowed to have a moving part in it.
    $destroyed = New-Object -TypeName System.Collections.ArrayList

    foreach ($leaf in @('bootstrap.json', 'state.json')) {
        $secret = '{0}\{1}' -f $root, $leaf

        if (-not $FileSystem.TestPath($secret)) { continue }

        $FileSystem.RemoveItem($secret, $false)
        [void] $destroyed.Add([string] $secret)
    }

    $result['SecretRemoved'] = [string[]] @($destroyed)

    # -- and the tree goes to something that can delete it --------------------

    $handoff = Start-HDTAgentRemoval -Path $root -FinishAction $FinishAction -DelaySecond $DelaySecond `
        -DriverPath $DriverPath `
        -ProcessId $ProcessId -FileSystem $FileSystem -Process $Process -Environment $Environment

    $result['RemovalStarted'] = [bool] $handoff.Started
    $result['RemovalProcessId'] = [int] $handoff.ProcessId
    $result['Message'] = [string] $handoff.Message

    return [pscustomobject] $result
}
