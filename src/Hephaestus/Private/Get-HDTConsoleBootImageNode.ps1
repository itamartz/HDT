function Get-HDTConsoleBootImageNode {
    <#
        .SYNOPSIS
            Builds the boot image row - named for the image, detailing the build
            date, both artifacts, both hashes, and whether the ISO carries the
            same boot image.

        .DESCRIPTION
            THIS ROW IS WHY C1 NAMES HASHES AT ALL. A deployment share's boot
            image is the one artifact an administrator cannot inspect by looking
            at it: a .wim and a .iso on a share say nothing about when they were
            built, by which engine, or whether the ISO actually carries the WIM
            beside it. The manifest records all of that, and this row is where it
            becomes readable.

            THE BUILD DATE IS IN THE DETAIL, AND ONLY THERE. It was in the row
            as well, on the argument that "is this image current?" gets asked in
            front of a bench with a machine waiting. It does not earn a second
            place: the row opens on one click and Built is the fourth field, and
            the same timestamp rendered twice is a row that contradicts its own
            detail the first time a rebuild lands while the tree is open.

            THE HASHES ARE SHOWN IN FULL. A truncated hash cannot be compared
            with anything, which is the only thing a hash is for.

            THE ISO CLAIM IS STATED IN WORDS. "the WIM inside the ISO and
            the standalone WIM have identical hashes" is a property the build
            asserts; the console says whether it holds for THIS image rather than
            printing two 64-character strings and leaving an administrator to
            compare them by eye.

        .PARAMETER BootImage
            The BootImage projection from Get-HDTConsoleWorkspace.

        .PARAMETER Workspace
            The workspace it belongs to, for the workspace.yaml path the rebuild
            command names.

        .PARAMETER Header
            What the banner says while this row is selected.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one console node.

        .EXAMPLE
            Get-HDTConsoleBootImageNode -BootImage $model.BootImage -Workspace $model
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $BootImage,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Workspace,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Header
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # What the row teaches an administrator to type. Reading a manifest is a
    # file read, not a cmdlet - so the honest invocation is the file read, and
    # the rebuild command is named in the detail where it belongs.
    $command = "Get-Content -LiteralPath '{0}' -Raw | ConvertFrom-Json" -f $BootImage.ManifestPath

    if ($BootImage.Status -ne 'Ok') {
        $suffix = 'not built'
        if ($BootImage.Status -eq 'Error') {
            $suffix = 'manifest unreadable'
        }

        $field = @(
            New-HDTConsoleField -Label 'Image name' -Value $BootImage.Name
            New-HDTConsoleField -Label 'Architecture' -Value $BootImage.Architecture
            New-HDTConsoleField -Label 'Language' -Value $BootImage.Language
            New-HDTConsoleField -Label 'Manifest' -Value $BootImage.ManifestPath
            New-HDTConsoleField -Label 'Why' -Value $BootImage.Error
            New-HDTConsoleField -Label 'To build it' -Value ("Update-HDTBootImage -WorkspacePath '{0}'" -f $Workspace.WorkspacePath)
        )

        return (New-HDTConsoleNode -Depth 3 -Kind 'BootImage' -Status $BootImage.Status `
                -Text ('{0} - {1}' -f $BootImage.Name, $suffix) `
                -Field $field -Command $command -Header $Header `
                -Subject $Workspace.WorkspacePath)
    }

    $built = '(not recorded)'
    if ($null -ne $BootImage.BuiltUtc) {
        $built = [string]::Format([cultureinfo]::InvariantCulture, '{0:yyyy-MM-dd HH:mm:ss}',
            $BootImage.BuiltUtc.ToUniversalTime())
    }

    $verdict = 'DIFFERS from the standalone WIM - one build emits both, so they should be identical'
    if ($BootImage.HashMatch) {
        $verdict = 'matches the standalone WIM'
    }

    $field = @(
        New-HDTConsoleField -Label 'Image name' -Value $BootImage.Name
        New-HDTConsoleField -Label 'Architecture' -Value $BootImage.Architecture
        New-HDTConsoleField -Label 'Language' -Value $BootImage.Language
        New-HDTConsoleField -Label 'Built' -Value ('{0} UTC' -f $built)
        New-HDTConsoleField -Label 'Built on' -Value $BootImage.BuiltOn
        New-HDTConsoleField -Label 'Engine version' -Value $BootImage.EngineVersion
        New-HDTConsoleField -Label 'Build id' -Value $BootImage.BuildId

        New-HDTConsoleField -Label 'WIM path' -Value $BootImage.WimPath
        New-HDTConsoleField -Label 'WIM size' -Value (Format-HDTConsoleByteCount -Byte $BootImage.WimSizeBytes)
        New-HDTConsoleField -Label 'WIM SHA-256' -Value $BootImage.WimSha256

        New-HDTConsoleField -Label 'ISO path' -Value $BootImage.IsoPath
        New-HDTConsoleField -Label 'ISO size' -Value (Format-HDTConsoleByteCount -Byte $BootImage.IsoSizeBytes)
        New-HDTConsoleField -Label 'ISO SHA-256' -Value $BootImage.IsoSha256
        New-HDTConsoleField -Label 'boot.wim SHA-256' -Value (Get-HDTConsoleDisplayText -Text $BootImage.IsoBootWimSha256 -Fallback '(not recorded by this manifest)')
        New-HDTConsoleField -Label 'boot.wim in the ISO' -Value $verdict

        New-HDTConsoleField -Label 'Manifest' -Value $BootImage.ManifestPath
        New-HDTConsoleField -Label 'To rebuild it' -Value ("Update-HDTBootImage -WorkspacePath '{0}'" -f $Workspace.WorkspacePath)
    )

    # THE ROW IS THE IMAGE'S NAME. The build date is one click away in the
    # Built field below, and a timestamp printed twice is a timestamp that
    # disagrees with itself the first time a rebuild lands while the tree is
    # open.
    return (New-HDTConsoleNode -Depth 3 -Kind 'BootImage' -Status 'Ok' `
            -Text $BootImage.Name `
            -Field $field -Command $command -Header $Header `
                -Subject $Workspace.WorkspacePath)
}
