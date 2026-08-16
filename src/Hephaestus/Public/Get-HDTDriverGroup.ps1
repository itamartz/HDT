function Get-HDTDriverGroup {
    <#
        .SYNOPSIS
            The driver groups a deployment share has.

        .DESCRIPTION
            A DRIVER GROUP IS A FOLDER UNDER Drivers\ - MDT's selection profile,
            by another name. Nothing could list them until this existed, so the
            console's Windows PE window asked an administrator to TYPE the group
            name into a box: a box you can spell wrong, after which
            Update-HDTBootImage warns that there is nothing at that path and
            builds an image with no drivers in it. That is a boot image which
            cannot see the disk, produced by a typo, discovered on a bench.

            IT LISTS FOLDERS, NOT FILES, and that distinction needs
            IFileSystem.GetDirectory rather than a filter over GetChildItem: a
            group can legitimately be called 'Dell Latitude 7450 v2.1', so
            "has a dot in it" does not mean "is a file". Drivers\ also holds
            driver-index.json beside the groups.

            A SHARE WITH NO Drivers FOLDER ANSWERS NOTHING rather than throwing.
            New-HDTWorkspace creates it, but a window opened on a hand-made
            share still has to draw its Drivers tab.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per group, in name
            order, with Name and Path.

        .EXAMPLE
            Get-HDTDriverGroup -Root 'C:\HDTLab\Share'

        .EXAMPLE
            Get-HDTDriverGroup -Root 'C:\HDTLab\Share' | Select-Object -ExpandProperty Name

            What the Windows PE window's Drivers list offers.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $folder = Get-HDTWorkspacePath -Root $Root -Kind Drivers

    if (-not $FileSystem.TestPath($folder)) { return [pscustomobject[]] @() }

    $group = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($FileSystem.GetDirectory($folder))) {
        [void] $group.Add([pscustomobject] @{
                Name = [string] (Split-Path -Path ([string] $current) -Leaf)
                Path = [string] $current
            })
    }

    # IN NAME ORDER, and not in the order the file system handed them over: a
    # list an administrator scans for a name they half remember has to be
    # somewhere predictable.
    return [pscustomobject[]] @($group | Sort-Object -Property Name)
}
