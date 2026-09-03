function New-HDTMediaManifest {
    <#
        .SYNOPSIS
            Builds the standalone media build manifest as JSON text.

        .DESCRIPTION
            WHAT WENT ON THE DISC, WRITTEN DOWN BESIDE IT. DESIGN 6.2 keeps the
            last build in Media\<id>\media.manifest.json rather than as a key in
            media.yaml, for two reasons: media.yaml is a file an administrator
            hand-edits and comments, so a build that rewrote it every run would
            lose those comments or need a splice for a value nobody types; and a
            manifest on disk means the artifact beside it came from the build
            that wrote it.

            IT IS PURE, AND IT RETURNS TEXT - New-HDTBootImageManifest's shape
            exactly, for its reasons. Handed everything it records, so every
            claim in it is assertable without a ten-minute build; and it returns
            the JSON rather than writing it, so Update-HDTMediaContent writes it
            through IFileSystem like everything else and the write is provable
            with nothing on disk.

            THE PROVIDER IS DERIVED FROM deployRoot HERE TOO, by the same
            predicate Update-HDTBootImage uses - a value starting \\ is Smb and
            anything else is Local. Passing it in would be a second way to say
            one thing, and the two would disagree the first time somebody built a
            disc from a share whose deployRoot had changed.

            IT CARRIES NO CREDENTIAL, AND THE OMISSION IS BY CONSTRUCTION RATHER
            THAN BY FILTERING: there is no credential parameter at all. A disc
            has no share to authenticate to (Set-HDTMediaWorkspaceLine takes the
            block off the projected workspace.yaml), and this file sits beside an
            ISO that is handed around - DESIGN 6.3 treats boot media as a
            credential in itself. A unit test greps the serialised text.

            TWO TRAPS New-HDTBootImageManifest's HEADER ALREADY RECORDS, and both
            apply unchanged:

              A ONE-ELEMENT LIST SERIALISES AS AN OBJECT on both engines, and an
              operator indexing projected[0] would get nothing.
              ConvertTo-Json -AsArray does not exist under Windows PowerShell
              5.1, so the arrays are forced by wrapping and then asserted below.

              builtUtc IS A STRING, because pwsh 7 and Windows PowerShell 5.1
              disagree about round-tripping a [datetime] through JSON (05-03's
              bootstrap trap).

        .PARAMETER MediaId
            The media definition's id - the folder name under Media\.

        .PARAMETER Name
            What the console shows for it.

        .PARAMETER BuildId
            This build's GUID.

        .PARAMETER BuiltUtc
            The build timestamp, as the ISO 8601 string it is recorded as.

        .PARAMETER BuiltOn
            The build host's computer name.

        .PARAMETER EngineVersion
            The Hephaestus module version that built it.

        .PARAMETER WorkspaceId
            workspace.yaml's id.

        .PARAMETER WorkspaceRoot
            The share the disc was projected from.

        .PARAMETER SelectionProfile
            The profile that governed the projection. It IS the projection
            (DESIGN 6.2), so it is the single most useful line in this file.

        .PARAMETER DeployRoot
            The deployRoot the projected workspace.yaml carries - \Share.

        .PARAMETER Architecture
            amd64 or arm64.

        .PARAMETER Firmware
            UEFI, BIOS or Both, as the ISO was burned.

        .PARAMETER Projected
            The rows that travelled, as Get-HDTMediaProjection returned them.

        .PARAMETER Excluded
            The rows that were refused, each with its reason. Recorded because
            "why is bootstrap-rules.yaml not on this disc" is a question somebody
            asks a week later on a machine they cannot touch.

        .PARAMETER Warning
            The dependency sentences, so a disc that shipped with one says so.

        .PARAMETER Iso
            Path, Sha256, SizeBytes.

        .PARAMETER BootWimSha256
            The hash of sources\boot.wim on the media tree the ISO was built
            from.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the manifest as JSON.

        .EXAMPLE
            New-HDTMediaManifest -MediaId 'LAB-DISC' -Name 'Lab disc' -BuildId $id `
                -BuiltUtc $utc -BuiltOn $env:COMPUTERNAME -EngineVersion '0.15.0' `
                -WorkspaceId 'HDT-LAB' -WorkspaceRoot $root -SelectionProfile 'everything' `
                -DeployRoot '\Share' -Architecture amd64 -Firmware UEFI `
                -Projected $projected -Excluded $excluded -Warning $warning `
                -Iso $iso -BootWimSha256 $sha

        .LINK
            New-HDTBootImageManifest
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a string; it changes no state. The caller writes it through IFileSystem under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $MediaId = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Name = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $BuildId = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $BuiltUtc = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $BuiltOn = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $EngineVersion = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $WorkspaceId = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $WorkspaceRoot = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $SelectionProfile = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $DeployRoot = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Architecture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Firmware = '',

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Projected,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Excluded,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Warning,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Iso,

        [Parameter()]
        [AllowEmptyString()]
        [string] $BootWimSha256 = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Reads a key off a hashtable that may be $null or may not carry it, as
    # New-HDTBootImageManifest does and for its reason: engine code runs under
    # Set-StrictMode -Version Latest, where a missing key on a hashtable is $null
    # but a missing PROPERTY throws.
    $valueOf = {
        param([hashtable] $Table, [string] $Key, [object] $Default)

        if ($null -eq $Table) { return $Default }
        if (-not $Table.ContainsKey($Key)) { return $Default }
        if ($null -eq $Table[$Key]) { return $Default }

        return $Table[$Key]
    }

    $propertyOf = {
        param([object] $Row, [string] $Property, [object] $Default)

        if ($null -eq $Row) { return $Default }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Property)) { return $Default }
            if ($null -eq $Row[$Property]) { return $Default }
            return $Row[$Property]
        }

        $member = $Row.PSObject.Properties[$Property]
        if ($null -eq $member) { return $Default }
        if ($null -eq $member.Value) { return $Default }

        return $member.Value
    }

    $rowOf = {
        param([object[]] $Source)

        $out = New-Object -TypeName System.Collections.ArrayList

        foreach ($item in @($Source)) {
            [void] $out.Add([ordered] @{
                    kind        = [string] (& $propertyOf $item 'Kind' '')
                    source      = [string] (& $propertyOf $item 'Source' '')
                    destination = [string] (& $propertyOf $item 'Destination' '')
                    reason      = [string] (& $propertyOf $item 'Reason' '')
                    present     = [bool] (& $propertyOf $item 'Present' $false)
                    rewritten   = [bool] (& $propertyOf $item 'Rewritten' $false)
                })
        }

        return [object[]] @($out)
    }

    # DERIVED, NOT PASSED IN. The exact predicate Update-HDTBootImage uses.
    $provider = 'Local'
    if ($DeployRoot.StartsWith('\\')) { $provider = 'Smb' }

    $document = [ordered] @{
        schemaVersion    = 1
        mediaId          = $MediaId
        name             = $Name
        buildId          = $BuildId
        builtUtc         = $BuiltUtc
        builtOn          = $BuiltOn
        engineVersion    = $EngineVersion
        workspaceId      = $WorkspaceId
        workspaceRoot    = $WorkspaceRoot
        selectionProfile = $SelectionProfile
        deployRoot       = $DeployRoot
        provider         = $provider
        architecture     = $Architecture
        firmware         = $Firmware
        # WRAPPED AT THE ASSIGNMENT, NOT ONLY INSIDE THE SCRIPTBLOCK. Invoking a
        # scriptblock enumerates whatever it returned into the pipeline, so a
        # one-row projection arrives here as a single ordered dictionary and
        # serialises as an object - the exact defect the guard below catches.
        projected        = [object[]] @(& $rowOf $Projected)
        excluded         = [object[]] @(& $rowOf $Excluded)
        warnings         = [string[]] @($Warning)
        artifacts        = [ordered] @{
            iso           = [ordered] @{
                path      = [string] (& $valueOf $Iso 'Path' '')
                sha256    = [string] (& $valueOf $Iso 'Sha256' '')
                sizeBytes = [long] (& $valueOf $Iso 'SizeBytes' ([long] 0))
            }
            bootWimSha256 = $BootWimSha256
        }
    }

    # Depth 6: artifacts.iso is two levels down and the projection rows are one,
    # so the default of 2 would render them as type names. -Compress is
    # deliberately NOT set - this file is read by people.
    $text = ConvertTo-Json -InputObject $document -Depth 6

    # THE ASSERTION THAT THEY CAME OUT AS ARRAYS, made here rather than left to a
    # caller to discover. See the header: a one-element list serialises as an
    # object and breaks every consumer that indexes it.
    foreach ($key in @('projected', 'excluded', 'warnings')) {
        if ($text -notmatch ('"{0}":\s*(\[|null)' -f $key)) {
            throw ("The media manifest serialised '{0}' as an object rather than an array. That would break every consumer that indexes it." -f $key)
        }
    }

    return $text
}
