function Test-HDTFunctionName {
    <#
        .SYNOPSIS
            Tests whether a function name obeys the DESIGN 15.1 Verb-HDTNoun rule.

        .DESCRIPTION
            Returns $true when the name is a valid HDT command name and $false
            otherwise. The rule itself lives in Get-HDTFunctionNameViolation; this is
            the boolean face of it, for call sites that only need a yes or no.

        .PARAMETER Name
            The function name to test. An empty string or $null is not a valid name
            and returns $false rather than throwing.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTFunctionName -Name 'ConvertTo-HDTReport'

            Returns $true.

        .EXAMPLE
            Test-HDTFunctionName -Name 'Get-HdtThing'

            Returns $false: the prefix must be uppercase HDT.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    process {
        return (@(Get-HDTFunctionNameViolation -Name $Name).Count -eq 0)
    }
}
