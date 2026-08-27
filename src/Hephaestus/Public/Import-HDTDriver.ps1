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
        [object] $FileSystem = (New-HDTFileSystem),

        # THE ONE EXTERNAL TOOL THIS COMMAND NEEDS, injected so a cab import is
        # provable without expand.exe actually running.
        [Parameter()]
        [AllowNull()]
        [object] $Process = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Process) { $Process = New-HDTProcessService }

    if (-not $FileSystem.TestPath($Source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category ObjectNotFound `
                    -Message 'there is nothing to import here. Point at the folder the vendor pack was extracted into.'))
    }

    # -- what did they actually point at? -------------------------------------
    #
    # A DELL WinPE PACK IS A .cab AND AN HP ONE IS A SELF-EXTRACTING .exe.
    # Pointing at the download is the ordinary case, not a mistake, so an
    # archive is expanded rather than refused.
    # NOT '$source' - PowerShell is case-insensitive, so that assignment would
    # overwrite the -Source parameter with this object and every later use of it
    # would read a property off a string.
    $sourceKind = Get-HDTDriverSourceKind -Path $Source -FileSystem $FileSystem

    # NOTHING USABLE IS REFUSED HERE, not by the archive path - that one takes a
    # mandatory -Archive, and an empty one fails on parameter validation with a
    # message about a parameter instead of about the folder somebody picked.
    if ([string] $sourceKind.Kind -eq 'Empty') {
        $archive = @($FileSystem.GetChildItem($Source) | Where-Object {
                @('.cab', '.exe', '.zip', '.msi') -contains
                ([System.IO.Path]::GetExtension([string] $_)).ToLowerInvariant()
            })

        $detail = 'It holds no .inf files and nothing that can be expanded into any.'

        if (@($archive).Count -gt 1) {
            $detail = ('It holds {0} archives and no .inf files, so there is no way to tell which one is the driver pack. Point at one of them.' -f
                @($archive).Count)
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category InvalidData `
                    -Message ("'{0}' is not a driver source. {1}" -f $Source, $detail)))
    }

    if ([string] $sourceKind.Kind -ne 'Folder') {
        return Import-HDTDriverArchive -Root $Root -Path $Path -Source $Source `
            -Kind ([string] $sourceKind.Kind) -Archive ([string] $sourceKind.Archive) `
            -Vendor ([string] $sourceKind.Vendor) `
            -FileSystem $FileSystem -Process $Process -Cmdlet $PSCmdlet `
            -WhatIf:$WhatIfPreference
    }

    # HOW MANY DRIVERS ARE ACTUALLY IN THERE, COUNTED BEFORE ANYTHING IS MADE.
    # The folder used to be created first, so a refused import still left an
    # empty driver folder on the share - which is worse than nothing: it appears
    # in the profile editor's tree, invites a tick, and injects nothing.
    #
    # It RECURSES: a vendor pack is a folder per device class, and counting only
    # the top level answers zero for every real pack there is.
    $infCount = Measure-HDTDriverInf -Path $Source -FileSystem $FileSystem

    # IT REFUSES, AND IT USED TO WARN. A warning is invisible in a WPF app: the
    # console imported a folder holding nothing but a Dell .cab, said nothing an
    # administrator saw, and left a driver folder that a profile would include
    # and a build would inject nothing from - found on a bench, weeks later.
    #
    # AND IT NAMES THE ARCHIVE IT FOUND. Dell and HP ship WinPE packs as a .cab,
    # and pointing at the download rather than the folder it was expanded into is
    # the commonest way to get this wrong. A refusal that only says what it
    # wanted leaves somebody re-picking the same folder.
    if ($infCount -eq 0) {
        $archive = @($FileSystem.GetChildItem($Source) | Where-Object {
                @('.cab', '.zip', '.msi', '.exe') -contains
                ([System.IO.Path]::GetExtension([string] $_)).ToLowerInvariant()
            })

        $found = 'nothing that looks like a driver'
        $fix = 'Point at the folder the vendor pack was extracted into.'

        if (@($archive).Count -gt 0) {
            $found = ("'{0}'" -f [System.IO.Path]::GetFileName([string] @($archive)[0]))
            $fix = 'Expand it first - a vendor pack is an archive, and the driver store holds the .inf tree inside it, not the download.'
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Source `
                    -Category InvalidData `
                    -Message ("'{0}' holds no .inf files, so this would import no drivers - it holds {1}. {2}" -f
                        $Source, $found, $fix)))
    }

    # The destination's rules are the profile's rules; New-HDTDriverFolder owns
    # them, so this refuses through the same command rather than a second copy.
    $folder = New-HDTDriverFolder -Root $Root -Path $Path -FileSystem $FileSystem -Confirm:$false `
        -WhatIf:$WhatIfPreference

    $full = [string] $folder.FullPath

    if (-not $PSCmdlet.ShouldProcess($full, ("Copy {0} driver(s) from '{1}'" -f $infCount, $Source))) {
        return [pscustomobject] @{
            Path        = $Path
            FullPath    = $full
            Source      = $Source
            DriverCount = $infCount
        }
    }

    # [void], BECAUSE IT RETURNS THE FILES IT COPIED. Left unswallowed they join
    # this command's output, and the caller gets an ARRAY whose last element is
    # the result object - so '.DriverCount' is a property that cannot be found.
    [void] (Copy-HDTContentTree -Source $Source -Destination $full -FileSystem $FileSystem)

    return [pscustomobject] @{
        Path        = $Path
        FullPath    = $full
        Source      = $Source
        DriverCount = $infCount
    }
}
