function Get-HDTDriverState {
    <#
        .SYNOPSIS
            The drivers somebody has turned off on this share.

        .DESCRIPTION
            THE ONE FACT THAT IS NOT IN THE .inf, because there is nowhere in an
            .inf to put it. Everything else the console shows about a driver -
            class, provider, version, date, PnP ids - is read out of the file
            every time it is asked for. This is the exception.

            IT RECORDS ONLY WHAT IS OFF, and that is the whole design. The
            alternative considered first was a driver-index.json holding a parsed
            copy of every driver plus a flag, and it is worse in three ways:

              IT DUPLICATES THE .inf. Two answers to "what class is this driver",
              and the wrong one wins whenever the folder changed and the index
              did not - which is every re-import.

              IT MUST BE MAINTAINED. A driver imported without rebuilding the
              index is a driver the console cannot see; a driver deleted leaves a
              row pointing at nothing.

              A NEW DRIVER WOULD ARRIVE IN NO STATE AT ALL. Recording what is
              OFF means anything not named is ON, so a pack imported tomorrow is
              enabled without anybody writing anything.

            A SHARE NOBODY HAS DISABLED ANYTHING ON THEREFORE HAS NO DOCUMENT,
            and that is the ordinary case. This answers empty for it.

            THE PATHS ARE RELATIVE TO Drivers\ so the document survives the share
            being moved or mounted under a different letter - the same reason a
            selection profile's includes are relative.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER FileSystem
            The IFileSystem to read with.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the disabled drivers' paths, relative to Drivers\.

        .EXAMPLE
            Get-HDTDriverState -Root 'C:\HDTLab\Share' -FileSystem (New-HDTFileSystem)

        .LINK
            Get-HDTDriver
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $path = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'driver-state.yaml'

    if (-not $FileSystem.TestPath($path)) { return [string[]] @() }

    $document = ConvertFrom-HDTYaml -Yaml ([string] $FileSystem.ReadAllText($path)) -Path $path

    if ($null -eq $document) { return [string[]] @() }
    if (-not $document.Contains('disabled')) { return [string[]] @() }
    if ($null -eq $document['disabled']) { return [string[]] @() }

    return [string[]] @(@($document['disabled']) |
            ForEach-Object { ([string] $_).Trim().TrimStart('\', '/') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
