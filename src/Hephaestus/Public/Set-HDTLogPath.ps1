function Set-HDTLogPath {
    <#
        .SYNOPSIS
            Moves the live log to the target volume, mirroring everything already
            written (DESIGN 4.4.1).

        .DESCRIPTION
            A DEPLOYMENT THAT DIES IN WinPE LOSES ITS LOG AT THE REBOOT, AND
            DYING IN WinPE IS EXACTLY WHEN THE LOG IS WANTED. X: is a RAM disk;
            it is gone the moment the machine restarts. DESIGN 4.4.1 says
            _HDTLogPath follows the deployment:

              WinPE, before a disk exists            X:\HDT\Logs
              WinPE, after the volume is formatted   <target>\HDT\Logs
              Full OS                                C:\HDT\Logs

            This is the second row. Phase 04 deferred it on purpose and said so;
            this is where it lands.

            WHAT IT DOES, IN ORDER:

              1. computes the destination with Get-HDTLogPath, which already owns
                 that answer - it is not rebuilt by hand here;
              2. returns immediately if the context is already there, because the
                 loop may ask more than once;
              3. creates the destination through the context's IFileSystem;
              4. MIRRORS everything already written, preserving the tree -
                 HDT.log, HDT.jsonl, status.json, Steps\, Gather\, Native\;
              5. repoints LogPath, JsonlPath, MasterLogPath and - when a step is
                 mid-flight - StepLogPath. Seq IS NOT TOUCHED: DESIGN 4.4.2's
                 counter is monotonic across the whole run and a reset here would
                 be exactly the ambiguity it exists to prevent;
              6. sets _HDTLogPath in the variable dictionary when one is given;
              7. writes one message record naming BOTH paths, through the already
                 repointed context, so the first line in the new file explains why
                 the file exists.

            IT IS A MIRROR, NOT A MOVE. The RAM-disk copy stays. A relocation
            that deleted the only log and then failed would be worse than no
            relocation.

            AND IT NEVER THROWS. A target volume that cannot be written - full,
            not formatted after all, a letter that went away - produces a Warning
            record through the OLD context, leaves everything pointing at X:, and
            returns the old path. Losing the logs is not an acceptable price for
            moving the logs.

            A BARE DRIVE LETTER IS ACCEPTED, because that is what the engine
            publishes: Invoke-HDTDiskPartitionStep sets HDTOSVolume to 'W', not
            'W:'. 'W', 'W:' and 'W:\' all name the same volume here.

        .PARAMETER Context
            A New-HDTLogContext result. It is mutated in place - every holder of
            the same object logs to the new path from the next record onward.

        .PARAMETER TargetVolume
            The formatted target volume. A bare letter, 'W:' or 'W:\'.

        .PARAMETER Variable
            The live variable dictionary. When supplied, _HDTLogPath is set in
            it. The engine variable is read-only TO SEQUENCES AND RULES; the
            engine itself is what sets it, which is what the leading underscore
            means (DESIGN 4.4.1).

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the log path in force after the call. The new one on
            success, the old one when the relocation could not be made.

        .EXAMPLE
            Set-HDTLogPath -Context $log -TargetVolume 'W:' -Variable $Context.Variable

            What Invoke-HDTTaskSequence does once, after the step that formats
            the volume publishes HDTOSVolume.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mirrors a log directory and repoints an in-memory context. It deletes nothing, and it is called from a finally-safe path that must never prompt or fail.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetVolume,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $current = ([string] $Context.LogPath).TrimEnd('\', '/')

    # 'W' -> 'W:'. The partition step publishes a bare letter, and a bare letter
    # handed to Get-HDTLogPath would yield a RELATIVE path - logs written beside
    # the current directory, on the RAM disk, which is the one place they must
    # not stay.
    $volume = $TargetVolume.Trim().TrimEnd('\', '/')
    if ($volume -notmatch ':$') {
        $volume = '{0}:' -f $volume.TrimEnd(':')
    }

    # Get-HDTLogPath already owns the answer, including the rule that a
    # -TargetVolume means nothing in the full OS. Passing the context's own phase
    # rather than a literal keeps that rule in one place: a FullOS context
    # computes C:\HDT\Logs, matches, and this becomes a no-op.
    $destination = (Get-HDTLogPath -Phase ([string] $Context.Phase) -TargetVolume $volume).TrimEnd('\', '/')

    if ($destination -eq $current) {
        return $current
    }

    $fileSystem = $Context.FileSystem

    try {
        $fileSystem.CreateDirectory($destination)

        # The whole tree, relative paths preserved: Steps\003-ApplyImage.dism.log
        # arrives as Steps\003-ApplyImage.dism.log rather than flattened into a
        # directory of clashing names.
        [void] (Copy-HDTContentTree -Source $current -Destination $destination -FileSystem $fileSystem)
    } catch {
        # THE OLD CONTEXT, DELIBERATELY. It is the one that still works, and this
        # record is the only evidence the relocation was tried.
        Write-HDTLog -Context $Context -Severity Warning -Component 'Logging' `
            -Message ("The deployment log could not be relocated from '{0}' to '{1}': {2}. Logging continues on the RAM disk, which means this log does not survive the next reboot (DESIGN 4.4.1)." -f
                $current, $destination, $_.Exception.Message) `
            -Data ([ordered] @{ from = $current; to = $destination })

        return $current
    }

    # Repointed AFTER the mirror succeeded, so a half-copied tree never becomes
    # the place the run logs to.
    $Context.LogPath = $destination
    $Context.JsonlPath = '{0}\HDT.jsonl' -f $destination
    $Context.MasterLogPath = '{0}\HDT.log' -f $destination

    # A step mid-flight has its own log file under the old root. Rebased, it
    # keeps one log rather than two halves.
    $stepLogPath = [string] $Context.StepLogPath
    if (-not [string]::IsNullOrWhiteSpace($stepLogPath) -and
        $stepLogPath.StartsWith(($current + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {

        $Context.StepLogPath = '{0}{1}' -f $destination, $stepLogPath.Substring($current.Length)
    }

    if ($PSBoundParameters.ContainsKey('Variable') -and $null -ne $Variable) {
        $Variable['_HDTLogPath'] = $destination
    }

    # Through the ALREADY REPOINTED context, so the first line in the new file
    # says why the file exists. Seq carries straight on from the old one.
    Write-HDTLog -Context $Context -Component 'Logging' `
        -Message ("_HDTLogPath moved from '{0}' to '{1}'. Everything written so far was mirrored, and the copy on the RAM disk is left in place (DESIGN 4.4.1)." -f
            $current, $destination) `
        -Data ([ordered] @{ from = $current; to = $destination })

    return $destination
}
