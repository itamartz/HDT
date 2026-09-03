function Remove-HDTMedia {
    <#
        .SYNOPSIS
            Removes a standalone media definition from a deployment share.

        .DESCRIPTION
            THE OTHER HALF OF New-HDTMedia. Deployment Workbench offers Delete on
            the right-click menu of a media item; this is the command behind it.

            IT DELETES A FOLDER, so the guards are the ones CLAUDE.md demands of
            anything that does. The id names a folder under Media\ and is checked
            TWICE: once as typed - no separators, no wildcards, no spaces, not
            '.' or '..' - and once as resolved, because what matters is where it
            ended up rather than how it looked. A target that is not provably
            inside this share's Media folder is refused with nothing removed. The
            two overlap, and that is the point: every way of escaping Media\
            carries a separator, so the second check has nothing left to catch -
            it is a backstop, and a recursive delete is worth two cheap checks.

            A FOLDER WITH NO media.yaml IS NOT A MEDIA DEFINITION. It is somebody's
            staging directory that happens to sit under Media\, and this command
            must not be the thing that removes it.

            AN ISO OUTSIDE THE FOLDER IS NAMED AND LEFT. output may be rooted
            anywhere - another disk, another server - which is the whole reason a
            rooted output is legal, and CLAUDE.md's protected-path rule says what
            follows: a delete target is never built by expanding a variable
            somebody typed a year ago. One thing is removed here, the media
            folder, and an ISO that is not inside it is reported in a warning and
            on the returned object so a console can say so before anybody agrees
            to anything.

            ConfirmImpact IS High, so it prompts unless the caller says
            -Confirm:$false. The console says it, having asked in its own dialog.

        .PARAMETER WorkspaceRoot
            The share's root.

        .PARAMETER Id
            The media id - the folder name under Media\.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            System.Management.Automation.PSCustomObject with WorkspaceRoot and Id
            - which is what Get-HDTMedia returns.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Path and
            IsoLeftBehind - the ISO this command did not delete, or an empty
            string when the ISO went with the folder.

        .EXAMPLE
            Remove-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD'

        .EXAMPLE
            (Remove-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD' -WhatIf).IsoLeftBehind

            Which ISO would be orphaned, without removing anything.

        .LINK
            New-HDTMedia

        .LINK
            Get-HDTMedia
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Media is a mass noun here and the singular name of one object - MDT calls the Deployment Workbench node Media and its action Update Media Content, and DESIGN 6.2 names these four commands. The analyzer reads it as the Latin plural of medium. Renaming to MediaItem would make HDT the only toolkit an MDT admin has to translate.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline, and a
    # flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        # FIRST LINE, BEFORE ANYTHING PASSES IT ON. Get-HDTMedia's own
        # -FileSystem is ValidateNotNull, so handing it a $null that was never
        # resolved throws on the parameter instead of doing the work.
        if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

        # -- the id, before it becomes a path ---------------------------------

        if ($Id -match '[\\/:*?"<>|]' -or $Id -match '\s' -or $Id -eq '.' -or $Id -eq '..') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                        -Message ("'{0}' cannot be a media id. An id is a folder name: no spaces, and none of \ / : * ? `" < > |. This command deletes the folder it names, so an id that is a path is refused rather than resolved." -f $Id)))
        }

        $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id
        $document = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id, 'media.yaml'

        # -- and the path, after ----------------------------------------------
        #
        # THE SECOND CHECK IS NOT THE FIRST ONE AGAIN. That one judged what was
        # typed; this judges what it resolved to, which is the thing about to be
        # removed.
        $mediaRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media

        if (-not ([System.IO.Path]::GetFullPath($folder)).StartsWith(
                ([System.IO.Path]::GetFullPath($mediaRoot)).TrimEnd('\') + '\',
                [System.StringComparison]::OrdinalIgnoreCase)) {

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                        -Message ("'{0}' resolves to '{1}', which is not inside this workspace's Media folder. Nothing was removed." -f $Id, $folder)))
        }

        # -- is it a media definition at all? ---------------------------------

        if (-not $FileSystem.TestPath($folder)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder -Category ObjectNotFound `
                        -Message ("this workspace has no media definition called '{0}'." -f $Id)))
        }

        if (-not $FileSystem.TestPath($document)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                        -Message ("'{0}' holds no media.yaml, so it is not a media definition - it is a folder that happens to sit under Media. Remove it yourself if that is what you meant." -f $folder)))
        }

        # -- where the ISO is, read BEFORE the delete -------------------------
        #
        # Afterwards the document is gone and the answer with it.
        $media = Get-HDTMedia -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem

        $isoLeftBehind = ''
        $outputPath = [string] $media.OutputPath

        if (-not [string]::IsNullOrWhiteSpace($outputPath)) {
            $inside = ([System.IO.Path]::GetFullPath($outputPath)).StartsWith(
                ([System.IO.Path]::GetFullPath($folder)).TrimEnd('\') + '\',
                [System.StringComparison]::OrdinalIgnoreCase)

            if (-not $inside) { $isoLeftBehind = $outputPath }
        }

        $answer = [pscustomobject] @{
            Id            = $Id
            Path          = $folder
            IsoLeftBehind = $isoLeftBehind
        }

        if (-not [string]::IsNullOrEmpty($isoLeftBehind)) {
            Write-Warning ("The ISO for '{0}' is at '{1}', outside the media folder, so it was NOT removed. Delete it yourself if you meant to." -f
                $Id, $isoLeftBehind)
        }

        $said = "Remove media definition '{0}' and everything in its folder" -f $Id
        if (-not [string]::IsNullOrEmpty($isoLeftBehind)) {
            $said = '{0}. The ISO at {1} is outside it and stays' -f $said, $isoLeftBehind
        }

        if (-not $PSCmdlet.ShouldProcess($folder, $said)) { return $answer }

        # THE ONLY RECURSIVE REMOVE IN THIS COMMAND, and its target is the folder
        # both checks above agreed is inside Media\.
        $FileSystem.RemoveItem($folder, $true)

        return $answer
    }
}
