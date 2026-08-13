function ConvertTo-HDTOperatingSystemCatalog {
    <#
        .SYNOPSIS
            Projects a validated os.yaml document into the catalog object the
            engine works with.

        .DESCRIPTION
            One projection, used by both Import-HDTOperatingSystem and
            Get-HDTOperatingSystem, so what the importer returns and what the
            reader returns are the same shape by construction rather than by two
            authors agreeing.

            IT RESOLVES ImagePath, AND THAT PATH IS THE SEAM M4 REPLACES. DESIGN
            6 abstracts content access behind Resolve-Content / Copy-Content /
            Test-Content, and M4 ships the Smb and Local providers. Until then a
            relative sourcePath is resolved against the operating system folder,
            which is exactly what a provider would return for Local. When M4
            lands, ApplyImage changes from "ask the catalog" to "ask the
            provider" and no step logic moves.

            A ROOTED sourcePath IS KEPT AS IT IS. Media too large to bring into
            the share is registered where it stands, and a catalog that silently
            re-rooted it would send the apply step to a path with nothing in it.

        .PARAMETER Document
            The validated document, as ConvertFrom-HDTYaml returns it or as
            Import-HDTOperatingSystem built it.

        .PARAMETER OsFolder
            The operating system folder, built with Get-HDTWorkspacePath.

        .PARAMETER CatalogPath
            The os.yaml the document came from or is destined for.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            ConvertTo-HDTOperatingSystemCatalog -Document $document -OsFolder $folder -CatalogPath $path
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $OsFolder,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $CatalogPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $read = {
        param($Key)

        if ($Document.Contains($Key)) { return $Document[$Key] }
        return $null
    }

    $sourcePath = [string] (& $read 'sourcePath')

    # [IO.Path]::Combine, not Join-Path, for the reason Get-HDTWorkspacePath
    # gives: building a path must not require the drive to be mounted.
    $imagePath = $sourcePath
    if (-not [System.IO.Path]::IsPathRooted($sourcePath)) {
        $imagePath = [System.IO.Path]::Combine($OsFolder, $sourcePath.TrimStart('\', '/'))
    }

    $image = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @($Document['images'])) {
        $entry = {
            param($Key)

            if ($current.Contains($Key)) { return $current[$Key] }
            return $null
        }

        [void] $image.Add([pscustomobject] @{
                Index       = [int] (& $entry 'index')
                Name        = [string] (& $entry 'name')
                Description = [string] (& $entry 'description')
                Edition     = [string] (& $entry 'edition')
                SizeBytes   = [long] $(if ($null -eq (& $entry 'sizeBytes')) { 0 } else { (& $entry 'sizeBytes') })
                Version     = [string] (& $entry 'version')
            })
    }

    $defaultIndex = 0
    if ($null -ne (& $read 'defaultIndex')) { $defaultIndex = [int] (& $read 'defaultIndex') }

    return [pscustomobject] @{
        SchemaVersion = [int] (& $read 'schemaVersion')
        Id            = [string] (& $read 'id')
        Name          = [string] (& $read 'name')
        Description   = [string] (& $read 'description')
        Type          = [string] (& $read 'type')
        Architecture  = [string] (& $read 'architecture')
        SourcePath    = $sourcePath
        ImportedUtc   = [string] (& $read 'importedUtc')
        DefaultIndex  = $defaultIndex
        Path          = $CatalogPath
        OsFolder      = $OsFolder
        ImagePath     = $imagePath
        Images        = [object[]] @($image)
    }
}
