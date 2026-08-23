function Copy-HDTLog {
    <#
        .SYNOPSIS
            Copies the log directory back to the share, on phase end and on
            failure.

        .DESCRIPTION
            On phase end and on failure the log directory is copied
            to <share>\Logs\<ComputerName>-<RunId>\. "Copy-back happens on failure
            too - a deployment that dies is exactly when the logs matter, and
            MDT's habit of stranding them on a wiped machine is a real operational
            problem."

            IT NEVER THROWS. A share that has gone away is the normal case for a
            machine that failed early, and a copy-back that threw would mask the
            failure it was called to preserve evidence of. A failure is logged as
            a Warning and the function returns nothing, so a caller in a finally
            block can call it unguarded.

            The directory structure under the log path is preserved, so
            Steps\003-ApplyImage.log arrives as Steps\003-ApplyImage.log rather
            than being flattened into a directory of clashing names.

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
            System.String - the directory the logs were copied into, or nothing
            when the copy failed.

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
    [OutputType([string])]
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
        Write-HDTLog -Context $Context -Severity Warning -Component 'Logging' `
            -Message ("Could not copy the deployment logs to '{0}': {1}" -f $Destination, $_.Exception.Message)

        return
    }

    return $root
}
