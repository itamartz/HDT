function Get-HDTConsoleBootImageNode {
    <#
        .SYNOPSIS
            Builds the boot image row - the build date, both artifacts, both
            hashes, and DESIGN 6.1.1's verdict.

        .DESCRIPTION
            THIS ROW IS WHY C1 NAMES HASHES AT ALL. A deployment share's boot
            image is the one artifact an administrator cannot inspect by looking
            at it: a .wim and a .iso on a share say nothing about when they were
            built, by which engine, or whether the ISO actually carries the WIM
            beside it. The manifest records all of that, and this row is where it
            becomes readable.

            THE BUILD DATE IS IN THE ROW, NOT ONLY IN THE DETAIL. "Is this image
            current?" is the question that gets asked in front of a bench with a
            machine waiting, and an answer that needs a click is an answer that
            gets guessed instead.

            THE HASHES ARE SHOWN IN FULL. A truncated hash cannot be compared
            with anything, which is the only thing a hash is for.

            DESIGN 6.1.1's CLAIM IS STATED IN WORDS. "the WIM inside the ISO and
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

        $detail = @(
            ('{0,-20}: {1}' -f 'Image name', $BootImage.Name)
            ('{0,-20}: {1}' -f 'Architecture', $BootImage.Architecture)
            ('{0,-20}: {1}' -f 'Language', $BootImage.Language)
            ('{0,-20}: {1}' -f 'Manifest', $BootImage.ManifestPath)
            ''
            $BootImage.Error
            ''
            ("To build it:  Update-HDTBootImage -WorkspacePath '{0}'" -f $Workspace.WorkspacePath)
        )

        return (New-HDTConsoleNode -Depth 3 -Kind 'BootImage' -Status $BootImage.Status `
                -Text ('{0} - {1}' -f $BootImage.Name, $suffix) `
                -Detail ($detail -join [System.Environment]::NewLine) -Command $command -Header $Header)
    }

    $built = '(not recorded)'
    if ($null -ne $BootImage.BuiltUtc) {
        $built = [string]::Format([cultureinfo]::InvariantCulture, '{0:yyyy-MM-dd HH:mm:ss}',
            $BootImage.BuiltUtc.ToUniversalTime())
    }

    $verdict = 'DIFFERS from the standalone WIM - DESIGN 6.1.1 expects them identical'
    if ($BootImage.HashMatch) {
        $verdict = 'matches the standalone WIM (DESIGN 6.1.1)'
    }

    $detail = @(
        ('{0,-20}: {1}' -f 'Image name', $BootImage.Name)
        ('{0,-20}: {1}' -f 'Architecture', $BootImage.Architecture)
        ('{0,-20}: {1}' -f 'Language', $BootImage.Language)
        ''
        ('{0,-20}: {1} UTC' -f 'Built', $built)
        ('{0,-20}: {1}' -f 'Built on', $BootImage.BuiltOn)
        ('{0,-20}: {1}' -f 'Engine version', $BootImage.EngineVersion)
        ('{0,-20}: {1}' -f 'Build id', $BootImage.BuildId)
        ''
        'WIM (WDS / PXE)'
        ('  {0,-18}: {1}' -f 'Path', $BootImage.WimPath)
        ('  {0,-18}: {1}' -f 'Size', (Format-HDTConsoleByteCount -Byte $BootImage.WimSizeBytes))
        ('  {0,-18}: {1}' -f 'SHA-256', $BootImage.WimSha256)
        ''
        'ISO (VM / removable media)'
        ('  {0,-18}: {1}' -f 'Path', $BootImage.IsoPath)
        ('  {0,-18}: {1}' -f 'Size', (Format-HDTConsoleByteCount -Byte $BootImage.IsoSizeBytes))
        ('  {0,-18}: {1}' -f 'SHA-256', $BootImage.IsoSha256)
        ('  {0,-18}: {1}' -f 'boot.wim SHA-256', (Get-HDTConsoleDisplayText -Text $BootImage.IsoBootWimSha256 -Fallback '(not recorded by this manifest)'))
        ('  {0,-18}: {1}' -f 'boot.wim', $verdict)
        ''
        ('{0,-20}: {1}' -f 'Manifest', $BootImage.ManifestPath)
        ("To rebuild:  Update-HDTBootImage -WorkspacePath '{0}'" -f $Workspace.WorkspacePath)
    )

    return (New-HDTConsoleNode -Depth 3 -Kind 'BootImage' -Status 'Ok' `
            -Text ('{0} - built {1} UTC' -f $BootImage.Name, $built) `
            -Detail ($detail -join [System.Environment]::NewLine) -Command $command -Header $Header)
}
