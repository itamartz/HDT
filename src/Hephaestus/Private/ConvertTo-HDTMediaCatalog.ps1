function ConvertTo-HDTMediaCatalog {
    <#
        .SYNOPSIS
            Projects a validated media.yaml document into the media object the
            engine and the console work with.

        .DESCRIPTION
            EVERY DEFAULT IN THE MEDIA MODEL LIVES HERE, and nowhere else.
            description and enabled are optional in the document, so most
            media.yaml files in a real workspace declare five keys and inherit
            the rest. What they inherit:

              description  empty - nothing to say
              enabled      true - MDT's media item ships ticked

            output IS RESOLVED HERE AND NOT AT WRITE TIME. A share is routinely
            authored on one machine and built on another, so a path expanded to a
            drive letter when the item was created is the one value that is
            certainly wrong later. The document keeps what was typed; Output is
            that, and OutputPath is that resolved against the workspace root -
            unless it is already rooted, in which case it is left exactly alone,
            because media is routinely built onto another disk or another server.

            [IO.Path]::Combine, NOT Join-Path, for Get-HDTWorkspacePath's reason:
            Join-Path resolves the drive qualifier and throws DriveNotFound for a
            drive this session has not mounted, which is what a workspace root
            routinely is - an admin authoring on a workstation, a test naming
            X:\. A line written with Join-Path cannot be tested at all.

            THE LAST BUILD IS A MANIFEST, NOT A KEY IN THE DOCUMENT.
            Media\<id>\media.manifest.json is written by Update-HDTMediaContent
            exactly as Boot\<name>.manifest.json already works, and for the two
            reasons already written down in this repository: media.yaml is a file
            an administrator hand-edits and comments, so a build that rewrote it
            every run would either lose those comments or need a splice for a
            value nobody types; and a manifest on disk means the artifact beside
            it came from the build that wrote it.

            THIS FUNCTION READS NOTHING. It is handed the parsed manifest, or
            $null, the way New-HDTBootImageManifest is handed everything it
            records - Get-HDTMedia does the reading and decides that a manifest
            which will not parse is a missing manifest rather than a failed read.

        .PARAMETER Document
            The validated document, as ConvertFrom-HDTYaml returns it.

        .PARAMETER WorkspaceRoot
            The share root a relative output resolves against.

        .PARAMETER Folder
            The media folder, built with Get-HDTWorkspacePath.

        .PARAMETER CatalogPath
            The media.yaml the document came from.

        .PARAMETER Manifest
            The parsed media.manifest.json, or $null when there is not one.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            ConvertTo-HDTMediaCatalog -Document $document -WorkspaceRoot 'X:\Share' -Folder $folder -CatalogPath $path -Manifest $null
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Folder,

        [Parameter(Mandatory = $true, Position = 3)]
        [ValidateNotNullOrEmpty()]
        [string] $CatalogPath,

        [Parameter()]
        [AllowNull()]
        [object] $Manifest = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $read = {
        param($Key)

        if ($Document.Contains($Key)) { return $Document[$Key] }
        return $null
    }

    # -- the tick -------------------------------------------------------------

    $enabled = $true
    if ($null -ne (& $read 'enabled')) { $enabled = [bool] $Document['enabled'] }

    # -- where the ISO goes ---------------------------------------------------

    $output = [string] (& $read 'output')
    $outputPath = $output

    if (-not [System.IO.Path]::IsPathRooted($output)) {
        $outputPath = [System.IO.Path]::Combine($WorkspaceRoot, $output.TrimStart('\', '/'))
    }

    # -- the last build -------------------------------------------------------

    $lastBuildUtc = $null
    $isoPath = ''
    $isoSizeBytes = [long] 0
    $isoSha256 = ''

    if ($null -ne $Manifest) {
        $artifact = Get-HDTConsoleJsonProperty -InputObject $Manifest -Name 'artifacts' -Default $null
        $iso = Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'iso' -Default $null

        # THE BUILD DATE IS NOT NECESSARILY A STRING BY THE TIME IT GETS HERE.
        # ConvertFrom-Json coerces an ISO-8601 value to a [datetime] on its own,
        # and Windows PowerShell 5.1 and pwsh 7 disagree about the resulting
        # Kind. Formatting it back to a string and re-parsing loses the offset
        # and shifts the build time by the viewer's zone - Get-HDTConsoleBootImage
        # records that exact defect, an image built at 07:13 UTC reported as
        # 04:13 on a UTC+3 desk. So a DateTime is taken as a DateTime, and only a
        # genuine string is parsed.
        $builtUtcValue = Get-HDTConsoleJsonProperty -InputObject $Manifest -Name 'builtUtc' -Default $null

        if ($builtUtcValue -is [datetime]) {
            $lastBuildUtc = ([datetime] $builtUtcValue).ToUniversalTime()
        } elseif (-not [string]::IsNullOrWhiteSpace([string] $builtUtcValue)) {
            $lastBuildUtc = [datetime]::Parse([string] $builtUtcValue, [cultureinfo]::InvariantCulture,
                ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal))
        }

        $isoPath = [string] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'path')
        $isoSha256 = [string] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'sha256')
        $isoSizeBytes = [long] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'sizeBytes' -Default 0)
    }

    return [pscustomobject] @{
        Id               = [string] (& $read 'id')
        Name             = [string] (& $read 'name')
        Description      = [string] (& $read 'description')
        SelectionProfile = [string] (& $read 'selectionProfile')

        # WHAT THE DOCUMENT SAYS, AND WHAT IT MEANS, SIDE BY SIDE. Set-HDTMedia
        # writes Output back; a build writes to OutputPath. Keeping only the
        # resolved one would make an edit rewrite a relative path as an absolute.
        Output           = $output
        OutputPath       = $outputPath
        Enabled          = $enabled
        Folder           = $Folder
        DocumentPath     = $CatalogPath
        LastBuildUtc     = $lastBuildUtc
        IsoPath          = $isoPath
        IsoSizeBytes     = $isoSizeBytes
        IsoSha256        = $isoSha256
    }
}
