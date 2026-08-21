function Remove-HDTResumeAgent {
    <#
        .SYNOPSIS
            MDT's LTICleanup: keeps the logs, drops the agent, and leaves a
            finished machine carrying nothing of the deployment that built it.

        .DESCRIPTION
            WHAT A DEPLOYED MACHINE WAS STILL HOLDING. Watched on 2026-08-21:
            the deployment succeeded, the Deployment Summary said so - and the
            machine still had the deployment share on a mapped drive, still had
            C:\HDT with the engine and the share credential's bootstrap document
            in it, and its only record of how it had been built was inside that
            same folder.

            MDT does this at the end of State Restore and so does the reference
            implementation. It is the last thing a deployment owes the machine.

            THE LOGS MOVE FIRST, AND THE ORDER IS THE WHOLE COMMAND. They live
            under the folder being removed, so a version that deleted first
            would be a deployment with no account of itself - strictly worse
            than a machine with a stale folder on it. Nothing is removed if the
            copy throws.

            WHERE THEY GO IS THE CALLER'S ANSWER, and the payload's default is
            %WINDIR%\Logs\HDT. That is a deliberate divergence from MDT, which
            copies to %WINDIR%\TEMP\DeploymentLogs - a directory Windows itself
            cleans out, which is a poor home for the only record of how a
            machine was built. DESIGN 14 carries the reason.

            IT DOES NOT DECIDE WHEN. On a FAILED deployment none of this should
            happen: that is precisely the machine somebody walks up to with
            questions, and every one of those questions is answered by the
            things this removes. The caller owns that rule - MDT's
            LTICleanup runs on success only - and this command runs when it is
            called.

            AND IT REFUSES A PATH THAT IS NOT AN AGENT. CLAUDE.md's rule is that
            nothing passes a variable to a recursive delete without asserting
            first that it is the thing it meant. A bug upstream must not turn
            this into a machine with no C:\Windows, so the path has to CONTAIN A
            STAGED AGENT - Start-HDTResume.ps1, the file Copy-HDTResumeAgent
            puts there - before anything is removed. A folder merely named HDT is
            somebody else's.

            THE MAPPED DRIVE IS NOT THIS COMMAND'S. The content provider owns it
            and Disconnect is what drops it; a second answer to "who unmaps the
            share" is a second thing to get wrong.

        .PARAMETER Path
            The staged agent folder. C:\HDT on a deployed machine.

        .PARAMETER LogDestination
            Where the logs are kept before the folder goes.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Removed,
            LogDestination and LogFileCount.

        .EXAMPLE
            Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination "$env:WinDir\Logs\HDT"

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
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $root = $Path.TrimEnd('\', '/')

    $result = [ordered] @{
        Path           = $root
        Removed        = $false
        LogDestination = $LogDestination.TrimEnd('\', '/')
        LogFileCount   = 0
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

    if (-not $PSCmdlet.ShouldProcess($root, 'Keep the logs and remove the staged resume agent')) {
        return [pscustomobject] $result
    }

    # -- the logs, before anything is removed ---------------------------------

    $logRoot = '{0}\Logs' -f $root

    if ($FileSystem.TestPath($logRoot)) {
        $destination = $result['LogDestination']
        $FileSystem.CreateDirectory($destination)

        foreach ($file in @($FileSystem.GetChildItem($logRoot))) {
            $leaf = [System.IO.Path]::GetFileName([string] $file)

            $FileSystem.CopyItem([string] $file, ('{0}\{1}' -f $destination, $leaf))
            $result['LogFileCount']++
        }
    }

    # -- and now the folder ---------------------------------------------------

    # Recursive, and the assertion above is what makes that safe to write.
    $FileSystem.RemoveItem($root, $true)
    $result['Removed'] = $true

    return [pscustomobject] $result
}
