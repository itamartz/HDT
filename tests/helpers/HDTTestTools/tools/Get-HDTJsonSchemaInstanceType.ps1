function Get-HDTJsonSchemaInstanceType {
    <#
        .SYNOPSIS
            The JSON type name of a value ConvertFrom-Json produced.

        .DESCRIPTION
            'null', 'boolean', 'string', 'array', 'object', 'integer' or
            'number'. Integer is reported for a number with no fractional part,
            which is draft-07's rule and NOT the CLR's: `1.0` arrives from
            ConvertFrom-Json as a Decimal and is still an integer to a schema.

            THE ORDER OF THE CHECKS IS THE WHOLE FUNCTION. `$true -as [int]` is 1
            in PowerShell and `[bool]` is not [string], so a boolean tested for
            numberhood before booleanhood validates against `type: integer` -
            which is exactly the mistake a hand-written type check makes, and why
            tests/unit/JsonSchemaValidator.Tests.ps1 asserts that case by name.

        .PARAMETER Instance
            The value.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTJsonSchemaInstanceType -Instance (ConvertFrom-Json '{"v":1.0}').v

            Returns 'integer'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        $Instance
    )

    if ($null -eq $Instance) { return 'null' }
    if ($Instance -is [bool]) { return 'boolean' }
    if ($Instance -is [string]) { return 'string' }
    if ($Instance -is [System.Collections.IList]) { return 'array' }
    if ($Instance -is [System.Management.Automation.PSCustomObject]) { return 'object' }

    if ($Instance -is [byte] -or $Instance -is [int16] -or $Instance -is [int32] -or $Instance -is [int64] -or
        $Instance -is [uint16] -or $Instance -is [uint32] -or $Instance -is [uint64]) {
        return 'integer'
    }

    if ($Instance -is [decimal] -or $Instance -is [double] -or $Instance -is [single]) {
        $value = [double] $Instance
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return 'number' }
        if ($value -eq [math]::Truncate($value)) { return 'integer' }
        return 'number'
    }

    throw ("A value of type '{0}' did not come from ConvertFrom-Json and has no JSON type." -f $Instance.GetType().FullName)
}
