function Remove-HDTTaskSequence {
    <#
        .SYNOPSIS
            Removes a task sequence and the folder it lives in.

        .DESCRIPTION
            THE ONLY AUTHORING COMMAND THAT DELETES. Everything else in this
            toolkit splices lines and hands them back for Save-HDTSequenceDocument
            to write; this one takes a directory away, so every refusal below is
            about what it might delete INSTEAD of what it was asked to.

            THE ID IS THE FOLDER NAME - TaskSequences\<id>\sequence.yaml - which
            makes a separator, a colon or a '..' in it a PATH rather than a name.
            A delete built from one of those leaves the share it was pointed at,
            so the id is refused before anything is resolved, and the resolved
            path is checked to still sit under the workspace afterwards. Belt and
            braces, because the cost of being wrong here is somebody else's data.

            A FOLDER HOLDING NO sequence.yaml IS NOT A TASK SEQUENCE, and it is
            not removed. A folder under TaskSequences\ that somebody put notes in
            would otherwise be deleted on the strength of where it sits.

            IT REMOVES THE WHOLE FOLDER, not just the document: a sequence keeps
            its unattend.xml, and any script it names, beside it. Leaving those
            behind would leave a folder that looks like a sequence to anything
            that lists the directory.

            ConfirmImpact IS High, so it prompts unless the caller says
            -Confirm:$false. The console's Remove asks in its own dialog first
            and then passes that, which is the same decision made once.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER Id
            The sequence to remove, which is also its folder name.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id and Path.

        .EXAMPLE
            Remove-HDTTaskSequence -Workspace C:\HDTLab\Share -Id DEMO-05

        .EXAMPLE
            Remove-HDTTaskSequence -Workspace C:\HDTLab\Share -Id DEMO-05 -WhatIf

            What it would take, without taking it.

        .LINK
            New-HDTTaskSequence
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
                    -Message ("'{0}' cannot be a task sequence id. An id is a folder name: no spaces, and none of \\ / : * ? "" < > |. This command deletes the folder it names, so an id that is a path is refused rather than resolved." -f $Id)))
    }

    $folder = Get-HDTWorkspacePath -Root $Workspace -Kind TaskSequences -ChildPath $Id
    $document = Join-Path -Path $folder -ChildPath 'sequence.yaml'

    # -- and the path, after ---------------------------------------------------
    #
    # THE SECOND CHECK IS NOT THE FIRST ONE AGAIN. That one judged what was
    # typed; this judges what it resolved to, which is the thing about to be
    # removed. A delete target must be provably inside the share.
    $sequenceRoot = Get-HDTWorkspacePath -Root $Workspace -Kind TaskSequences

    if (-not ([System.IO.Path]::GetFullPath($folder)).StartsWith(
            ([System.IO.Path]::GetFullPath($sequenceRoot)).TrimEnd('\') + '\',
            [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' resolves to '{1}', which is not inside this workspace's TaskSequences folder. Nothing was removed." -f $Id, $folder)))
    }

    # -- is it a task sequence at all? ----------------------------------------

    if (-not $FileSystem.TestPath($folder)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder -Category ObjectNotFound `
                    -Message ("this workspace has no task sequence called '{0}'." -f $Id)))
    }

    if (-not $FileSystem.TestPath($document)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                    -Message ("'{0}' holds no sequence.yaml, so it is not a task sequence - it is a folder that happens to sit under TaskSequences. Remove it yourself if that is what you meant." -f $folder)))
    }

    if (-not $PSCmdlet.ShouldProcess($folder, ("Remove task sequence '{0}' and everything in its folder" -f $Id))) {
        return [pscustomobject] @{
            Id   = $Id
            Path = $folder
        }
    }

    $FileSystem.RemoveItem($folder, $true)

    return [pscustomobject] @{
        Id   = $Id
        Path = $folder
    }
}
