function Get-HDTDriver {
    <#
        .SYNOPSIS
            The drivers in a share's driver store, read out of the .inf files
            themselves.

        .DESCRIPTION
            WHAT THE CONSOLE'S DRIVER GRID IS MADE OF, and what a selection
            profile could not tell you: a profile names FOLDERS, and this says
            what is inside one - the class, who made it, its version and date,
            and the PnP ids it claims.

            IT PARSES, IT DOES NOT INDEX. Every call reads the .inf files under
            the folder. A vendor WinPE pack is forty of them and reading forty
            small files is nothing; a driver-index.json that could go stale
            against the folder it describes is a second opinion about the share,
            and the share is the one that matters.

            THE ENABLED FLAG IS THE ONE THING NOT IN THE .inf, because there is
            nowhere in an .inf to put it. It comes from
            Control\driver-state.yaml, which records only the drivers somebody
            has turned OFF - so a store nobody has disabled anything in needs no
            document at all, and a driver added tomorrow is enabled without
            anybody writing anything.

            ENCODING IS HANDLED HERE, WHICH IS WHY THE PARSER TAKES A STRING.
            .inf files ship UTF-16LE as often as ANSI; ReadAllText detects the
            byte order mark, and a parser that took a path would have to know
            that too.

            A FILE THAT WILL NOT PARSE IS STILL A ROW. It comes back with its
            name and nothing else rather than throwing, because one malformed
            .inf in a vendor pack must not empty the grid - the same rule
            Get-HDTConsoleWorkspace follows for a sequence that will not load.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            A folder under Drivers\ to read. Omitted, the whole store.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per .inf, in path order,
            with Name, InfName, Folder, Path, FullPath, Class, Provider, Version,
            Date, HardwareId, ModelCount and Enabled.

        .EXAMPLE
            Get-HDTDriver -Root 'C:\HDTLab\Share'

            Every driver on the share.

        .EXAMPLE
            Get-HDTDriver -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell WinPE 11 x64' |
                Where-Object { $_.Class -eq 'Net' }

            The network drivers in one vendor pack - which is what the boot
            image actually needs from it.

        .EXAMPLE
            (Get-HDTDriver -Root 'C:\HDTLab\Share' | Where-Object { -not $_.Enabled }).Count

            How many drivers on this share are turned off.

        .LINK
            Import-HDTDriver

        .LINK
            Disable-HDTDriver
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers

    $folder = $store
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $folder = [System.IO.Path]::Combine($store, $Path.Trim().TrimStart('\', '/'))
    }

    if (-not $FileSystem.TestPath($folder)) { return [pscustomobject[]] @() }

    $disabled = Get-HDTDriverState -Root $Root -FileSystem $FileSystem

    $row = New-Object -TypeName System.Collections.ArrayList

    # AN ARRAYLIST AND A SCRIPTBLOCK, not a counter and recursion into a
    # variable: '&' gives the block its own scope, so anything it assigns to is
    # lost. Add() mutates the object every scope can see.
    $walk = {
        param([string] $Current)

        foreach ($item in @($FileSystem.GetChildItem($Current) | Sort-Object)) {
            if (([System.IO.Path]::GetExtension([string] $item)).ToLowerInvariant() -ne '.inf') { continue }

            [void] $row.Add([string] $item)
        }

        foreach ($child in @($FileSystem.GetDirectory($Current) | Sort-Object)) {
            & $walk ([string] $child)
        }
    }

    & $walk $folder

    $driver = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in @($row)) {
        $relative = [string] $file

        if ($relative.StartsWith($store, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $relative.Substring($store.Length).TrimStart('\', '/')
        }

        $parsed = $null

        try {
            $parsed = ConvertFrom-HDTDriverInf -Text ([string] $FileSystem.ReadAllText($file)) `
                -InfName ([System.IO.Path]::GetFileName([string] $file))
        } catch {
            # ONE BAD .inf MUST NOT EMPTY THE GRID.
            $parsed = [pscustomobject] @{
                InfName = [System.IO.Path]::GetFileName([string] $file)
                Name = '(this .inf could not be read)'; Class = ''; ClassGuid = ''
                Provider = ''; Version = ''; Date = ''; CatalogFile = ''
                ModelCount = 0; HardwareId = [string[]] @()
            }
        }

        $name = [string] $parsed.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] $parsed.InfName }

        [void] $driver.Add([pscustomobject] @{
                Name        = $name
                InfName     = [string] $parsed.InfName
                Folder      = [string] (Split-Path -Path $relative -Parent)
                Path        = $relative
                FullPath    = [string] $file
                Class       = [string] $parsed.Class
                Provider    = [string] $parsed.Provider
                Version     = [string] $parsed.Version
                Date        = [string] $parsed.Date
                ModelCount  = [int] $parsed.ModelCount
                HardwareId  = [string[]] @($parsed.HardwareId)
                Enabled     = (-not ($disabled -contains $relative))
            })
    }

    return [pscustomobject[]] @($driver)
}
