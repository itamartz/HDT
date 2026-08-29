function Copy-HDTLog {
    <#
        .SYNOPSIS
            Copies the log directory back to the share, on phase end and on
            failure.

        .DESCRIPTION
            On phase end and on failure the log directory is copied
            to <share>\Logs\<ComputerName>-<RunId>\. Copy-back happens on failure
            too - a deployment that dies is exactly when the logs matter, and a
            machine that is about to be wiped is not a place to leave them.

            IT NEVER THROWS. A share that has gone away is the normal case for a
            machine that failed early, and a copy-back that threw would mask the
            failure it was called to preserve evidence of. A failure is reported
            on the result rather than raised, so a caller in a finally block can
            call it unguarded.

            AND IT NEVER THREW AND NEVER SAID SO EITHER, WHICH WAS THE DEFECT.
            It used to answer a bare path string on success and NOTHING on
            failure, writing a Warning through Write-HDTLog - into the log it
            had just failed to send. So the one surface that knew the logs were
            not reaching the share was the copy of the log that never arrived,
            and every caller piped the answer to Out-Null because there was
            nothing in it to read. A technician standing at the bench had no way
            to tell.

            SO ONE SHAPE, BOTH OUTCOMES: Path, Succeeded and Message, always all
            three. A caller that has to test the TYPE before it can read the
            answer is a caller that will read the wrong one, and Path is filled
            on a failure too because where it was trying to put them is the
            first thing anybody checks next.

            The directory structure under the log path is preserved, so
            Steps\003-ApplyImage.log arrives as Steps\003-ApplyImage.log rather
            than being flattened into a directory of clashing names.

            EXCEPT FOR A FOLDER OF THE NAME IT IS WRITING, WHICH IS SKIPPED.
            The log root frequently already holds a copy of itself under exactly
            <ComputerName>-<RunId> - the copy the previous leg made onto the
            volume that survives the reboot - and the destination is sometimes
            that folder. Carrying it across is what produced three levels of
            <run>\<run>\<run> on a real share. The comment at $runFolder has the
            whole account.

            Everything goes through the context's injected IFileSystem. Children
            are classified with GetLength, which succeeds for a file and throws
            for a directory on both implementations of IFileSystem - the interface
            has no "is this a directory" method, and adding one for this would be
            a wider change than the question deserves.

        .PARAMETER Context
            A New-HDTLogContext result. Supplies the log path, the run id and the
            injected services.

        .PARAMETER Destination
            The share's log root, conventionally <share>\Logs.

        .PARAMETER ComputerName
            The name of the machine being deployed, which the engine passes from
            %HDTComputerName%. Defaults to this machine's name for a caller that
            has not resolved one yet.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path (the directory
            the logs were copied into, or would have been), Succeeded and
            Message (empty unless the copy failed).

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            Copy-HDTLog -Context $log -Destination '\\LAP-AMMSO01\HDTShare$\Logs' -ComputerName 'PC-0001'

            Copies the whole log tree to the share under a folder named for the
            machine and the run, so two deployments of the same machine do not
            overwrite each other.

        .EXAMPLE
            $answer = Copy-HDTLog -Context $log -Destination '\\LAP-AMMSO01\HDTShare$\Logs' -ComputerName 'PC-0001'
            $answer.Path

            Where they landed. A share that cannot be reached is reported rather than
            thrown: losing the logs must not fail a deployment that worked.

    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ComputerName = [System.Environment]::MachineName
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fileSystem = $Context.FileSystem
    $root = '{0}\{1}-{2}' -f $Destination.TrimEnd('\', '/'), $ComputerName, $Context.RunId
    $source = [string] $Context.LogPath

    # THE NAME OF THE FOLDER BEING WRITTEN, WHICH THE SOURCE MAY ALREADY HOLD A
    # COPY OF. Measured on a real share and on the machine it deployed:
    #
    #   PC-5784-6600-26-run-20260829-052141\
    #     PC-5784-6600-26-run-20260829-052141\
    #       PC-5784-6600-26-run-20260829-052141\
    #
    # three deep, each with its own Steps\ and Gather\. Two call sites feed it
    # and both are this one folder name appearing on both sides of the copy.
    #
    # Invoke-HDTTaskSequence copies the log onto the volume that survives the
    # reboot - and Set-HDTLogPath has by then moved the CONTEXT onto that
    # volume, so the destination composed above, <volume>\HDT\Logs\<name>, sits
    # INSIDE its own source, <volume>\HDT\Logs. The walk found the folder it had
    # just created and copied it into itself.
    #
    # And that copy outlives the reboot, so the full-OS log root then holds a
    # folder of this name too - which the final copy-back to the share carries
    # across, giving the second level, once per leg.
    #
    # SKIPPED, NOT MERGED, AND NOT REFUSED. The folder is a snapshot of the very
    # tree being copied, so nothing in it is lost by leaving it behind; merging
    # it would ask CopyItem to copy a file onto itself in the case where the
    # destination IS that folder, which throws; and refusing outright is not
    # available to a command documented never to throw. Copy-HDTContentTree
    # refuses the same shape because it may.
    $runFolder = [System.IO.Path]::GetFileName($root)

    try {
        $fileSystem.CreateDirectory($root)

        # Breadth-first over the log tree, carrying each item's path relative to
        # the log root so the structure survives the copy.
        $pending = New-Object -TypeName System.Collections.ArrayList
        [void] $pending.Add([pscustomobject] @{ Path = $source; Relative = '' })

        while ($pending.Count -gt 0) {
            $current = $pending[0]
            $pending.RemoveAt(0)

            foreach ($child in @($fileSystem.GetChildItem($current.Path))) {
                $leaf = Split-Path -Path $child -Leaf

                # See $runFolder above: a previous copy of this same run, or the
                # destination itself when it sits inside the source.
                if ($leaf -eq $runFolder) { continue }

                $relative = $leaf
                if (-not [string]::IsNullOrEmpty([string] $current.Relative)) {
                    $relative = '{0}\{1}' -f $current.Relative, $leaf
                }

                $isFile = $true
                try {
                    [void] $fileSystem.GetLength($child)
                } catch {
                    $isFile = $false
                }

                if ($isFile) {
                    $fileSystem.CopyItem($child, ('{0}\{1}' -f $root, $relative))
                } else {
                    [void] $pending.Add([pscustomobject] @{ Path = $child; Relative = $relative })
                }
            }
        }
    } catch {
        $reason = [string] $_.Exception.Message

        # THE LOG STILL GETS THE LINE, because a run that later reaches a
        # working share ships this file too and the sentence belongs in it. It
        # is no longer the ONLY place it goes: the caller is told as well, and
        # the caller has a screen.
        Write-HDTLog -Context $Context -Severity Warning -Component 'Logging' `
            -Message ("Could not copy the deployment logs to '{0}': {1}" -f $Destination, $reason)

        return [pscustomobject] @{
            Path      = $root
            Succeeded = $false
            Message   = $reason
        }
    }

    return [pscustomobject] @{
        Path      = $root
        Succeeded = $true
        Message   = ''
    }
}
