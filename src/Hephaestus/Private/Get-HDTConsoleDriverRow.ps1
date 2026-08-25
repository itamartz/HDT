function Get-HDTConsoleDriverRow {
    <#
        .SYNOPSIS
            The drivers in one folder, as the console's grid shows them.

        .DESCRIPTION
            Get-HDTDriver's answer, projected for a DataGrid: the columns bind
            to these names, and the one thing added is StateMark - the tick or
            the word the Enabled column shows.

            A TICK AND THE WORD 'no', NOT A CHECKBOX. A tick box in a read-only
            grid invites a click that does nothing; the state is CHANGED in the
            properties window a double-click opens, where the box is real and
            sits beside the thing it affects. Two places to set one value is two
            places that disagree.

            A FOLDER THAT CANNOT BE READ ANSWERS NOTHING rather than throwing.
            The grid is drawn while somebody clicks around a tree, and a share
            with a driver folder somebody deleted mid-session must not take the
            window down.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            The folder, as the row names it - 'Drivers\WinPE\Dell'. The leading
            'Drivers\' is dropped, because Get-HDTDriver counts from inside the
            store.

        .PARAMETER FileSystem
            The IFileSystem to read with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per driver, with
            StateMark, Name, Class, Provider, Version, Date, Path, Enabled and
            HardwareId.

        .EXAMPLE
            Get-HDTConsoleDriverRow -Root 'C:\HDTLab\Share' -Path 'Drivers\WinPE\Dell'

        .EXAMPLE
            @(Get-HDTConsoleDriverRow -Root $root -Path 'Drivers' | Where-Object { $_.StateMark -eq 'no' })

            The disabled ones, which is what the column exists to make findable.

        .LINK
            Get-HDTDriver
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
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

    if ([string]::IsNullOrWhiteSpace($Root)) { return [pscustomobject[]] @() }

    # THE ROW NAMES ITSELF FROM THE STORE'S ROOT - 'Drivers\WinPE\Dell' - and
    # Get-HDTDriver counts from inside it.
    $inside = [string] $Path
    if ($inside -match '^(?i)Drivers$') { $inside = '' }
    if ($inside -match '^(?i)Drivers\\') { $inside = $inside.Substring('Drivers\'.Length) }

    $driver = @()

    try {
        $driver = @(Get-HDTDriver -Root $Root -Path $inside -FileSystem $FileSystem)
    } catch {
        Write-Verbose ("the driver folder could not be read: {0}" -f [string] $_.Exception.Message)
        return [pscustomobject[]] @()
    }

    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in @($driver)) {
        $mark = 'no'
        if ([bool] $one.Enabled) { $mark = [string] ([char] 0x2713) }

        [void] $row.Add([pscustomobject] @{
                StateMark  = $mark
                Name       = [string] $one.Name
                Class      = [string] $one.Class
                Provider   = [string] $one.Provider
                Version    = [string] $one.Version
                Date       = [string] $one.Date
                Path       = [string] $one.Path
                FullPath   = [string] $one.FullPath
                Enabled    = [bool] $one.Enabled
                HardwareId = [string[]] @($one.HardwareId)
                ModelCount = [int] $one.ModelCount
                InfName    = [string] $one.InfName
            })
    }

    return [pscustomobject[]] @($row)
}
