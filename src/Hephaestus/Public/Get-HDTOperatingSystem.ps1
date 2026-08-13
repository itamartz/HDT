function Get-HDTOperatingSystem {
    <#
        .SYNOPSIS
            Reads an operating system out of the workspace catalog.

        .DESCRIPTION
            The read half of DESIGN 9.3's catalog. It reads
            OperatingSystems\<id>\os.yaml through an injected IFileSystem - never
            Get-Content - so the whole authoring path is provable under Pester
            with no share, no media and no disk (PROJECT constraint 4).

            Four steps, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTOperatingSystemDocument, which names the
                 file and the offending key;
              4. project, resolving ImagePath.

            ImagePath IS THE SEAM M4 REPLACES. DESIGN 6 abstracts content access
            behind Resolve-Content / Copy-Content / Test-Content, and M4 ships the
            Smb and Local providers. Until then this resolves an image path from
            the workspace root it is given, which is exactly what a provider would
            return for Local. When M4 lands, ApplyImage changes from "ask the
            catalog" to "ask the provider" and no step logic moves. A rooted
            sourcePath is kept as it is, because media too large to bring into
            the share is registered where it stands.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id, which is the folder name under OperatingSystems\.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              SchemaVersion, Id, Name, Description, Type, Architecture,
              SourcePath, ImportedUtc, DefaultIndex, Path, OsFolder, ImagePath
              and Images - one row per index carrying Index, Name, Description,
              Edition, SizeBytes and Version.

        .EXAMPLE
            Get-HDTOperatingSystem -WorkspaceRoot 'X:\Deploy' -Id 'Win11-LTSC-2024' -FileSystem (New-HDTFileSystem)

        .EXAMPLE
            $os = Get-HDTOperatingSystem -WorkspaceRoot $root -Id $id -FileSystem $fs
            Resolve-HDTImageIndex -Image $os.Images -Edition EnterpriseS

            The catalog and the index resolver, which is how ApplyImage will use
            both.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $osFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $Id
    $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $Id, 'os.yaml'

    if (-not $FileSystem.TestPath($catalogPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                    -Message ("no operating system with the id '{0}' is in this workspace. Import one with Import-HDTOperatingSystem." -f $Id) `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($catalogPath)

    $document = ConvertFrom-HDTYaml -Yaml $text -Path $catalogPath
    Assert-HDTOperatingSystemDocument -Document $document -Path $catalogPath

    return (ConvertTo-HDTOperatingSystemCatalog -Document $document -OsFolder $osFolder -CatalogPath $catalogPath)
}
