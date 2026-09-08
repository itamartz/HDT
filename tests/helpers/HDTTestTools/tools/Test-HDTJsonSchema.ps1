function Test-HDTJsonSchema {
    <#
        .SYNOPSIS
            Tests whether a JSON document validates against a JSON Schema, on
            Windows PowerShell 5.1.

        .DESCRIPTION
            Returns $true when Get-HDTJsonSchemaViolation finds nothing and
            $false otherwise. The rule itself lives there; this is the boolean
            face of it, and it is the shape the schema contract suites compare
            against Assert-HDT*Document's verdict.

            A REAL BOOLEAN, NOT A TRUTHY OBJECT. `Should -BeTrue` passes for a
            non-empty array, so a contract handed a list of violations instead of
            $false would report the wrong verdict as success.

            Test-Json's own signature is deliberately mirrored - -Json and
            -Schema, in that order - so a call site reads the same on either
            engine. It does NOT mirror Test-Json's habit of writing an error
            record on failure: a caller that wants the reason asks
            Get-HDTJsonSchemaViolation for it.

        .PARAMETER Json
            The document, as text.

        .PARAMETER Schema
            The JSON Schema, as text.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTJsonSchema -Json (Get-Content ./state.json -Raw) -Schema (Get-Content ./schemas/state.schema.json -Raw)

            Returns $true when the state document satisfies its schema.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Schema
    )

    return [bool] (@(Get-HDTJsonSchemaViolation -Json $Json -Schema $Schema).Count -eq 0)
}
