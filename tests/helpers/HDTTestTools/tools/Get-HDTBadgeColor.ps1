function Get-HDTBadgeColor {
    <#
        .SYNOPSIS
            Picks the shields.io colour for a percentage.

        .DESCRIPTION
            ONE PLACE THAT DECIDES WHAT A NUMBER LOOKS LIKE. Coverage is the
            only caller today, but the moment a second badge carries a
            percentage the bands have to be the same ones or the README starts
            telling two stories about what "green" means.

            The bands are shields.io's own convention, which is what a reader
            arriving from any other repository already expects:

                90 and above  brightgreen
                80 to 90      green
                70 to 80      yellowgreen
                60 to 70      yellow
                50 to 60      orange
                below 50      red

        .PARAMETER Percent
            The percentage, 0 to 100. A number outside that range is a
            computation that went wrong upstream, and a badge is the last place
            it should be discovered, so it throws.

        .OUTPUTS
            System.String - a shields.io colour name.

        .EXAMPLE
            Get-HDTBadgeColor -Percent 83.4

            green
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(0, 100)]
        [double] $Percent
    )

    if ($Percent -ge 90) { return 'brightgreen' }
    if ($Percent -ge 80) { return 'green' }
    if ($Percent -ge 70) { return 'yellowgreen' }
    if ($Percent -ge 60) { return 'yellow' }
    if ($Percent -ge 50) { return 'orange' }

    return 'red'
}
