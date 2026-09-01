function Get-HDTWindowsUpdate {
    <#
        .SYNOPSIS
            The Windows updates imported into a workspace.

        .DESCRIPTION
            Reads WindowsUpdates\<id>\update.yaml through the same validator
            Import-HDTWindowsUpdate writes through, so an entry that would not
            load is reported as an error naming the file rather than quietly
            missing from a list an administrator is reading to decide what is
            deployed.

            THE PACKAGE PATH IS A CONVENTION, NOT A KEY IN THE FILE, exactly as
            an application's source folder is: the .msu sits beside its
            update.yaml under the update's own folder, and fileName says which
            file it is. That is what makes a workspace movable - nothing records
            an absolute path - and it is what the ApplyUpdates step resolves
            through the content provider at deployment time.

            THE ROWS ARE ORDERED THE WAY THEY MUST BE APPLIED, not the way the
            file system happened to enumerate them: servicing stack updates
            first, then by the build each update produces, then by KB. See
            Get-HDTUpdateApplyOrder for why that is the correct servicing order
            and where it comes from.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            One update id to return. Omit it for every update in the workspace.

        .PARAMETER Release
            Return only updates filed under this release. This is how the console
            groups its list and how a sequence narrows one.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per update, with the
            document's keys plus PackagePath, Folder and WorkspaceRoot.

        .EXAMPLE
            Get-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' | Format-Table Kb, Release, Kind, TargetVersion

            Everything imported, in the order the step would apply it.

        .EXAMPLE
            Get-HDTWindowsUpdate -WorkspaceRoot 'C:\HDTLab\Share' -Release 'WS2025'

            Just the Server 2025 updates.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Release,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $readOne = {
        param([string] $UpdateId)

        $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $UpdateId
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $UpdateId, 'update.yaml'

        $document = ConvertFrom-HDTYaml -Yaml ($FileSystem.ReadAllText($catalogPath)) -Path $catalogPath
        Assert-HDTWindowsUpdateDocument -Document $document -Path $catalogPath

        $get = {
            param([string] $Key, [object] $Default)

            if ($document.Contains($Key)) { return $document[$Key] }
            return $Default
        }

        [pscustomobject] @{
            Id                = [string] $document['id']
            Kb                = [string] $document['kb']
            Name              = [string] $document['name']
            Description       = [string] (& $get 'description' '')
            Release           = [string] $document['release']
            Kind              = [string] $document['kind']
            Architecture      = [string] $document['architecture']
            FileName          = [string] $document['fileName']
            SizeBytes         = [long] (& $get 'sizeBytes' 0)
            BaselineVersion   = [string] (& $get 'baselineVersion' '')
            TargetVersion     = [string] (& $get 'targetVersion' '')
            Build             = [int] (& $get 'build' 0)
            Revision          = [int] (& $get 'revision' 0)
            PackageId         = [string] (& $get 'packageId' '')
            SourceBranch      = [string] (& $get 'sourceBranch' '')
            BundledSsuKb      = [string] (& $get 'bundledSsuKb' '')
            BundledSsuVersion = [string] (& $get 'bundledSsuVersion' '')
            CreatedUtc        = [string] (& $get 'createdUtc' '')
            ImportedUtc       = [string] (& $get 'importedUtc' '')
            Enabled           = [bool] (& $get 'enabled' $true)
            Note              = [string] (& $get 'note' '')
            Folder            = $folder
            # A CONVENTION, NOT A KEY. Nothing records an absolute path, which
            # is what lets a share be moved or reached over SMB from WinPE.
            PackagePath       = [System.IO.Path]::Combine($folder, [string] $document['fileName'])
            CatalogPath       = $catalogPath
            WorkspaceRoot     = $WorkspaceRoot
        }
    }

    if ($PSBoundParameters.ContainsKey('Id')) {
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $Id, 'update.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                        -Message ("no Windows update with the id '{0}' is in this workspace. An update is a folder under WindowsUpdates\ holding an update.yaml." -f $Id) `
                        -Category ObjectNotFound))
        }

        return (& $readOne $Id)
    }

    $updateRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates

    if (-not $FileSystem.TestPath($updateRoot)) { return }

    $row = foreach ($child in @($FileSystem.GetChildItem($updateRoot))) {
        $childId = [System.IO.Path]::GetFileName([string] $child)
        $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind WindowsUpdates -ChildPath $childId, 'update.yaml'

        if (-not $FileSystem.TestPath($catalogPath)) { continue }

        & $readOne $childId
    }

    $result = @($row)

    if ($PSBoundParameters.ContainsKey('Release')) {
        $result = @($result | Where-Object { $_.Release -eq $Release })
    }

    return [pscustomobject[]] @(Get-HDTUpdateApplyOrder -Update $result)
}
