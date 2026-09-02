function Remove-HDTWindowsUpdate {
    <#
        .SYNOPSIS
            Removes an imported Windows update from a deployment share.

        .DESCRIPTION
            THE OTHER HALF OF Import-HDTWindowsUpdate, and until it existed an
            update filed against the wrong release had to be removed with
            Explorer - which is how somebody deletes the wrong folder. MDT offers
            Delete on the right-click menu of its Packages node; this is the
            command behind HDT's.

            IT IS Remove-HDTOperatingSystem'S TWIN, deliberately, down to the two
            checks on the id: once as typed - no separators, no spaces, not . or
            .. - and once as resolved, because what matters is where it ended up
            rather than how it looked. A target that is not provably inside this
            share's WindowsUpdates folder is refused with nothing removed.

            THE FOLDER IS THE UNIT, AND THAT IS THE POINT. update.yaml names
            the .msu beside it by file name and nothing else records where the
            package is, so removing the document without the package - or the
            package without the document - leaves a catalog entry pointing at a
            file that is gone. Nothing on the console would show it; the
            ApplyUpdates step would find out offline, inside an applied image,
            minutes into a deployment. So both go together or neither goes.

            A FOLDER WITH NO update.yaml IS NOT AN IMPORTED UPDATE. It is
            somebody's staging directory that happens to sit under
            WindowsUpdates\, and this command must not be the thing that removes
            it.

            WHICH SEQUENCES WOULD HAVE APPLIED IT IS REPORTED, NOT ENFORCED,
            and "applied it" is two questions rather than one. A step that names
            a RELEASE points at no folder by name, so removing this update breaks
            nothing: the machine simply arrives without it. A step whose
            `updates` NAMES THIS ID does point here by name, and
            Invoke-HDTApplyUpdatesStep refuses an id the share does not have -
            so that one fails at the machine rather than deploying without it.

            BOTH ARE REPORTED AND NEITHER IS ENFORCED. An administrator deleting
            a superseded update should not be stopped by a sequence they are
            about to edit; they should be told which sequences to look at, which
            is what UsedBy is.

            ConfirmImpact IS High, so it prompts unless the caller says
            -Confirm:$false. The console says it, having asked in its own dialog.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share. Named as
            Get-HDTWindowsUpdate and Import-HDTWindowsUpdate name it, because the
            console echoes this line for somebody to retype.

        .PARAMETER Id
            The update's catalog id - the folder name under WindowsUpdates\,
            e.g. KB5094126-x64.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one; a test passes
            New-HDTFakeFileSystem and this is provable with no share.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Release, Path
            and UsedBy - the ids of the task sequences that would have applied it.

        .EXAMPLE
            Remove-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Id 'KB5094126-x64' -WhatIf

            Describes what it would remove, including which task sequences apply
            this release, and deletes nothing. Worth running first: a cumulative
            update is most of a gigabyte somebody downloaded.

        .EXAMPLE
            Get-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' | Format-Table Id, Kb, Release

            What is on the share, and the ids -Id takes.

        .LINK
            Import-HDTWindowsUpdate

        .LINK
            Get-HDTWindowsUpdate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # -- the id, before it becomes a path ------------------------------------

    if ($Id -match '[\\/:*?"<>|]' -or $Id -match '\s' -or $Id -eq '.' -or $Id -eq '..') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' cannot be a Windows update id. An id is a folder name: no spaces, and none of \ / : * ? `" < > |. This command deletes the folder it names, so an id that is a path is refused rather than resolved." -f $Id)))
    }

    $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id
    $document = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id, 'update.yaml'

    # -- and the path, after -------------------------------------------------
    #
    # THE SECOND CHECK IS NOT THE FIRST ONE AGAIN. That one judged what was
    # typed; this judges what it resolved to, which is the thing about to be
    # removed.
    $updateRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates

    if (-not ([System.IO.Path]::GetFullPath($folder)).StartsWith(
            ([System.IO.Path]::GetFullPath($updateRoot)).TrimEnd('\') + '\',
            [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' resolves to '{1}', which is not inside this workspace's WindowsUpdates folder. Nothing was removed." -f $Id, $folder)))
    }

    # -- is it an imported update at all? ------------------------------------

    if (-not $FileSystem.TestPath($folder)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder -Category ObjectNotFound `
                    -Message ("this workspace has no Windows update called '{0}'." -f $Id)))
    }

    if (-not $FileSystem.TestPath($document)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' holds no update.yaml, so it is not an imported Windows update - it is a folder that happens to sit under WindowsUpdates. Remove it yourself if that is what you meant." -f $folder)))
    }

    # -- what it is, before it is gone ---------------------------------------
    #
    # THE RELEASE IS READ OFF THE DOCUMENT, because the question below is asked
    # about the release and not about the id. A document that will not parse is
    # not a reason to refuse the delete - it is a reason this update cannot be
    # used, which is very likely why somebody is removing it.
    $release = ''

    try {
        $parsed = ConvertFrom-HDTYaml -Yaml ($FileSystem.ReadAllText($document)) -Path $document
        if ($parsed.Contains('release')) { $release = [string] $parsed['release'] }
    } catch {
        $release = ''
    }

    # -- who would have applied it -------------------------------------------
    #
    # READ BEFORE THE DELETE, because afterwards the package is gone and the
    # answer is the same. A sequence that will not read is skipped rather than
    # failing the removal: it has its own broken row in the console already.
    $usedBy = New-Object -TypeName System.Collections.ArrayList
    $sequenceRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind TaskSequences

    if (-not [string]::IsNullOrWhiteSpace($release) -and $FileSystem.TestPath($sequenceRoot)) {
        foreach ($child in @($FileSystem.GetChildItem($sequenceRoot))) {

            $sequencePath = [System.IO.Path]::Combine([string] $child, 'sequence.yaml')
            if (-not $FileSystem.TestPath($sequencePath)) { continue }

            $named = ''

            try {
                $sequence = ConvertFrom-HDTYaml -Yaml ($FileSystem.ReadAllText($sequencePath)) -Path $sequencePath

                if (-not (Test-HDTSequenceAppliesUpdate -Document $sequence -Release $release -Id $Id)) { continue }

                $named = [string] $sequence['id']
            } catch {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($named)) {
                $named = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            }

            [void] $usedBy.Add($named)
        }
    }

    $said = "Remove Windows update '{0}' and everything in its folder" -f $Id
    if (@($usedBy).Count -gt 0) {
        # 'apply this update' AND NOT 'apply this release', because the list can
        # now hold both kinds: a sequence matched on its release and one that
        # named this id in `updates`. The release wording would describe half of
        # them wrongly, and it is the half that fails at the machine.
        $said = '{0}. These task sequences apply this update: {1}' -f $said, (@($usedBy) -join ', ')
    }

    if (-not $PSCmdlet.ShouldProcess($folder, $said)) {
        return [pscustomobject] @{
            Id      = $Id
            Release = $release
            Path    = $folder
            UsedBy  = [string[]] @($usedBy)
        }
    }

    $FileSystem.RemoveItem($folder, $true)

    return [pscustomobject] @{
        Id      = $Id
        Release = $release
        Path    = $folder
        UsedBy  = [string[]] @($usedBy)
    }
}
