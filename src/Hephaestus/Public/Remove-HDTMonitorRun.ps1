function Remove-HDTMonitorRun {
    <#
        .SYNOPSIS
            Clears one deployment's heartbeat file off the share's Monitoring
            node.

        .DESCRIPTION
            Deployment Workbench's Monitoring node, and the thing that node has
            always needed: a way to take a finished run off it. The engine writes
            a heartbeat per running deployment under Logs\_active\, and nothing
            ever removes one - so a share that has deployed fifty machines shows
            fifty rows, and the one that is actually running is somewhere in
            them.

            THIS IS THE ONE DELETABLE THING ON A SHARE THAT BREAKS NOTHING. No
            task sequence reads a heartbeat, no boot image names one, and no rule
            resolves from one. Clearing a FINISHED run loses a record of a
            deployment that already happened; clearing a LIVE one loses the
            console's view of it until the engine writes the next step, which it
            does anyway. That is why the dialog in front of it does not borrow
            the "this cannot be undone" sentence the other four removals share -
            see Get-HDTConsoleRemoval.

            A RUN ID IS A FILE NAME AND NOTHING ELSE, and this command is the
            shape that costs people their share: a string off a tree row turned
            into a delete. So it refuses rather than normalises. A separator, a
            '..', a rooted path or a wildcard is a defect in whatever produced
            it, and accepting one because it happens to resolve somewhere legal
            would be luck rather than a rule. Three refusals stand between a
            caller and the delete:

              1. the run id must be a single path segment - no '\', no '/', no
                 '..', not rooted, and no wildcard, because
                 Logs\_active\*.json is every run on the share;
              2. the composed path must still sit under <Root>\Logs\_active
                 once normalised - belt and braces over rule 1, because a path
                 that survives a textual check and then resolves somewhere else
                 is exactly the bug this kind of command is famous for;
              3. it must exist, and a run that has already gone is not an error.
                 Two people clearing the same finished row is a Tuesday.

            IT DELETES ONE FILE, NOT RECURSIVELY, by an explicit path it built
            itself from -Root and -RunId. Nothing here enumerates a directory to
            decide what to remove.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER RunId
            The run, as the Monitoring row names it - the heartbeat file's name
            without its .json extension.

        .PARAMETER FileSystem
            The IFileSystem to delete through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with RunId, Path and
            Removed.

        .EXAMPLE
            Remove-HDTMonitorRun -Root 'C:\HDTLab\Share' -RunId 'run-20260827-191455'

            Takes one finished deployment off the Monitoring node.

        .EXAMPLE
            Remove-HDTMonitorRun -Root 'C:\HDTLab\Share' -RunId 'run-20260827-191455' -WhatIf

            Which file it would clear, without clearing it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $id = $RunId.Trim()

    # -- 1. a run id is one path segment --------------------------------------

    $illegal = @('\', '/', '..', '*', '?', ':')
    $bad = @($illegal | Where-Object { $id.Contains($_) })

    if ([string]::IsNullOrWhiteSpace($id) -or @($bad).Count -gt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $RunId `
                    -Message ("'{0}' is not a run id. A run is one heartbeat file under Logs\_active, so its id carries no path separator, no '..', and no wildcard." -f $RunId)))
    }

    $active = Join-Path -Path (Get-HDTWorkspacePath -Root $Root -Kind Logs) -ChildPath '_active'
    $full = [System.IO.Path]::Combine($active, ('{0}.json' -f $id))

    # -- 2. still under _active once normalised -------------------------------

    $fullNormal = [System.IO.Path]::GetFullPath($full)
    $activeNormal = [System.IO.Path]::GetFullPath($active).TrimEnd('\')

    if (-not $fullNormal.StartsWith($activeNormal + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $full `
                    -Message ("'{0}' does not resolve to a heartbeat file inside '{1}', so it will not be removed." -f $full, $active)))
    }

    # -- 3. it has to be there ------------------------------------------------

    if (-not $FileSystem.TestPath($fullNormal)) {
        return [pscustomobject] @{ RunId = $id; Path = $fullNormal; Removed = $false }
    }

    if (-not $PSCmdlet.ShouldProcess($fullNormal, 'Clear this run off the Monitoring node')) {
        return [pscustomobject] @{ RunId = $id; Path = $fullNormal; Removed = $false }
    }

    # A RUN IS A FILE. -Recurse on something that turns out to be a directory is
    # how a single-file delete takes a tree with it.
    $FileSystem.RemoveItem($fullNormal, $false)

    return [pscustomobject] @{ RunId = $id; Path = $fullNormal; Removed = $true }
}
