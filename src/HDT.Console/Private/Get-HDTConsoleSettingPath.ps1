function Get-HDTConsoleSettingPath {
    <#
        .SYNOPSIS
            Where the console keeps the size it was left at.

        .DESCRIPTION
            %APPDATA%\HDT\console.json, and one place decides that so the reader
            and the writer cannot disagree about it.

            APPDATA IS READ THROUGH THE ENVIRONMENT PROVIDER rather than from
            $env:APPDATA, so the whole path is provable under Pester on a machine
            whose profile is somewhere else entirely.

            NO APPDATA MEANS NO FILE, NOT A GUESS. A process running without a
            user profile - a service account, a locked-down context - gets an
            empty path, and the caller answers with the default size. Inventing a
            location would put a file somewhere nobody would think to look for it
            and nobody would clean up.

        .PARAMETER Environment
            An IEnvironmentProvider.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the path, or an empty string when there is no
            profile to put it in.

        .EXAMPLE
            Get-HDTConsoleSettingPath -Environment (New-HDTEnvironmentProvider)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $appData = [string] $Environment.GetVariable('APPDATA')

    if ([string]::IsNullOrWhiteSpace($appData)) {
        return ''
    }

    return [System.IO.Path]::Combine($appData, 'HDT', 'console.json')
}
