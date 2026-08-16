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

            IT RESOLVES ImagePath, AND THAT PATH IS THE SEAM 04-02 MARKED AND
            05-02 CLOSED. DESIGN 6 abstracts content access behind a provider,
            and -Content is where one arrives:

              with -Content     ImagePath is what the provider answered for the
                                path relative to the provider's own root;
              without -Content  a relative sourcePath is resolved against the
                                operating system folder, exactly as before.

            The second form is not a leftover: Import-HDTOperatingSystem runs on
            an administrator's workstation with no provider in sight, and every
            test written before 05-02 still exercises it.

            NO STEP LOGIC MOVED WHEN THE PROVIDER ARRIVED. Invoke-HDTApplyImageStep
            passes $Context.Service.Content when the run was started with one and
            is otherwise unchanged, which
            tests/unit/Invoke-HDTApplyImageStep.Tests.ps1 asserts by running the
            same step through the Local and the Smb providers and comparing the
            ordered list of every service call: the arguments differ, the
            operations do not.

            A ROOTED sourcePath IS KEPT AS IT IS, provider or no provider. Media
            too large to bring into the share is registered where it stands,
and a catalog that silently re-rooted it would send the
            apply step to a path with nothing in it.

        .PARAMETER Document
            The validated document, as ConvertFrom-HDTYaml returns it or as
            Import-HDTOperatingSystem built it.

        .PARAMETER OsFolder
            The operating system folder, built with Get-HDTWorkspacePath.

        .PARAMETER CatalogPath
            The os.yaml the document came from or is destined for.

        .PARAMETER Content
            An IContentProvider, or nothing. When supplied, a relative
            sourcePath is resolved through it - made relative to the provider's
            own root first, so 'sources\install.wim' under
            OperatingSystems\Win11-LTSC-2024 is asked for as
            'OperatingSystems\Win11-LTSC-2024\sources\install.wim'.

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
        [string] $CatalogPath,

        [Parameter()]
        [AllowNull()]
        [object] $Content = $null
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
        if ($null -eq $Content) {
            $imagePath = [System.IO.Path]::Combine($OsFolder, $sourcePath.TrimStart('\', '/'))
        } else {
            # The provider answers for paths relative to ITS root, so the
            # operating system folder is made relative to that root first. A
            # folder that is not under the provider's root stays absolute and
            # the provider returns it unchanged, which is the same answer
            # DESIGN 9.3's registered-where-it-stands case gets.
            $folder = $OsFolder
            $root = [string] $Content.Root

            if ((-not [string]::IsNullOrEmpty($root)) -and
                $folder.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {

                $folder = $folder.Substring($root.Length).TrimStart('\', '/')
            }

            $imagePath = [string] $Content.ResolveContent(
                [System.IO.Path]::Combine($folder, $sourcePath.TrimStart('\', '/')))
        }
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
