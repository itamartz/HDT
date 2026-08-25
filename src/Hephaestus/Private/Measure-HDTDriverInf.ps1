function Measure-HDTDriverInf {
    <#
        .SYNOPSIS
            How many .inf files a folder holds, at any depth.

        .DESCRIPTION
            The number an administrator recognises a driver pack by, and the one
            the console puts on the row.

            IT RECURSES BECAUSE A VENDOR PACK IS NESTED. A Dell or HP WinPE pack
            arrives as a folder per device class - network\, storage\, chipset\ -
            and counting only the top level answers zero for every real pack
            there is. That is not a hypothetical: it is what the first version of
            this did, and the test that caught it seeds the pack the way one
            actually arrives.

            IT COUNTS, IT DOES NOT PARSE. Reading each .inf for its hardware ids
            and building driver-index.json is M5 and is what PnP matching needs;
            this is the group-match path, where a folder is named by a profile
            and injected whole.

            A FOLDER THAT IS NOT THERE ANSWERS ZERO rather than throwing. The
            caller is usually about to warn about exactly that.

        .PARAMETER Path
            The folder to count in.

        .PARAMETER FileSystem
            The IFileSystem to read with.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Int32

        .EXAMPLE
            Measure-HDTDriverInf -Path 'D:\packs\dell' -FileSystem (New-HDTFileSystem)

        .EXAMPLE
            Measure-HDTDriverInf -Path 'C:\HDTLab\Share\Drivers\WinPE' -FileSystem $fs

            What the console shows beside a driver folder.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Path)) { return 0 }

    # AN ARRAYLIST, NOT A COUNTER. '$count++' inside a scriptblock invoked with
    # '&' assigns to a NEW local in the block's own scope and leaves the outer
    # one at zero - the same scoping trap a console handler hit reaching for its
    # maker's locals. Add() mutates the object every scope is looking at.
    $found = New-Object -TypeName System.Collections.ArrayList

    $walk = {
        param([string] $Folder)

        foreach ($item in @($FileSystem.GetChildItem($Folder))) {
            if ([System.IO.Path]::GetExtension([string] $item) -eq '.inf') {
                [void] $found.Add([string] $item)
            }
        }

        foreach ($child in @($FileSystem.GetDirectory($Folder))) {
            & $walk ([string] $child)
        }
    }

    & $walk $Path

    return [int] @($found).Count
}
