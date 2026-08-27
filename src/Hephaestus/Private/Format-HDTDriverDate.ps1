function Format-HDTDriverDate {
    <#
        .SYNOPSIS
            A driver's date as a screen should show it.

        .DESCRIPTION
            ISO, AND FOR TWO REASONS THAT BOTH MATTER.

            IT SORTS. The console's driver grid is a DataGrid bound to strings,
            so clicking the Date header sorts the TEXT - and as text
            '11/28/2024' comes before '06/11/2025'. The column put a 2024 driver
            above a 2025 one and was lying about the one thing it exists to say.
            yyyy-MM-dd sorts correctly as text with no converter and no
            comparer.

            IT CANNOT BE MISREAD. An .inf writes 06/11/2025 meaning the 11th of
            June, because DriverVer is specified as MM/DD/YYYY whatever the
            vendor's country. Every administrator outside the United States
            reads that as the 6th of November - on a screen whose whole purpose
            is to say which of two drivers is newer.

            THE RAW STRING IS NOT REPLACED, ONLY RENDERED. Get-HDTDriver keeps
            what the file said, and the PnP tie-break compares parsed dates
            rather than displayed ones. This is the display layer, and a format
            belongs nowhere else - which is also why this exists as one command
            instead of twice: the grid and the properties window showed the same
            driver two different ways for exactly as long as they each did their
            own formatting.

            A DATE THAT WILL NOT PARSE IS RETURNED UNTOUCHED rather than blanked.
            An odd-looking date an administrator can compare against the .inf
            beats an empty cell, which says the field is missing when it is not.

        .PARAMETER Date
            The date as the .inf wrote it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String.

        .EXAMPLE
            Format-HDTDriverDate -Date '11/28/2024'

            2024-11-28.

        .EXAMPLE
            Format-HDTDriverDate -Date 'NT_x86'

            NT_x86 - unchanged, because it is not a date and hiding it would
            lose the only clue about a malformed .inf.

        .LINK
            ConvertTo-HDTDriverDate
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Date = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Date)) { return '' }

    $parsed = ConvertTo-HDTDriverDate -Value $Date

    if ($parsed -eq [datetime]::MinValue) { return [string] $Date }

    return [string] $parsed.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}
