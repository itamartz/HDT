function New-HDTMedia {
    <#
        .SYNOPSIS
            Creates a standalone media definition on a deployment share.

        .DESCRIPTION
            THE OBJECT MDT'S DEPLOYMENT WORKBENCH KEEPS UNDER ADVANCED
            CONFIGURATION -> MEDIA, as YAML. A media item there carries a
            selection profile, a media path and an enabled tick, and Update Media
            Content regenerates it. HDT keeps the same object at
            Media\<id>\media.yaml and Update-HDTMediaContent regenerates it.

            THIS COMMAND BUILDS NOTHING. It writes a document. No content is
            projected, no ADK is touched and no ISO is burnt - all three are
            Update-HDTMediaContent's job, deliberately, so that authoring a media
            item is instant and repeatable and building one is the slow thing an
            administrator asks for on purpose.

            THE SELECTION PROFILE IS CHECKED AGAINST THE SHARE, and this is the
            check that stops a media item whose projection is empty for a reason
            nobody can see. The built-ins need no document, so a hand-made share
            with no Control\selection-profiles.yaml still takes 'everything' or
            'all-drivers'; an authored id has to actually be in that file.

            IT DEFAULTS THE WAY MDT DEFAULTS. selectionProfile is 'everything' -
            a whole share on a disc is the answer somebody making standalone
            media wants first - output is Media\<id>\HDT_<id>.iso, and enabled is
            true. description is written only when there is one: a key present
            and blank reads as a failed template substitution rather than as a
            decision.

            THE DOCUMENT IT COMPOSED IS VALIDATED BEFORE IT IS WRITTEN, by the
            engine's own Assert-HDTMediaDocument, parsed back through
            ConvertFrom-HDTYaml. A command that wrote a document its own
            validator would refuse has left a broken file on the share for
            somebody else to find.

            WHAT IT RETURNS IS WHAT A LATER READ GIVES. The object comes back
            from Get-HDTMedia rather than from a second construction of it here,
            so the two cannot drift.

            THE FILE IS HEADED WITH COMMENTS, and that is why Set-HDTMedia
            splices rather than re-serialising: comments die at parse time, and
            this is a document an administrator hand-edits.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The media id. It becomes the folder name under Media\, and
            Remove-HDTMedia deletes the folder it names, so it is checked as a
            folder name before it becomes a path.

        .PARAMETER Name
            What an administrator reads in the console's Media node and in a
            build log.

        .PARAMETER Description
            Free text - Workbench's Comments box. Omitted, no key is written.

        .PARAMETER SelectionProfile
            Which of the share's content travels onto the disc. Defaults to
            'everything', as MDT's media item does.

        .PARAMETER Output
            The ISO the build writes. Share-relative unless it is rooted.
            Defaults to Media\<id>\HDT_<id>.iso.

        .PARAMETER Enabled
            The tick. A [bool] rather than a [switch] because the value is
            written into a document and -Enabled:$false has to be sayable.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, as Get-HDTMedia returns
            it.

        .EXAMPLE
            New-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD' -Name 'Windows 11 field media'

            The whole share on a disc, written to
            Media\WIN11-FIELD\HDT_WIN11-FIELD.iso, ready for
            Update-HDTMediaContent.

        .EXAMPLE
            New-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD' -Name 'Windows 11 field media' -SelectionProfile 'field-kit' -Output 'D:\Builds\field.iso'

            A projection of one selection profile, built onto another disk
            because a 6 GB ISO does not fit beside the share.

        .LINK
            Get-HDTMedia

        .LINK
            Set-HDTMedia

        .LINK
            Remove-HDTMedia
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description = '',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SelectionProfile = 'everything',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Output = '',

        # A [bool] AND NOT A [switch]. The value is written into a document, and
        # -Enabled:$false has to be sayable - a switch would make "off" the
        # absence of a parameter, which is not a thing this file can record.
        [Parameter()]
        [bool] $Enabled = $true,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

        # -- the id, before it becomes a path ---------------------------------

        if ($Id -notmatch $idPattern) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                        -Message ("'{0}' is not a legal media id. An id is a folder name under Media\: it starts with a letter or a digit and holds only letters, digits, underscore, dot and hyphen - no separators, no spaces, and never '.' or '..'. Remove-HDTMedia deletes the folder it names, which is why it is refused here rather than resolved." -f $Id)))
        }

        $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id, 'media.yaml'

        if ($FileSystem.TestPath($catalogPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                        -Message ("this share already has a media definition called '{0}', and New-HDTMedia never replaces one. Edit it with Set-HDTMedia, or create the new one under a different id." -f $Id)))
        }

        # -- the profile, checked against the share ---------------------------
        #
        # -FileSystem IS PASSED ON, AND THAT IS NOT OPTIONAL. Get-HDTSelectionProfile
        # defaults it to the REAL adapter, so a call that omitted it would read
        # the actual disk while every other line of this command read the one it
        # was handed - and the answer would depend on whether this machine
        # happens to have a share at that path.
        $available = @(Get-HDTSelectionProfile -Root $WorkspaceRoot -FileSystem $FileSystem)

        if (@($available | Where-Object { $_.Id -eq $SelectionProfile }).Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $SelectionProfile `
                        -Message ("no selection profile with the id '{0}' is on this share, so this media item would project content nobody could name. The ids it has are {1}." -f
                            $SelectionProfile, (@($available | ForEach-Object { $_.Id }) -join ', ')) `
                        -Category ObjectNotFound))
        }

        # -- where the ISO goes -----------------------------------------------
        #
        # COMPOSED RELATIVE AND LEFT RELATIVE. The share is authored on one
        # machine and built on another, so a default expanded to a drive letter
        # here is the one value that is certainly wrong later; Get-HDTMedia
        # resolves it against the workspace root at read time.
        $writtenOutput = $Output
        if ([string]::IsNullOrWhiteSpace($writtenOutput)) {
            $writtenOutput = [System.IO.Path]::Combine('Media', $Id, ('HDT_{0}.iso' -f $Id))
        }

        # -- the document -----------------------------------------------------

        $line = New-Object -TypeName System.Collections.ArrayList

        [void] $line.Add('# HDT standalone media definition - the media item MDT keeps under Advanced Configuration.')
        [void] $line.Add('# Update-HDTMediaContent projects the share through the selection profile below and writes the ISO.')
        [void] $line.Add('')
        [void] $line.Add('schemaVersion: 1')
        [void] $line.Add(('id: {0}' -f (Get-HDTConsoleScalarText -Value $Id)))
        [void] $line.Add(('name: {0}' -f (Get-HDTConsoleScalarText -Value $Name)))

        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            [void] $line.Add(('description: {0}' -f (Get-HDTConsoleScalarText -Value $Description)))
        }

        [void] $line.Add(('selectionProfile: {0}' -f (Get-HDTConsoleScalarText -Value $SelectionProfile)))
        [void] $line.Add(('output: {0}' -f (Get-HDTConsoleScalarText -Value $writtenOutput)))

        # BARE LOWERCASE true/false, which is what ConvertFrom-HDTYaml reads back
        # as a boolean and what Assert-HDTMediaDocument's "enabled must be true
        # or false" refusal expects. Quoted, it would be a string.
        [void] $line.Add(('enabled: {0}' -f $Enabled.ToString().ToLowerInvariant()))

        $text = (@($line) -join [Environment]::NewLine) + [Environment]::NewLine

        # -- validated before it is written -----------------------------------

        $document = ConvertFrom-HDTYaml -Yaml $text -Path $catalogPath
        Assert-HDTMediaDocument -Document $document -Path $catalogPath -Id $Id

        $said = "Create media definition '{0}' - selection profile '{1}', output '{2}'" -f
            $Id, $SelectionProfile, $writtenOutput

        if (-not $PSCmdlet.ShouldProcess($catalogPath, $said)) { return }

        $FileSystem.CreateDirectory($folder)
        $FileSystem.WriteAllText($catalogPath, $text)

        # WHAT A LATER READ GIVES, not a second construction of it.
        return (Get-HDTMedia -WorkspaceRoot $WorkspaceRoot -Id $Id -FileSystem $FileSystem)
    }
}
