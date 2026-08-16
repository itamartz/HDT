function Get-HDTConsoleBootImage {
    <#
        .SYNOPSIS
            Reads the boot image manifest a share carries, and reports a share
            that has none.

        .DESCRIPTION
            Update-HDTBootImage writes Boot\<name>.manifest.json beside the .wim
            and the .iso it produced, recording the build id, the time, the
            machine, the engine version and the SHA-256 and size of both
            artifacts. That file is where the console's build date and hashes
            come from: re-deriving them would mean hashing a 500 MB ISO every
            time a window opens, and the manifest exists precisely so nobody has
            to.

            THREE ANSWERS, NOT TWO. 'Ok' is a manifest that was read. 'Missing'
            is a share whose image has never been built - a legitimate state for
            a share an administrator is still setting up, so it names
            Update-HDTBootImage rather than reading as a fault. 'Error' is a
            manifest that is there and cannot be read, which is a fault and says
            so. Collapsing the last two would tell an admin to rebuild an image
            when the real problem is a truncated file on the share.

            IT NEVER THROWS. Every failure becomes a status, because the boot
            image is one panel of a window that still has a share, task sequences
            and operating systems to show.

            THE ISO CLAIM IS EVALUATED, NOT REPEATED. HashMatch is the
            comparison of the standalone WIM's hash against the hash of the
            boot.wim inside the ISO, both of which the manifest records. An older
            manifest written before that key existed answers $false rather than
            throwing - Get-HDTConsoleJsonProperty is what makes a missing key a
            default instead of a PropertyNotFoundException.

        .PARAMETER Root
            The workspace root.

        .PARAMETER BootImage
            The projected bootImage block from Import-HDTWorkspaceDocument. Its
            Name is what the manifest is called.

        .PARAMETER FileSystem
            An IFileSystem.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - see
            Get-HDTConsoleWorkspace's OUTPUTS.

        .EXAMPLE
            Get-HDTConsoleBootImage -Root 'C:\HDTLab\Share' -BootImage $workspace.BootImage -FileSystem $fs
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $BootImage,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $manifestName = '{0}.manifest.json' -f $BootImage.Name
    $manifestPath = Get-HDTWorkspacePath -Root $Root -Kind Boot -ChildPath $manifestName

    $result = [pscustomobject] @{
        Name             = [string] $BootImage.Name
        Architecture     = [string] $BootImage.Architecture
        Language         = [string] $BootImage.Language
        ManifestPath     = $manifestPath
        Status           = 'Missing'
        Error            = ''
        BuildId          = ''
        BuiltUtc         = $null
        BuiltOn          = ''
        EngineVersion    = ''
        WimPath          = ''
        WimSha256        = ''
        WimSizeBytes     = [long] 0
        IsoPath          = ''
        IsoSha256        = ''
        IsoSizeBytes     = [long] 0
        IsoBootWimSha256 = ''
        HashMatch        = $false
    }

    if (-not $FileSystem.TestPath($manifestPath)) {
        $result.Error = ("no boot image has been built for this share yet. Run Update-HDTBootImage against '{0}' to build one." -f
            [System.IO.Path]::Combine($Root, 'workspace.yaml'))

        return $result
    }

    try {
        $manifest = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText($manifestPath))

        $artifact = Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'artifacts' -Default $null
        $wim = Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'wim' -Default $null
        $iso = Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'iso' -Default $null

        $result.BuildId = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'buildId')
        $result.BuiltOn = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'builtOn')
        $result.EngineVersion = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'engineVersion')

        # THE BUILD DATE IS NOT NECESSARILY A STRING BY THE TIME IT GETS HERE.
        # ConvertFrom-Json coerces an ISO-8601 value to a [datetime] on its own,
        # and it does not do it the same way on both engines - Windows PowerShell
        # 5.1 and pwsh 7 disagree about the resulting Kind. Formatting it back to
        # a string and re-parsing loses the offset and shifts the build time by
        # the viewer's zone, twice; the first draft of this file did exactly that
        # and reported an image built at 07:13 UTC as 04:13 UTC on a UTC+3 desk.
        # So the DateTime is taken as a DateTime when that is what arrived, and
        # only a genuine string is parsed - AssumeUniversal because the manifest
        # writes Z, AdjustToUniversal so the result is Kind=Utc either way.
        $builtUtcValue = Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'builtUtc' -Default $null

        if ($builtUtcValue -is [datetime]) {
            $result.BuiltUtc = ([datetime] $builtUtcValue).ToUniversalTime()
        } elseif (-not [string]::IsNullOrWhiteSpace([string] $builtUtcValue)) {
            $result.BuiltUtc = [datetime]::Parse([string] $builtUtcValue, [cultureinfo]::InvariantCulture,
                ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal))
        }

        $result.WimPath = [string] (Get-HDTConsoleJsonProperty -InputObject $wim -Name 'path')
        $result.WimSha256 = [string] (Get-HDTConsoleJsonProperty -InputObject $wim -Name 'sha256')
        $result.WimSizeBytes = [long] (Get-HDTConsoleJsonProperty -InputObject $wim -Name 'sizeBytes' -Default 0)

        $result.IsoPath = [string] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'path')
        $result.IsoSha256 = [string] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'sha256')
        $result.IsoSizeBytes = [long] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'sizeBytes' -Default 0)

        $result.IsoBootWimSha256 = [string] (Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'isoBootWimSha256')

        $result.HashMatch = ((-not [string]::IsNullOrWhiteSpace($result.WimSha256)) -and
            ([string]::Equals($result.WimSha256, $result.IsoBootWimSha256, [System.StringComparison]::OrdinalIgnoreCase)))

        $result.Status = 'Ok'
    } catch {
        $result.Status = 'Error'
        $result.Error = ("the boot image manifest could not be read: {0}" -f [string] $_.Exception.Message)
    }

    return $result
}
