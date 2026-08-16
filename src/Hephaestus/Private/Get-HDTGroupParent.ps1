function Get-HDTGroupParent {
    <#
        .SYNOPSIS
            The key identifying the group one level above the given group path.

        .DESCRIPTION
            Used to work out which groups are each other's neighbours, which is
            what decides whether Up and Down are offered on a group.

            A TOP-LEVEL GROUP'S PARENT IS THE EMPTY KEY, not an error and not a
            path of its own. It is written as a separate function because
            slicing an array to "all but the last" is the one expression in
            PowerShell that quietly does the opposite on a one-element array:
            $path[0..($path.Count - 2)] with a count of 1 indexes -1, which is
            the LAST element, so a top-level group would come back as its own
            parent and every top-level group would then look like a neighbour of
            nothing.

            THE SEPARATOR IS THE UNIT SEPARATOR, as everywhere else group paths
            are keyed, so a group legitimately called 'A\B' cannot collide with
            a group 'B' inside a group 'A'.

        .PARAMETER Path
            The group's path, outermost first.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the parent's key, empty for a top-level group.

        .EXAMPLE
            Get-HDTGroupParent -Path @('Install', 'Drivers')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $part = @($Path)

    if ($part.Count -le 1) {
        return ''
    }

    return (($part[0..($part.Count - 2)]) -join "`u{001F}")
}
