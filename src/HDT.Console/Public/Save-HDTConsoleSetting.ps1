function Save-HDTConsoleSetting {
    <#
        .SYNOPSIS
            Remembers the size the console was left at.

        .DESCRIPTION
            Written when the window closes, read when it opens, so an
            administrator sizes the console once rather than every morning.

            IT NEVER THROWS. The window is already on its way out by the time
            this runs, and there is nothing useful anybody could do with an error
            about a preference file - a read-only profile, a full disk, a roaming
            profile mid-sync. It returns whether it saved instead, so a caller
            that cares can say so and the rest can ignore it.

            IT REFUSES A SIZE THE WINDOW COULD NOT OPEN AT. A minimised or
            zero-height window reports a size no one can use, and remembering it
            would leave a console that opens unusably small - the state hardest
            to escape, because escaping it means using the window.

            IT WRITES NOTHING TO A DEPLOYMENT SHARE. The path is under the user
            profile (Get-HDTConsoleSettingPath) and a test asserts it.

        .PARAMETER Width
            The width to remember, in device-independent units.

        .PARAMETER Height
            The height to remember.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter by default.

        .PARAMETER Environment
            An IEnvironmentProvider - the real adapter by default.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether the size was written.

        .EXAMPLE
            [void] (Save-HDTConsoleSetting -Width 1800 -Height 900)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one preference file under the user profile and reports whether it managed to. It cannot fail a caller and has nothing to confirm.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $Width,

        [Parameter(Mandatory = $true)]
        [int] $Height,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Environment) { $Environment = New-HDTEnvironmentProvider }

    if ($Width -lt $script:HDTConsoleMinimumWidth -or $Height -lt $script:HDTConsoleMinimumHeight) {
        Write-Verbose ('A console size of {0} x {1} is below the window minimum and was not remembered.' -f $Width, $Height)
        return $false
    }

    $path = Get-HDTConsoleSettingPath -Environment $Environment

    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $document = [pscustomobject] @{
        schemaVersion = 1
        width         = $Width
        height        = $Height
    }

    try {
        $FileSystem.WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 3))
        return $true
    } catch {
        Write-Verbose ("The console size could not be saved to '{0}': {1}" -f $path, [string] $_.Exception.Message)
        return $false
    }
}
