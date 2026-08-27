function ConvertTo-HDTDriverDate {
    <#
        .SYNOPSIS
            A driver's DriverVer date as something that sorts.

        .DESCRIPTION
            AN .inf DATE IS MONTH/DAY/YEAR, ALWAYS, WHATEVER THE MACHINE'S
            LOCALE IS. The DriverVer directive is specified that way, and a
            vendor in Frankfurt still ships 06/11/2025 meaning the 11th of June.
            Parsing it with the current culture is how a share administered from
            a machine set to en-GB reads every driver's date wrong for eleven
            days of each month and correctly for the rest - a bug that looks
            like nothing at all until a tie-break picks the older pack.

            SO THE CULTURE IS PINNED AND THE FORMATS ARE LISTED. Two digits or
            one, four-digit year or two, which is the whole range DriverVer
            permits.

            A DATE THAT WILL NOT PARSE SORTS LAST rather than throwing, for the
            reason ConvertTo-HDTDriverVersion sorts an unreadable version last:
            one malformed .inf in a vendor pack of a hundred and forty must not
            decide the match for the other hundred and thirty-nine.

        .PARAMETER Value
            The date as read out of the .inf, or anything else.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.DateTime. [datetime]::MinValue for anything unparseable.

        .EXAMPLE
            ConvertTo-HDTDriverDate -Value '06/11/2025'

            The 11th of June 2025, on a machine set to any locale at all.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $floor = [datetime]::MinValue

    $text = ''
    if ($null -ne $Value) { $text = ([string] $Value).Trim() }

    if ([string]::IsNullOrEmpty($text)) { return $floor }

    $format = [string[]] @('MM/dd/yyyy', 'M/d/yyyy', 'MM/dd/yy', 'M/d/yy')
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $style = [System.Globalization.DateTimeStyles]::None

    $parsed = $floor
    if ([datetime]::TryParseExact($text, $format, $culture, $style, [ref] $parsed)) { return $parsed }

    return $floor
}
