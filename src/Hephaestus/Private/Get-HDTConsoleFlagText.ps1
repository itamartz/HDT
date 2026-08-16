function Get-HDTConsoleFlagText {
    <#
        .SYNOPSIS
            Renders a true/false fact the way the console shows it.

        .DESCRIPTION
            'True' and 'False' are how PowerShell prints a boolean, not how a
            person reads one. A field captioned "Folder exists" answers yes or
            no, and rendering it here keeps that decision out of every caller
            that has a flag to show.

        .PARAMETER Value
            The flag.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleFlagText -Value $workspace.Driver.Present

            Returns 'yes' or 'no'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [bool] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Value) {
        return 'yes'
    }

    return 'no'
}
