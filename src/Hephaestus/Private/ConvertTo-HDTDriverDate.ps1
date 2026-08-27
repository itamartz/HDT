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

    # THE SPEC'S FORM FIRST, THEN THE ONES VENDORS ACTUALLY SHIP. DriverVer is
    # specified as MM/DD/YYYY and that is what nearly every .inf carries, but a
    # four-digit year leading is UNAMBIGUOUS - nothing can read 2025-06-11 as a
    # US date - so accepting it costs no correctness and rescues the packs that
    # do not follow the spec. A two-digit-year ISO form is deliberately NOT
    # accepted: 06/11/25 is already claimed by the American reading.
    $format = [string[]] @(
        'MM/dd/yyyy', 'M/d/yyyy', 'MM/dd/yy', 'M/d/yy',
        'yyyy-MM-dd', 'yyyy/MM/dd', 'yyyy.MM.dd', 'yyyy-M-d', 'yyyy/M/d')
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $style = [System.Globalization.DateTimeStyles]::None

    $parsed = $floor
    if ([datetime]::TryParseExact($text, $format, $culture, $style, [ref] $parsed)) { return $parsed }

    return $floor
}
