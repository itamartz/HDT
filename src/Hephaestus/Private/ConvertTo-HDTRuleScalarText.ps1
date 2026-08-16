function ConvertTo-HDTRuleScalarText {
    <#
        .SYNOPSIS
            One rule value, written so the engine reads back what the caller
            passed in.

        .DESCRIPTION
            THE RULES EDITOR IS HANDED OBJECTS, NOT TEXT. A condition is $true
            rather than 'true' and a version is 10 rather than '10', so something
            has to decide how each one is spelled in the file - and it has to
            spell it the way the reader will turn it back into the same thing.

            A BOOLEAN AND A NUMBER ARE WRITTEN BARE, because that is what makes
            them a boolean and a number when the file is read again. A number is
            formatted with the invariant culture: a machine whose decimal
            separator is a comma would otherwise write 1,5 into a YAML document,
            where the comma means something else entirely.

            A STRING THAT LOOKS LIKE ONE OF THOSE IS QUOTED. An administrator who
            asks for the string 'true' or the string '007' means those
            characters; written bare they would come back as a boolean and as the
            number 7, and the asset tag would have lost its leading zeroes
            somewhere between the console and the deployment.

            EVERYTHING ELSE GOES THROUGH THE SHARED QUOTER, which is the same one
            the task sequence editor uses, so a value written by one editor and a
            value written by the other are quoted by the same rule.

        .PARAMETER Value
            The value as the caller supplied it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the value, quoted if it has to be.

        .EXAMPLE
            ConvertTo-HDTRuleScalarText -Value $true

        .EXAMPLE
            ConvertTo-HDTRuleScalarText -Value 'Latitude*'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Value) {
        return "''"
    }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }

    if (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [double]) -or ($Value -is [decimal])) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }

    $text = [string] $Value

    # The strings YAML would read back as something other than a string.
    if ($text -match '^(?i:true|false|yes|no|on|off|null|~)$' -or
        $text -match '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$' -or
        [string]::IsNullOrEmpty($text)) {

        return "'{0}'" -f ($text -replace "'", "''")
    }

    return (Get-HDTConsoleScalarText -Value $text)
}
