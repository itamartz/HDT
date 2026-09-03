function Get-HDTMedia {
    <#
        .SYNOPSIS
            Reads a standalone media definition, or every one on the share, out
            of the workspace.

        .DESCRIPTION
            THE CATALOG IS THE DIRECTORY, exactly as it is for applications.
            Every media item gets a folder under Media\ holding its media.yaml,
            the ISO built from it and the manifest that records that build, so
            there is no single catalog file to parse - reading one item is a read
            of one media.yaml, and reading the catalog is an enumeration of that
            folder. Two administrators adding media never collide in one file,
            and a folder copy moves an item whole.

            It reads through an injected IFileSystem - never Get-Content - so the
            whole authoring path is provable under Pester with no share and no
            disk.

            Four steps per item, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTMediaDocument, which names the file and
                 the offending key - and is handed the FOLDER too, so a document
                 whose id disagrees with the folder it sits in is reported here
                 rather than becoming a path nothing can find;
              4. project with ConvertTo-HDTMediaCatalog, which resolves
                 OutputPath and applies every default.

            A FOLDER WITH NO media.yaml IS NOT A MEDIA DEFINITION, and
            enumeration skips it. A share people actually use collects stray
            folders, and a console that threw over one would be unusable. A
            folder that DOES hold a media.yaml and gets it wrong is a different
            thing entirely, and that fails naming the file.

            A WORKSPACE WITH NO Media\ FOLDER RETURNS NOTHING rather than
            failing. Standalone media is optional, and a share created before
            Media\ was part of the layout has not got one - New-HDTWorkspace
            never writes over an existing share.

            A MANIFEST THAT WILL NOT PARSE IS A MISSING MANIFEST, not a failed
            read. It records the last build; the media definition is the document
            beside it, and a half-written JSON file must not make an item
            unreadable in the console.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The media id, which is the folder name under Media\. Omit it to read
            every media definition in the workspace.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Id, Name, Description, SelectionProfile, Output, OutputPath,
              Enabled, Folder, DocumentPath, LastBuildUtc, IsoPath,
              IsoSizeBytes, IsoSha256 and WorkspaceRoot.

            LastBuildUtc is $null and the three Iso values are empty for an item
            that has never been built.

        .EXAMPLE
            Get-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share'

            Every media definition on the share, in folder order.

        .EXAMPLE
            (Get-HDTMedia -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WIN11-FIELD').OutputPath

            Where the next build of that item will write its ISO.

        .LINK
            New-HDTMedia

        .LINK
            Set-HDTMedia

        .LINK
            Remove-HDTMedia
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        # DEFAULTED, NOT MANDATORY, for the reason recorded on
        # Get-HDTApplication's own -FileSystem: reading the catalog is the first
        # thing an administrator types, and a mandatory service parameter makes
        # that call fail with an error about a parameter they do not have.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline, and a
    # flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $readOne = {
            param([string] $MediaId)

            $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $MediaId
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $MediaId, 'media.yaml'
            $manifestPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $MediaId, 'media.manifest.json'

            $text = $FileSystem.ReadAllText($catalogPath)

            $document = ConvertFrom-HDTYaml -Yaml $text -Path $catalogPath
            Assert-HDTMediaDocument -Document $document -Path $catalogPath -Id $MediaId

            # THE MANIFEST IS BEST-EFFORT. See the description: a broken one is a
            # missing one, because the media definition is the document and not
            # the record of what happened to it last Tuesday.
            $manifest = $null

            if ($FileSystem.TestPath($manifestPath)) {
                try {
                    $manifest = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText($manifestPath))
                } catch {
                    $manifest = $null
                }
            }

            $entry = ConvertTo-HDTMediaCatalog -Document $document -WorkspaceRoot $WorkspaceRoot `
                -Folder $folder -CatalogPath $catalogPath -Manifest $manifest

            # WHERE IT CAME FROM TRAVELS WITH IT. Without this, piping an entry
            # at Set- or Remove- binds the id and then asks for the share the
            # caller has just named, which is the point at which somebody stops
            # using the pipeline.
            $entry | Add-Member -NotePropertyName 'WorkspaceRoot' `
                -NotePropertyValue $WorkspaceRoot -Force

            return $entry
        }

        if ($PSBoundParameters.ContainsKey('Id')) {
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $Id, 'media.yaml'

            if (-not $FileSystem.TestPath($catalogPath)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                            -Message ("no media definition with the id '{0}' is in this workspace. A media definition is a folder under Media\ holding a media.yaml." -f $Id) `
                            -Category ObjectNotFound))
            }

            return (& $readOne $Id)
        }

        $mediaRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media

        if (-not $FileSystem.TestPath($mediaRoot)) { return }

        foreach ($child in @($FileSystem.GetChildItem($mediaRoot))) {
            $childId = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Media -ChildPath $childId, 'media.yaml'

            if (-not $FileSystem.TestPath($catalogPath)) { continue }

            & $readOne $childId
        }
    }
}
