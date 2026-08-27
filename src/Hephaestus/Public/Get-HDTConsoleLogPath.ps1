function Get-HDTConsoleLogPath {
    <#
        .SYNOPSIS
            Where the console writes its own log.

        .DESCRIPTION
            THE CONSOLE WROTE NO LOG AT ALL UNTIL THIS EXISTED. The engine has
            HDT.jsonl, a numbered file per step and a native tool log beside each
            one; the window an administrator drives all of that from had nothing.
            So "the console crashed when I imported a driver" was answered by
            reading source and reasoning about it, which is how a wrong half of
            the system gets blamed - and did.

            IT GOES IN THE SHARE'S Logs FOLDER, BESIDE THE DEPLOYMENT LOGS, at
            the author's direction. That is where an administrator already looks
            when something went wrong, and it puts the record of what was
            AUTHORED next to the record of what was DEPLOYED - so a task
            sequence that behaves oddly on a machine can be read against the
            session that edited it, in one place, by somebody who has the share
            open anyway.

            Console.log and Console.jsonl, not HDT.log: a console session and a
            deployment in one file would interleave two machines' worth of story
            into one thread.

            WHAT THIS COSTS, STATED SO IT IS NOT DISCOVERED LATER. A console
            opens many shares, opens them read-only, and starts before any share
            is chosen - so there is NO console log until a share is open, and
            none at all on a share that refuses the write. The session that can
            least afford to go unrecorded, the one that could not reach the
            share, is the one this cannot record. Start-HDTConsoleLog never
            throws, so that costs an administrator a log and never a console.

            IT IS PURE STRING LOGIC. It reads nothing and creates nothing, so a
            test needs no file system and the answer is the same on any machine.

        .PARAMETER WorkspaceRoot
            The deployment share root.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the directory, not a file.

        .EXAMPLE
            Get-HDTConsoleLogPath -WorkspaceRoot 'C:\HDTLab\Share'

            C:\HDTLab\Share\Logs

        .EXAMPLE
            Get-Content -LiteralPath (Join-Path (Get-HDTConsoleLogPath -WorkspaceRoot 'C:\HDTLab\Share') 'Console.log') -Tail 40

            The last forty lines the console recorded - which is where to start
            when somebody says a window misbehaved.

        .LINK
            Write-HDTLog

        .LINK
            Start-HDTConsoleLog
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE SHARE'S OWN Logs FOLDER, resolved through the one command that knows
    # the layout rather than by joining 'Logs' here - a second opinion about
    # where a workspace keeps things is how the two drift.
    return [string] (Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Logs)
}
