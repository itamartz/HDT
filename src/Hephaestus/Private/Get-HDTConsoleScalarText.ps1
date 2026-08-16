function Get-HDTConsoleScalarText {
    <#
        .SYNOPSIS
            One value, written the way it can be read back.

        .DESCRIPTION
            A PLAIN SCALAR IS WHAT AN ADMINISTRATOR WANTS TO READ IN A DIFF, so
            a value is written bare wherever bare is unambiguous - which is
            nearly always, because most of what goes in these keys is a number,
            a word or a PowerShell expression.

            IT IS QUOTED ONLY WHEN BARE WOULD BE READ BACK AS SOMETHING ELSE. A
            colon-space splits one key into two, a space-hash comments the rest
            of the value out, and a leading quote or YAML indicator opens a
            construct the rest of the value does not close. Those are the cases,
            and quoting outside them would put quotation marks around every
            number in the file.

            SINGLE QUOTES, WITH DOUBLING TO ESCAPE. A single-quoted YAML scalar
            has no escape sequences other than '' for a quote, so a Windows path
            or a regular expression survives it unaltered - which double quotes,
            with their backslash escapes, would not.

            IT IS SHARED because Set-HDTConsoleStepCondition and
            Set-HDTConsoleStepProperty must agree about it. Two copies of a
            quoting rule is two quoting rules as soon as one of them is fixed.

        .PARAMETER Value
            The value as the administrator typed it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the value, quoted if it has to be.

        .EXAMPLE
            Get-HDTConsoleScalarText -Value '2'

        .EXAMPLE
            Get-HDTConsoleScalarText -Value 'C:\Windows: the one on this disk'

            Comes back single-quoted, because the colon-space would otherwise
            split the key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Value -match ':\s' -or $Value -match '\s#' -or $Value -match '^["''\{\[\&\*\!\|\>\%\@\`\#]') {
        return "'{0}'" -f ($Value -replace "'", "''")
    }

    return $Value
}
