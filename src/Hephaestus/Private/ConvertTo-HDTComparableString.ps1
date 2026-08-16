function ConvertTo-HDTComparableString {
    <#
        .SYNOPSIS
            Renders a value as the string the rule engine compares and
            substitutes.

        .DESCRIPTION
            The single rendering the variable engine uses, so that a value which
            arrived as a [bool] from CIM, as a [bool] from the YAML parser, or as
            a [string] from a command line all compare on the same terms
            (`when: { HDTIsLaptop: true }` must match the gathered
            fact).

            Booleans render as True and False - PowerShell's own rendering - and
            everything else formattable renders in the INVARIANT culture. That
            last part is not decoration: ToString() and the format operator both
            follow the current culture, so on a de-DE machine 32768 renders
            '32.768' and 1.5 renders '1,5'. A rules.yaml must not resolve
            differently because of the regional settings of the machine being
            deployed.

            $null renders as $null rather than as an empty string, because the
            caller distinguishes "no such value" from "an empty value": an absent
            fact never matches a condition, while an empty one may.

        .PARAMETER Value
            The value to render. Any type; $null is allowed.

        .OUTPUTS
            System.String, or $null for $null.

        .EXAMPLE
            ConvertTo-HDTComparableString -Value $true

            Returns 'True'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'True'
        }
        return 'False'
    }

    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string] $Value
}
