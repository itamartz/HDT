function Remove-HDTOperatingSystem {
    <#
        .SYNOPSIS
            Removes an imported operating system from a deployment share.

        .DESCRIPTION
            THE OTHER HALF OF Import-HDTOperatingSystem, and until it existed an
            OS imported by mistake had to be removed with Explorer - which is
            how somebody deletes the wrong folder. Deployment Workbench offers
            Delete on the right-click menu of an imported OS; this is the
            command behind it.

            IT DELETES A FOLDER, so the guards are the ones CLAUDE.md demands of
            anything that does. The id names a folder under OperatingSystems\
            and is checked TWICE: once as typed - no separators, no spaces, not
            . or .. - and once as resolved, because what matters is where it
            ended up rather than how it looked. A target that is not provably
            inside this share's OperatingSystems folder is refused with nothing
            removed.

            A FOLDER WITH NO os.yaml IS NOT AN OPERATING SYSTEM. It is somebody's
            staging directory that happens to sit under OperatingSystems\, and
            this command must not be the thing that removes it.

            WHICH SEQUENCES WERE USING IT IS REPORTED, NOT ENFORCED. Removing
            media a sequence applies leaves a deployment that fails at Apply
            Operating System - minutes in, on the machine in front of somebody -
            so every sequence naming this id comes back in UsedBy. It is not a
            refusal: an administrator replacing media knows more than this
            command does, and a delete that could not be completed because
            something referred to it is a delete nobody can ever do.

            ConfirmImpact IS High, so it prompts unless the caller says
            -Confirm:$false. The console says it, having asked in its own dialog.

        .PARAMETER Workspace
            The share's root.

        .PARAMETER Id
            The operating system's id - the folder name under OperatingSystems\.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Path and
            UsedBy - the ids of the task sequences that named it.

        .EXAMPLE
            Remove-HDTOperatingSystem -Workspace 'C:\HDTLab\Share' -Id 'WS2025-Std'

        .LINK
            Import-HDTOperatingSystem
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

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
                    -Message ("'{0}' cannot be an operating system id. An id is a folder name: no spaces, and none of \ / : * ? `" < > |. This command deletes the folder it names, so an id that is a path is refused rather than resolved." -f $Id)))
    }

    $folder = Get-HDTWorkspacePath -Root $Workspace -Kind OperatingSystems -ChildPath $Id
    $document = Join-Path -Path $folder -ChildPath 'os.yaml'

    # -- and the path, after -------------------------------------------------
    #
    # THE SECOND CHECK IS NOT THE FIRST ONE AGAIN. That one judged what was
    # typed; this judges what it resolved to, which is the thing about to be
    # removed.
    $operatingSystemRoot = Get-HDTWorkspacePath -Root $Workspace -Kind OperatingSystems

    if (-not ([System.IO.Path]::GetFullPath($folder)).StartsWith(
            ([System.IO.Path]::GetFullPath($operatingSystemRoot)).TrimEnd('\') + '\',
            [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' resolves to '{1}', which is not inside this workspace's OperatingSystems folder. Nothing was removed." -f $Id, $folder)))
    }

    # -- is it an imported operating system at all? --------------------------

    if (-not $FileSystem.TestPath($folder)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder -Category ObjectNotFound `
                    -Message ("this workspace has no operating system called '{0}'." -f $Id)))
    }

    if (-not $FileSystem.TestPath($document)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' holds no os.yaml, so it is not an imported operating system - it is a folder that happens to sit under OperatingSystems. Remove it yourself if that is what you meant." -f $folder)))
    }

    # -- who was using it ----------------------------------------------------
    #
    # READ BEFORE THE DELETE, because afterwards the answer is the same and the
    # media is gone. A sequence that will not read is skipped rather than
    # failing the removal: it has its own broken row in the console already.
    $usedBy = New-Object -TypeName System.Collections.ArrayList
    $sequenceRoot = Get-HDTWorkspacePath -Root $Workspace -Kind TaskSequences

    if ($FileSystem.TestPath($sequenceRoot)) {
        foreach ($child in @($FileSystem.GetChildItem($sequenceRoot))) {

            $sequencePath = Join-Path -Path ([string] $child) -ChildPath 'sequence.yaml'
            if (-not $FileSystem.TestPath($sequencePath)) { continue }

            $text = [string] $FileSystem.ReadAllText($sequencePath)

            # THE KEY IS operatingSystem OR os, because both spellings reach the
            # ApplyImage step - matching the id anywhere in the file would count
            # a sequence that merely mentions it in a comment.
            if ($text -notmatch ('(?m)^\s*(operatingSystem|os)\s*:\s*[''"]?{0}[''"]?\s*$' -f [regex]::Escape($Id))) { continue }

            $named = ''

            try {
                $parsed = ConvertFrom-HDTYaml -Yaml $text -Path $sequencePath
                $named = [string] $parsed['id']
            } catch {
                $named = ''
            }

            if ([string]::IsNullOrWhiteSpace($named)) {
                $named = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            }

            [void] $usedBy.Add($named)
        }
    }

    $said = "Remove operating system '{0}' and everything in its folder" -f $Id
    if (@($usedBy).Count -gt 0) {
        $said = '{0}. It is named by: {1}' -f $said, (@($usedBy) -join ', ')
    }

    if (-not $PSCmdlet.ShouldProcess($folder, $said)) {
        return [pscustomobject] @{
            Id     = $Id
            Path   = $folder
            UsedBy = [string[]] @($usedBy)
        }
    }

    $FileSystem.RemoveItem($folder, $true)

    return [pscustomobject] @{
        Id     = $Id
        Path   = $folder
        UsedBy = [string[]] @($usedBy)
    }
}
