function Get-HDTOperatingSystem {
    <#
        .SYNOPSIS
            Reads an operating system out of the workspace catalog.

        .DESCRIPTION
            The read half of DESIGN 9.3's catalog. It reads
            OperatingSystems\<id>\os.yaml through an injected IFileSystem - never
            Get-Content - so the whole authoring path is provable under Pester
            with no share, no media and no disk.

            Four steps, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTOperatingSystemDocument, which names the
                 file and the offending key;
              4. project, resolving ImagePath.

            ImagePath IS THE SEAM 04-02 MARKED AND 05-02 CLOSED. DESIGN 6
            abstracts content access behind a provider, and -Content is where one
            arrives: given one, ImagePath is what the provider answered; given
            none, it is resolved from the workspace root exactly as before, which
            is what an administrator importing on a workstation gets.

            ApplyImage changed from "ask the catalog" to "ask the provider" by
            passing $Context.Service.Content, and NO STEP LOGIC MOVED - asserted
            by running the same step through the Local and the Smb providers and
            comparing the ordered list of every service call
            (tests/unit/Invoke-HDTApplyImageStep.Tests.ps1, DESIGN 6.2).

            A rooted sourcePath is kept as it is, provider or no provider,
            because media too large to bring into the share is registered where
            it stands.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id, which is the folder name under OperatingSystems\.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .PARAMETER Content
            An IContentProvider, or nothing. When supplied, ImagePath is what it
            answered for the relative sourcePath; a refusal is reported as a
            configuration error naming os.yaml, because a sourcePath that climbs
            out of the workspace is a mistake in that file.

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
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Content = $null
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

    try {
        return (ConvertTo-HDTOperatingSystemCatalog -Document $document -OsFolder $osFolder `
                -CatalogPath $catalogPath -Content $Content)
    } catch {
        # A provider refusal - a sourcePath that escapes the content root - is a
        # mistake in os.yaml, so it is reported naming os.yaml rather than
        # surfacing as a MethodInvocationException from a ScriptMethod three
        # frames down.
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                    -Message ("the image path could not be resolved: {0}" -f [string] $_.Exception.Message)))
    }
}
