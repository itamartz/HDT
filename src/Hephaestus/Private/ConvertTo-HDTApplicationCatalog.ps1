function ConvertTo-HDTApplicationCatalog {
    <#
        .SYNOPSIS
            Projects a validated app.yaml document into the catalog object the
            engine works with.

        .DESCRIPTION
            EVERY DEFAULT IN THE APPLICATION MODEL LIVES HERE, and nowhere else.
            DESIGN 8 makes successCodes, rebootCodes, runIn, uninstall, detect and
            dependencies all optional, so most app.yaml files in a real workspace
            declare four keys and inherit the rest. What they inherit:

              successCodes  0 and 3010
              rebootCodes   3010
              runIn         FullOS
              uninstall     empty - nothing to run
              detect        $null - install every time
              dependencies  empty

            3010 IS A SUCCESS, NOT A FAILURE. It means "installed, reboot
            required", and an engine that classified it as a failure would scrap a
            build over an install that worked. It is in both default lists on
            purpose: successCodes says the install succeeded, rebootCodes says the
            sequence owes it a restart.

            DETECT PROJECTS TO $null WHEN THE FILE DECLARES NONE. That is the
            signal the install step reads as "install unconditionally", and it is
            DESIGN 8's stated behaviour rather than a missing feature - the engine
            never infers a rule for an application that declined to declare one.
            When a rule IS declared, every key its type allows is projected, empty
            where the file left it out, so the step reads a stable shape under
            Set-StrictMode instead of testing for property existence.

            SourcePath IS THE SAME SEAM ConvertTo-HDTOperatingSystemCatalog
            CLOSED. An application's payload is Applications\<id>\source by
            convention (DESIGN 2.1) rather than by a key in the file, and with a
            provider it is what the provider answered for that path relative to
            the provider's own root. Without one it is resolved against the
            workspace, which is what an administrator on a workstation gets.

        .PARAMETER Document
            The validated document, as ConvertFrom-HDTYaml returns it.

        .PARAMETER AppFolder
            The application folder, built with Get-HDTWorkspacePath.

        .PARAMETER CatalogPath
            The app.yaml the document came from.

        .PARAMETER Content
            An IContentProvider, or nothing.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            ConvertTo-HDTApplicationCatalog -Document $document -AppFolder $folder -CatalogPath $path
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $AppFolder,

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

    # -- the exit codes -------------------------------------------------------

    $successCode = @(0, 3010)
    if ($null -ne (& $read 'successCodes')) {
        $successCode = @(@($Document['successCodes']) | ForEach-Object { [int] $_ })
    }

    $rebootCode = @(3010)
    if ($null -ne (& $read 'rebootCodes')) {
        $rebootCode = @(@($Document['rebootCodes']) | ForEach-Object { [int] $_ })
    }

    # -- the detection rule ---------------------------------------------------

    $detect = $null
    if ($null -ne (& $read 'detect')) {
        $rule = $Document['detect']
        $type = [string] $rule['type']
        $schema = Get-HDTApplicationDetectKey

        $projection = [ordered] @{ Type = $type }

        foreach ($key in @($schema[$type].Required + $schema[$type].Optional)) {
            $value = ''
            if ($rule.Contains($key)) { $value = [string] $rule[$key] }

            # 'productCode' -> 'ProductCode'. The engine reads PascalCase off an
            # object; the file is authored in the camelCase every other HDT
            # document uses.
            $projection[($key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1))] = $value
        }

        $detect = [pscustomobject] $projection
    }

    # -- the dependencies -----------------------------------------------------

    $dependency = @()
    if ($null -ne (& $read 'dependencies')) {
        $dependency = @(@($Document['dependencies']) | ForEach-Object { [string] $_ })
    }

    # -- the payload folder ---------------------------------------------------

    # [IO.Path]::Combine, not Join-Path, for the reason Get-HDTWorkspacePath
    # gives: building a path must not require the drive to be mounted.
    $sourcePath = [System.IO.Path]::Combine($AppFolder, 'source')

    if ($null -ne $Content) {
        # The provider answers for paths relative to ITS root, so the application
        # folder is made relative to that root first. A folder that is not under
        # the provider's root stays absolute and the provider returns it
        # unchanged.
        $folder = $AppFolder
        $root = [string] $Content.Root

        if ((-not [string]::IsNullOrEmpty($root)) -and
            $folder.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {

            $folder = $folder.Substring($root.Length).TrimStart('\', '/')
        }

        $sourcePath = [string] $Content.ResolveContent([System.IO.Path]::Combine($folder, 'source'))
    }

    $runIn = 'FullOS'
    if (-not [string]::IsNullOrWhiteSpace([string] (& $read 'runIn'))) {
        $runIn = [string] $Document['runIn']
    }

    return [pscustomobject] @{
        SchemaVersion = [int] (& $read 'schemaVersion')
        Id            = [string] (& $read 'id')
        Name          = [string] (& $read 'name')
        Description   = [string] (& $read 'description')
        Install       = [string] (& $read 'install')
        Uninstall     = [string] (& $read 'uninstall')
        SuccessCodes  = [int[]] $successCode
        RebootCodes   = [int[]] $rebootCode
        Detect        = $detect
        Dependencies  = [string[]] $dependency
        RunIn         = $runIn
        Path          = $CatalogPath
        AppFolder     = $AppFolder
        SourcePath    = $sourcePath
    }
}
