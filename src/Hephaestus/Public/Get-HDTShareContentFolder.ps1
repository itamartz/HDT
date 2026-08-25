function Get-HDTShareContentFolder {
    <#
        .SYNOPSIS
            Every folder on a share a selection profile is allowed to include
            from.

        .DESCRIPTION
            WHAT THE PROFILE EDITOR'S TICK BOX TREE IS MADE OF. An administrator
            knows the folder they want by SEEING it, not by typing its path -
            which is why MDT put a tree here and not a text box, and why this
            exists at all.

            IT ROOTS ON THE FIVE CONTENT FOLDERS AND NOTHING ELSE.
            Get-HDTSelectionProfileContentFolder decides which; Boot\, Logs\,
            Captures\, Control\ and Modules\ are absent because a profile may not
            include them. A tree that offered Logs\ would be a tree an
            administrator could tick to put every other machine's logs into a
            boot image.

            THE FIVE ARE ALWAYS ROWS, PRESENT OR NOT. A tree that hid
            Applications because nobody had imported one would be a tree nobody
            could tick the day they did - and Present says which, so the window
            can mark it rather than lie by omission.

            IT IS DEPTH-BOUNDED AND SAYS WHERE IT STOPPED. A driver store is
            tens of thousands of files; a tick box tree is not a file browser,
            and MDT's own is lazy for the same reason. Four levels reaches
            Drivers\WinPE\<vendor pack> and Drivers\<Make>\<Model>, which is
            what "Total Control" actually looks like. A folder whose children
            were cut carries Truncated, because a folder simply MISSING from a
            tree reads as a folder that is not on the share.

            IT READS THROUGH AN INJECTED IFileSystem - never Get-ChildItem - so
            the whole editor is provable under Pester with no share and no disk.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Depth
            How many levels below each content folder to walk. The content folder
            itself is depth 0.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per folder, parents
            before children, with Path (share-relative), Name, Depth, Present and
            Truncated.

        .EXAMPLE
            Get-HDTShareContentFolder -Root 'C:\HDTLab\Share'

        .EXAMPLE
            Get-HDTShareContentFolder -Root 'C:\HDTLab\Share' |
                Where-Object { $_.Path -like 'Drivers\WinPE\*' }

            The vendor WinPE packs a boot image profile is built from.

        .LINK
            Get-HDTSelectionProfile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [ValidateRange(1, 8)]
        [int] $Depth = 4,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $row = New-Object -TypeName System.Collections.ArrayList

    # Depth-first, parents before children, because that is the order a tree
    # builder consumes and the order a reader expects to see a share in.
    $walk = {
        param([string] $Relative, [string] $Full, [int] $Level)

        $child = @()
        $present = [bool] $FileSystem.TestPath($Full)

        if ($present) { $child = @($FileSystem.GetDirectory($Full)) }

        # TRUNCATED MEANS "there is more and this is not showing it", so it is
        # false for a folder with no children at all - a leaf is not a bound.
        $truncated = ($Level -ge $Depth) -and (@($child).Count -gt 0)

        [void] $row.Add([pscustomobject] @{
                Path      = $Relative
                Name      = [string] (Split-Path -Path $Relative -Leaf)
                Depth     = $Level
                Present   = $present
                Truncated = $truncated
            })

        if ($Level -ge $Depth) { return }

        foreach ($current in @($child | Sort-Object)) {
            $leaf = [string] (Split-Path -Path ([string] $current) -Leaf)

            & $walk ([System.IO.Path]::Combine($Relative, $leaf)) ([string] $current) ($Level + 1)
        }
    }

    foreach ($kind in @(Get-HDTSelectionProfileContentFolder)) {
        & $walk $kind ([System.IO.Path]::Combine($Root, $kind)) 0
    }

    return [pscustomobject[]] @($row)
}
