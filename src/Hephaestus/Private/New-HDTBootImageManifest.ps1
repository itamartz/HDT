function New-HDTBootImageManifest {
    <#
        .SYNOPSIS
            Builds the boot image build manifest as JSON text.

        .DESCRIPTION
            DESIGN 5.1's ANSWER TO BOOT IMAGE DRIFT: "the build is deterministic
            and repeatable ... and records a manifest of exactly what went in.
            Boot image drift - where nobody remembers what's in the WIM - is a
            real MDT operational problem."

            It is written to <workspace>\Boot\<name>.manifest.json LAST, after
            both artifacts exist, so a manifest that is there describes a build
            that finished.

            IT IS PURE, AND IT RETURNS TEXT. It is handed everything it records,
            so every claim in it can be asserted without a fifteen-minute build;
            and it returns the JSON rather than writing it, so Update-HDTBootImage
            writes it through IFileSystem like everything else and the write is
            provable with nothing on disk.

            TWO THINGS IN IT ARE ASSERTIONS AN OPERATOR CAN MAKE WITHOUT THE TEST
            SUITE, AND THAT IS THE POINT OF RECORDING THEM:

              artifacts.isoBootWimSha256 === artifacts.wim.sha256
                  DESIGN 6.1.1 written into the artifact. The WIM inside the ISO
                  and the standalone WIM are one file copied, not two exports, so
                  "a bug reproduced from the ISO is a bug in the PXE path" is
                  checkable by anyone holding this file.

              credential.username, and NEVER the secret
                  DESIGN 6.3. The manifest sits in Boot\ beside the WIM. It says
                  WHICH account the image carries so an operator can audit it,
                  and it carries nothing that would let them use it.

            THE SECRET IS DROPPED BY CONSTRUCTION, not by filtering: only
            Username, Embedded and PromptForCredential are read out of
            -Credential, so a caller that passes a password in that hashtable
            cannot leak it here. A unit test greps the serialised text for the
            protected string to prove it.

            EVERY LIST IS FORCED TO A JSON ARRAY with -AsArray-equivalent
            wrapping, because a one-element list serialised as an object breaks
            an operator's jq and the integration suite's own read-back, and a
            one-component build is a perfectly ordinary build.

        .PARAMETER BuildId
            The build's GUID, also written into bootstrap.json so a booted
            machine's RESULT.json names the image it came from.

        .PARAMETER BuiltUtc
            The build timestamp, as the ISO 8601 string it is recorded as. It is
            a string rather than a [datetime] because pwsh 7 and Windows
            PowerShell 5.1 disagree about round-tripping one through JSON
            (05-03's bootstrap trap).

        .PARAMETER BuiltOn
            The build host's computer name.

        .PARAMETER EngineVersion
            The Hephaestus module version that built it - and, because the module
            is staged from its own ModuleBase, the version inside the image.

        .PARAMETER WorkspaceId
            workspace.yaml's id.

        .PARAMETER Architecture
            amd64 or arm64.

        .PARAMETER Language
            The language pack folder, en-us by default.

        .PARAMETER Adk
            Root, Oscdimg, WinPeWim and WinPeWimSha256.

        .PARAMETER Component
            The rows Get-HDTBootImageComponent produced, in the order they were
            applied.

        .PARAMETER Driver
            The rows AddDriver reported back.

        .PARAMETER Payload
            What HDT staged into the image: Destination, Source, FileCount,
            SizeBytes.

        .PARAMETER ExtraContent
            What the administrator asked for: Source, Destination, FileCount.
            Kept separate from Payload because they are different promises.

        .PARAMETER Startnet
            The exact text written to startnet.cmd.

        .PARAMETER Credential
            Username, Embedded, PromptForCredential. Anything else in this
            hashtable is ignored.

        .PARAMETER Wim
            Path, Sha256, SizeBytes.

        .PARAMETER Iso
            Path, Sha256, SizeBytes, Firmware, NoPromptForKey, Skipped. Under
            -SkipIso only Skipped is set.

        .PARAMETER IsoBootWimSha256
            The hash of sources\boot.wim in the media the ISO was built from.
            Empty under -SkipIso.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the manifest as JSON.

        .EXAMPLE
            New-HDTBootImageManifest -BuildId $id -BuiltUtc $utc -BuiltOn $env:COMPUTERNAME `
                -EngineVersion '0.1.0' -WorkspaceId 'HDT-LAB' -Architecture amd64 -Language en-us `
                -Adk $adk -Component $component -Driver $driver -Payload $payload `
                -ExtraContent $extra -Startnet $startnet -Credential $credential `
                -Wim $wim -Iso $iso -IsoBootWimSha256 $wim.Sha256
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a string; it changes no state. The caller writes it through IFileSystem under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
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
        [string] $Architecture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Language = '',

        [Parameter()]
        [AllowNull()]
        [hashtable] $Adk,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Component,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Driver,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Payload,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $ExtraContent,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Startnet = '',

        [Parameter()]
        [AllowNull()]
        [hashtable] $Credential,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Wim,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Iso,

        [Parameter()]
        [AllowEmptyString()]
        [string] $IsoBootWimSha256 = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Reads a key off a hashtable that may be $null or may not carry it. Engine
    # code runs under Set-StrictMode -Version Latest, where a missing key on a
    # hashtable is $null but a missing PROPERTY throws, and these arrive as both.
    $valueOf = {
        param([hashtable] $Table, [string] $Name, [object] $Default)

        if ($null -eq $Table) { return $Default }
        if (-not $Table.ContainsKey($Name)) { return $Default }
        if ($null -eq $Table[$Name]) { return $Default }

        return $Table[$Name]
    }

    $propertyOf = {
        param([object] $Row, [string] $Name, [object] $Default)

        if ($null -eq $Row) { return $Default }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) { return $Default }
            if ($null -eq $Row[$Name]) { return $Default }
            return $Row[$Name]
        }

        $member = $Row.PSObject.Properties[$Name]
        if ($null -eq $member) { return $Default }
        if ($null -eq $member.Value) { return $Default }

        return $member.Value
    }

    # -- what went in ---------------------------------------------------------

    $componentRow = New-Object -TypeName System.Collections.ArrayList
    foreach ($item in @($Component)) {
        [void] $componentRow.Add([ordered] @{
                order       = [int] (& $propertyOf $item 'Order' 0)
                name        = [string] (& $propertyOf $item 'Name' '')
                cab         = [string] (& $propertyOf $item 'CabPath' '')
                languageCab = [string] (& $propertyOf $item 'LanguageCabPath' '')
                required    = [bool] (& $propertyOf $item 'Required' $false)
            })
    }

    $driverRow = New-Object -TypeName System.Collections.ArrayList
    foreach ($item in @($Driver)) {
        [void] $driverRow.Add([ordered] @{
                inf      = [string] (& $propertyOf $item 'Inf' '')
                provider = [string] (& $propertyOf $item 'Provider' '')
                version  = [string] (& $propertyOf $item 'Version' '')
                date     = [string] (& $propertyOf $item 'Date' '')
            })
    }

    $payloadRow = New-Object -TypeName System.Collections.ArrayList
    foreach ($item in @($Payload)) {
        [void] $payloadRow.Add([ordered] @{
                destination = [string] (& $propertyOf $item 'Destination' '')
                source      = [string] (& $propertyOf $item 'Source' '')
                fileCount   = [int] (& $propertyOf $item 'FileCount' 0)
                sizeBytes   = [long] (& $propertyOf $item 'SizeBytes' [long] 0)
            })
    }

    $extraRow = New-Object -TypeName System.Collections.ArrayList
    foreach ($item in @($ExtraContent)) {
        [void] $extraRow.Add([ordered] @{
                source      = [string] (& $propertyOf $item 'Source' '')
                destination = [string] (& $propertyOf $item 'Destination' '')
                fileCount   = [int] (& $propertyOf $item 'FileCount' 0)
            })
    }

    # -- the document ---------------------------------------------------------
    #
    # THE CREDENTIAL BLOCK READS THREE KEYS AND NO OTHERS. A caller that put a
    # password in that hashtable cannot leak it through here.

    $document = [ordered] @{
        schemaVersion      = 1
        buildId            = $BuildId
        builtUtc           = $BuiltUtc
        builtOn            = $BuiltOn
        engineVersion      = $EngineVersion
        workspaceId        = $WorkspaceId
        architecture       = $Architecture
        language           = $Language
        adk                = [ordered] @{
            root           = [string] (& $valueOf $Adk 'Root' '')
            oscdimg        = [string] (& $valueOf $Adk 'Oscdimg' '')
            winpeWim       = [string] (& $valueOf $Adk 'WinPeWim' '')
            winpeWimSha256 = [string] (& $valueOf $Adk 'WinPeWimSha256' '')
        }
        optionalComponents = [object[]] @($componentRow)
        drivers            = [object[]] @($driverRow)
        payload            = [object[]] @($payloadRow)
        extraContent       = [object[]] @($extraRow)
        startnet           = $Startnet
        credential         = [ordered] @{
            username            = [string] (& $valueOf $Credential 'Username' '')
            embedded            = [bool] (& $valueOf $Credential 'Embedded' $false)
            promptForCredential = [bool] (& $valueOf $Credential 'PromptForCredential' $false)
        }
        artifacts          = [ordered] @{
            wim              = [ordered] @{
                path      = [string] (& $valueOf $Wim 'Path' '')
                sha256    = [string] (& $valueOf $Wim 'Sha256' '')
                sizeBytes = [long] (& $valueOf $Wim 'SizeBytes' ([long] 0))
            }
            iso              = [ordered] @{
                path           = [string] (& $valueOf $Iso 'Path' '')
                sha256         = [string] (& $valueOf $Iso 'Sha256' '')
                sizeBytes      = [long] (& $valueOf $Iso 'SizeBytes' ([long] 0))
                firmware       = [string] (& $valueOf $Iso 'Firmware' '')
                noPromptForKey = [bool] (& $valueOf $Iso 'NoPromptForKey' $false)
                skipped        = [bool] (& $valueOf $Iso 'Skipped' $false)
            }
            isoBootWimSha256 = $IsoBootWimSha256
        }
    }

    # Depth 6: adk / artifacts.wim / artifacts.iso are two levels down and the
    # component rows are one, so the default of 2 would render them as type
    # names. -Compress is deliberately NOT set - this file is read by people.
    $text = ConvertTo-Json -InputObject $document -Depth 6

    # A ONE-ELEMENT LIST SERIALISES AS AN OBJECT ON BOTH ENGINES, and an operator
    # indexing optionalComponents[0] would get nothing. ConvertTo-Json -AsArray
    # does not exist under Windows PowerShell 5.1, so the arrays are forced by
    # wrapping them above; this is the assertion that they came out as arrays,
    # made here rather than left to a caller to discover.
    foreach ($name in @('optionalComponents', 'drivers', 'payload', 'extraContent')) {
        if ($text -notmatch ('"{0}":\s*(\[|null)' -f $name)) {
            throw ("The boot image manifest serialised '{0}' as an object rather than an array. That would break every consumer that indexes it." -f $name)
        }
    }

    return $text
}
