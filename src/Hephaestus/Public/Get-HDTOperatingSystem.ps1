function Get-HDTOperatingSystem {
    <#
        .SYNOPSIS
            Reads an operating system out of the workspace catalog.

        .DESCRIPTION
            The read half of the OS catalog. It reads
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

            ImagePath IS THE SEAM 04-02 MARKED AND 05-02 CLOSED. HDT
            abstracts content access behind a provider, and -Content is where one
            arrives: given one, ImagePath is what the provider answered; given
            none, it is resolved from the workspace root exactly as before, which
            is what an administrator importing on a workstation gets.

            ApplyImage changed from "ask the catalog" to "ask the provider" by
            passing $Context.Service.Content, and NO STEP LOGIC MOVED - asserted
            by running the same step through the Local and the Smb providers and
            comparing the ordered list of every service call
            (tests/unit/Invoke-HDTApplyImageStep.Tests.ps1).

            A rooted sourcePath is kept as it is, provider or no provider,
            because media too large to bring into the share is registered where
            it stands.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id, which is the folder name under OperatingSystems\.
            Omit it to read every operating system on the share - which is the
            answer to "what is on here", and how Get-HDTApplication has always
            behaved.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.
            Defaults to the real one.

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
            $fs = New-HDTFileSystem
            $root = 'C:\HDTLab\Share'
            $id = 'Win11-LTSC-2024'
            Get-HDTOperatingSystem -WorkspaceRoot 'X:\Deploy' -Id 'Win11-LTSC-2024'

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

        # OPTIONAL, AS IT IS ON Get-HDTApplication. It was mandatory here, so
        # "what operating systems are on this share?" had no answer that did not
        # involve listing the folder by hand - and the two readers of the same
        # share behaved differently for no reason anybody could state.
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Content = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $readOne = {
        param([string] $OperatingSystemId)

        $osFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $OperatingSystemId
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $OperatingSystemId, 'os.yaml'

        $text = $FileSystem.ReadAllText($catalogPath)

        $document = ConvertFrom-HDTYaml -Yaml $text -Path $catalogPath
        Assert-HDTOperatingSystemDocument -Document $document -Path $catalogPath

        try {
            return (ConvertTo-HDTOperatingSystemCatalog -Document $document -OsFolder $osFolder `
                    -CatalogPath $catalogPath -Content $Content)
        } catch {
            # A provider refusal - a sourcePath that escapes the content root -
            # is a mistake in os.yaml, so it is reported naming os.yaml rather
            # than surfacing as a MethodInvocationException from a ScriptMethod
            # three frames down.
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                        -Message ("the image path could not be resolved: {0}" -f [string] $_.Exception.Message)))
        }
    }

    # AN ID THAT WAS ASKED FOR AND IS NOT THERE IS STILL AN ERROR. Silence is
    # the right answer to "what is on this share"; it is the wrong answer to
    # "read me this one".
    if ($PSBoundParameters.ContainsKey('Id')) {
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $Id, 'os.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                        -Message ("no operating system with the id '{0}' is in this workspace. Import one with Import-HDTOperatingSystem." -f $Id) `
                        -Category ObjectNotFound))
        }

        return (& $readOne $Id)
    }

    # THE CATALOG IS THE DIRECTORY (DESIGN 2.1), so reading all of them is an
    # enumeration - and a folder with no os.yaml is somebody's staging
    # directory, not an operating system, exactly as it is under Applications\.
    $operatingSystemRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems

    if (-not $FileSystem.TestPath($operatingSystemRoot)) { return }

    foreach ($child in @($FileSystem.GetChildItem($operatingSystemRoot))) {
        $childId = [System.IO.Path]::GetFileName([string] $child)
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind OperatingSystems -ChildPath $childId, 'os.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) { continue }

        & $readOne $childId
    }
}
