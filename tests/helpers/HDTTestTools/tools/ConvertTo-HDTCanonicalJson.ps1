function ConvertTo-HDTCanonicalJson {
    <#
        .SYNOPSIS
            One JSON value rendered so that two equal values render identically.

        .DESCRIPTION
            `enum`, `const` and `uniqueItems` all ask the same question - are
            these two JSON values the same one - and JSON's answer is structural:
            object member order does not matter, and 1 and 1.0 are the same
            number. PowerShell's -eq answers neither of those, so equality is
            decided on this rendering instead.

            Object members are emitted in name order and numbers are normalised
            through decimal, which is why 1 and 1.0 collapse together. It is not
            RFC 8785 - it does not need to be, since nothing here hashes or signs
            the output - it only needs to be stable and total.

        .PARAMETER Value
            Any value produced by ConvertFrom-Json.

        .OUTPUTS
            System.String

        .EXAMPLE
            ConvertTo-HDTCanonicalJson -Value (ConvertFrom-Json '{"b":1,"a":2}')

            Returns '{"a":2,"b":1}'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }

    if ($Value -is [string]) {
        return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    }

    if ($Value -is [System.Collections.IList]) {
        $part = New-Object -TypeName System.Collections.ArrayList
        foreach ($item in $Value) {
            [void] $part.Add((ConvertTo-HDTCanonicalJson -Value $item))
        }
        return '[' + ($part -join ',') + ']'
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $part = New-Object -TypeName System.Collections.ArrayList
        foreach ($property in @($Value.PSObject.Properties | Sort-Object -Property Name)) {
            [void] $part.Add((ConvertTo-HDTCanonicalJson -Value $property.Name) + ':' +
                (ConvertTo-HDTCanonicalJson -Value $property.Value))
        }
        return '{' + ($part -join ',') + '}'
    }

    # A number. ConvertFrom-Json on 5.1 hands back Int32, Int64, Decimal or
    # Double depending on how the literal was written, so 1 and 1.0 arrive as
    # two different CLR types for the same JSON value.
    $text = ''
    try {
        $text = ([decimal] $Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        # Outside decimal's range. Round-trip format keeps it distinct from
        # every other value, which is all equality needs.
        $text = ([double] $Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($text.Contains('.')) {
        $text = $text.TrimEnd('0').TrimEnd('.')
    }

    if ($text -eq '' -or $text -eq '-') { $text = '0' }

    return $text
}
