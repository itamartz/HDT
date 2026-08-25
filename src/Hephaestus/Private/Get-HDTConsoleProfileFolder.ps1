function Get-HDTConsoleProfileFolder {
    <#
        .SYNOPSIS
            The folders a selection profile injects, as rows a window can bind
            to.

        .DESCRIPTION
            A PROFILE NAME IS A PROMISE; THIS IS THE LIST. It is exactly what
            Update-HDTBootImage will hand Add-WindowsDriver, shown on the tab
            that chose it, so a renamed folder is found HERE rather than on a
            bench with a laptop that cannot see its disk.

            IT PROJECTS, IT DOES NOT READ. Expand-HDTSelectionProfile has already
            been to the disk - Show-HDTBootImageWindow does that, because it has
            an IFileSystem and this view model deliberately has not. What arrives
            here is Path and Present, and what leaves is those two plus the
            sentence a technician reads.

            A MISSING FOLDER KEEPS ITS ROW AND SAYS SO. Dropping it would make a
            half-injected boot image look like a correct one.

            A PROFILE WITH NO Resolved PROPERTY ANSWERS NOTHING rather than
            throwing. The declared-but-unknown row has none, and neither does a
            share whose profile document could not be read.

        .PARAMETER SelectionProfile
            One profile, as Get-HDTSelectionProfile returned it, optionally
            carrying the Resolved list Expand-HDTSelectionProfile produced.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per folder, with Path,
            Present and Detail.

        .EXAMPLE
            Get-HDTConsoleProfileFolder -SelectionProfile $selectionProfile[0]

        .EXAMPLE
            @(Get-HDTConsoleProfileFolder -SelectionProfile $p | Where-Object { -not $_.Present }).Count

            How many of a profile's folders the share has not got.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $SelectionProfile
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $SelectionProfile) { return [pscustomobject[]] @() }

    # Under Set-StrictMode -Version Latest, reaching a property an object has not
    # got is an error rather than a null - and the declared-but-unknown row is a
    # row that genuinely has not got this one.
    if (@($SelectionProfile.PSObject.Properties.Name) -notcontains 'Resolved') { return [pscustomobject[]] @() }

    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($SelectionProfile.Resolved)) {
        $detail = ''
        if (-not [bool] $current.Present) { $detail = 'not on the share' }

        [void] $row.Add([pscustomobject] @{
                Path    = [string] $current.Path
                Present = [bool] $current.Present
                Detail  = $detail
            })
    }

    return [pscustomobject[]] @($row)
}
