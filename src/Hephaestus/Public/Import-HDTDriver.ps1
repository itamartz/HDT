function Import-HDTDriver {
    <#
        .SYNOPSIS
            Copies a vendor driver pack into the share's driver store.

        .DESCRIPTION
            Deployment Workbench's Import Drivers, and the other half of what a
            selection profile needs: New-HDTDriverFolder makes somewhere to put
            them, this puts them there.

            IT COPIES THE WHOLE TREE, NOT THE .inf FILES. A driver is an .inf AND
            the .sys, .cat and .dll beside it, usually in a folder per device
            class - copying the .inf alone produces a folder DISM refuses and a
            boot image with nothing in it. So the source is projected in whole,
            the way media is, through the same Copy-HDTContentTree.

            IT COUNTS THE .inf FILES because that is the number an administrator
            recognises a pack by, and the number the console puts on the row. It
            is a count, NOT a catalog: parsing each .inf for its hardware ids and
            building driver-index.json is M5, and PnP matching cannot happen
            until it exists. What this gives you is the group-match path, which
            is MDT's primary one - a folder, named by a profile, injected whole.

            A SOURCE WITH NO .inf IN IT IS ALMOST ALWAYS THE WRONG FOLDER -
            somebody picked the download rather than the extracted pack - so it
            warns rather than leaving a silently empty driver folder that a
            profile will happily include and a build will happily inject nothing
            from.

            THE DESTINATION IS CHECKED THE WAY A PROFILE'S INCLUDE IS. A path
            that climbs out of the share would copy a vendor pack somewhere it
            was not asked to, and then be includable.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            Where to put them, relative to Drivers\. Created if it is not there.

        .PARAMETER Source
            The extracted vendor pack to copy in.

        .PARAMETER FileSystem
            The IFileSystem to work through. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FullPath,
            Source and DriverCount.

        .EXAMPLE
            Import-HDTDriver -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell WinPE 11 x64' -Source 'D:\packs\dell-winpe'

            A vendor's WinPE pack, where a boot-critical profile can name it.

        .EXAMPLE
            Import-HDTDriver -Root 'C:\HDTLab\Share' -Path 'Dell\Latitude 7450' -Source 'D:\packs\7450' -WhatIf

            What it would copy and where, without copying it.

        .LINK
            New-HDTDriverFolder

        .LINK
            New-HDTSelectionProfile
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category ObjectNotFound `
                    -Message 'there is nothing to import here. Point at the folder the vendor pack was extracted into.'))
    }

    # The destination's rules are the profile's rules; New-HDTDriverFolder owns
    # them, so this refuses through the same command rather than a second copy.
    $folder = New-HDTDriverFolder -Root $Root -Path $Path -FileSystem $FileSystem -Confirm:$false `
        -WhatIf:$WhatIfPreference

    $full = [string] $folder.FullPath

    # HOW MANY DRIVERS ARE ACTUALLY IN THERE, counted at the SOURCE so the answer
    # is known before anything is written and -WhatIf can report it too. It
    # RECURSES: a vendor pack is a folder per device class, and counting only the
    # top level answers zero for every real pack there is.
    $infCount = Measure-HDTDriverInf -Path $Source -FileSystem $FileSystem

    if ($infCount -eq 0) {
        Write-Warning ("'{0}' holds no .inf files, so this import adds no drivers. That is usually the downloaded archive rather than the folder it was extracted into." -f $Source)
    }

    if (-not $PSCmdlet.ShouldProcess($full, ("Copy {0} driver(s) from '{1}'" -f $infCount, $Source))) {
        return [pscustomobject] @{
            Path        = $Path
            FullPath    = $full
            Source      = $Source
            DriverCount = $infCount
        }
    }

    Copy-HDTContentTree -Source $Source -Destination $full -FileSystem $FileSystem

    return [pscustomobject] @{
        Path        = $Path
        FullPath    = $full
        Source      = $Source
        DriverCount = $infCount
    }
}
