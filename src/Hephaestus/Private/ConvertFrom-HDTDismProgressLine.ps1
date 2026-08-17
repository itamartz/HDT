function ConvertFrom-HDTDismProgressLine {
    <#
        .SYNOPSIS
            Reads dism.exe's progress meter back as a whole number, or nothing.

        .DESCRIPTION
            THE LOGIC BEHIND AN ADAPTER THAT IS NOT ALLOWED ANY. New-HDTImageService
            runs dism.exe and is not unit tested - four of its five methods write
            to a disk - so it must stay branch-free (CLAUDE.md rule 1). It hands
            every line the tool writes to a callback; this decides which of them
            is a percentage, and it is pure, so the deciding is asserted against
            a captured transcript in tests/unit.

            THE METER'S SHAPE IS NOT THE OBVIOUS ONE, which is the whole reason
            this is tested against real output rather than written from memory
            (tests/fixtures/image/dism-apply-image-output.txt, captured on this
            machine):

                [                           1.0%                           ]
                [===========================85.0%=================         ]
                [==========================100.0%==========================]

            At 1% the number floats in spaces; at 85% it has an '=' run on both
            sides; at 100% it is embedded in a solid bar with no space around it
            at all. A pattern anchored on whitespace reads the first two and
            misses the one that says the apply finished.

            NOTHING IS RETURNED FOR ANYTHING ELSE, and that includes a sentence
            with a percentage in it. dism writes prose - a banner, a version, an
            error - and a bar that jumped because an error message mentioned a
            number would be lying at the moment somebody was reading it hardest.
            The meter is required to be the whole line: brackets, then a
            percentage inside them.

            THE FRACTION IS FLOORED, NEVER ROUNDED. 99.9% is not 100%, and the
            number on a technician's screen must not say finished before the
            tool has.

        .PARAMETER Line
            One line of dism.exe output, as the call operator hands it over.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Int32 - the percentage, 0 to 100. Nothing at all for a line
            that is not the meter.

        .EXAMPLE
            ConvertFrom-HDTDismProgressLine -Line '[====        37.0%        ] '

            37
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    # THE BRACKETS ARE THE PROOF THAT IT IS A METER. '=' and space are the only
    # things dism fills the bar with, and the number sits between them with no
    # separator guaranteed on either side.
    $match = [regex]::Match($Line.Trim(), '^\[[=\s]*([0-9]+(?:\.[0-9]+)?)%[=\s]*\]$')
    if (-not $match.Success) { return }

    $percent = [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)

    return [int] [System.Math]::Floor($percent)
}
