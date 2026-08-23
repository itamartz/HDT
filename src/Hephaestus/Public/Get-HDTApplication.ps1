function Get-HDTApplication {
    <#
        .SYNOPSIS
            Reads an application, or the whole application catalog, out of the
            workspace.

        .DESCRIPTION
            THE CATALOG IS THE DIRECTORY. DESIGN 2.1 gives every application a
            folder under Applications\ holding its app.yaml and its source\
            payload, so there is no single catalog file to parse - reading one
            application is a read of one app.yaml, and reading the catalog is an
            enumeration of that folder. Two administrators adding applications
            never collide in one file, and a folder copy moves an application
            whole.

            It reads through an injected IFileSystem - never Get-Content - so the
            whole authoring path is provable under Pester with no share and no
            disk.

            Four steps per application, and a failure at any of them is a
            terminating HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTApplicationDocument, which names the file
                 and the offending key;
              4. project with ConvertTo-HDTApplicationCatalog, which resolves
                 SourcePath and applies every default.

            A FOLDER WITH NO app.yaml IS NOT AN APPLICATION, and enumeration skips
            it. A share people actually use collects stray folders, and a console
            that threw over one would be unusable. A folder that DOES hold an
            app.yaml and gets it wrong is a different thing entirely, and that
            fails naming the file.

            A WORKSPACE WITH NO Applications\ FOLDER RETURNS NOTHING rather than
            failing. Applications are optional; a workspace that deploys an image
            and no software is a legitimate workspace.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id, which is the folder name under Applications\. Omit it
            to read every application in the workspace.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .PARAMETER Content
            An IContentProvider, or nothing. When supplied, SourcePath is what it
            answered for Applications\<id>\source.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              SchemaVersion, Id, Name, Description, Install, Uninstall,
              SuccessCodes, RebootCodes, Detect, Dependencies, RunIn, Path,
              AppFolder and SourcePath.

            Detect is $null for an application that declares no detection rule,
            which is DESIGN 8's "install every time".

        .EXAMPLE
            Get-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id '7Zip-24.09'

        .EXAMPLE
            Get-HDTApplication -WorkspaceRoot 'X:\Deploy' |
                Where-Object { $_.Dependencies.Count -gt 0 }

            The whole catalog, which is what Resolve-HDTApplicationOrder is handed.
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

        # DEFAULTED, NOT MANDATORY, as it is on Import, Set and Remove. This was
        # the one command of the five that refused a plain call: reading the
        # catalog is the first thing anybody types, and it answered with an
        # error about a parameter no administrator has.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        [Parameter()]
        [AllowNull()]
        [object] $Content = $null
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline, and a
    # flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $readOne = {
            param([string] $ApplicationId)

            $appFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $ApplicationId
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $ApplicationId, 'app.yaml'

            $text = $FileSystem.ReadAllText($catalogPath)

            $document = ConvertFrom-HDTYaml -Yaml $text -Path $catalogPath
            Assert-HDTApplicationDocument -Document $document -Path $catalogPath

            try {
                $entry = ConvertTo-HDTApplicationCatalog -Document $document -AppFolder $appFolder `
                    -CatalogPath $catalogPath -Content $Content

                # WHERE IT CAME FROM TRAVELS WITH IT. Without this, piping an entry
                # at Set- or Remove- binds the id and then asks for the share the
                # caller has just named, which is the point at which somebody stops
                # using the pipeline.
                $entry | Add-Member -NotePropertyName 'WorkspaceRoot' `
                    -NotePropertyValue $WorkspaceRoot -Force

                return $entry
            } catch {
                # A provider refusal - a path that escapes the content root - is
                # reported naming app.yaml rather than surfacing as a
                # MethodInvocationException from a ScriptMethod three frames down.
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                            -Message ("the application source path could not be resolved: {0}" -f [string] $_.Exception.Message)))
            }
        }

        if ($PSBoundParameters.ContainsKey('Id')) {
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id, 'app.yaml'

            if (-not $FileSystem.TestPath($catalogPath)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                            -Message ("no application with the id '{0}' is in this workspace. An application is a folder under Applications\ holding an app.yaml." -f $Id) `
                            -Category ObjectNotFound))
            }

            return (& $readOne $Id)
        }

        $applicationRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications

        if (-not $FileSystem.TestPath($applicationRoot)) { return }

        foreach ($child in @($FileSystem.GetChildItem($applicationRoot))) {
            $childId = [System.IO.Path]::GetFileName([string] $child)
            $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $childId, 'app.yaml'

            if (-not $FileSystem.TestPath($catalogPath)) { continue }

            & $readOne $childId
        }
    }
}
