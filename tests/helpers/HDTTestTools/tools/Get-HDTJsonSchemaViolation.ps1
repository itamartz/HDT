function Get-HDTJsonSchemaViolation {
    <#
        .SYNOPSIS
            Validates a JSON document against a JSON Schema on Windows PowerShell 5.1.

        .DESCRIPTION
            THE REASON THIS EXISTS. Test-Json is PowerShell 6+, and HDT's gate is
            Windows PowerShell 5.1 - the edition WinPE ships and therefore the
            only one that decides whether the engine works. Twelve contract
            suites validated schemas/*.schema.json with Test-Json behind
            `-Skip:(-not (Get-Command Test-Json))`, so on the gate all twelve
            Describe blocks vanished whole and reported green having executed
            nothing. Nothing anywhere checked a schema, and nothing proved the
            hand-written Assert-HDT*Document validators still agreed with one.

            IT IS A TEST HELPER AND NEVER SHIPS. The engine validates with
            Assert-HDT*Document, which is what runs in WinPE; the contract suites
            exist to prove those two agree on every fixture, and this is the side
            of that comparison the schema speaks for.

            IT REFUSES WHAT IT DOES NOT IMPLEMENT. The vocabulary walk runs over
            the whole schema first - every branch, not only the ones this
            document reaches - so a keyword the validator has never heard of
            throws on the commit that adds it. A validator that ignored one would
            be the green skip again in a different costume.

            THE PARSE IS ConvertFrom-Json's, DELIBERATELY, and not
            ConvertFrom-Yaml's even though YAML is a JSON superset and
            powershell-yaml is already a dependency here: YamlDotNet reads the
            JSON number 1.0 as an Int32, which would make `type: number` and
            `type: integer` indistinguishable on exactly the values where the
            difference matters. 5.1's ConvertFrom-Json keeps 1.0 a Decimal, keeps
            an ISO-8601 string a string, and keeps [] an empty array rather than
            collapsing it to $null.

            SCHEMAS ARE CACHED BY THEIR OWN TEXT. A contract suite validates
            dozens of fixtures against one schema, and re-parsing and re-walking
            it each time is the difference between a fast suite and a slow one.

        .PARAMETER Json
            The document, as text.

        .PARAMETER Schema
            The JSON Schema, as text.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Location, Keyword
            and Message. Nothing at all when the document validates.

        .EXAMPLE
            Get-HDTJsonSchemaViolation -Json '{ "id": 1 }' -Schema '{ "properties": { "id": { "type": "string" } } }'

            Reports one violation at '#/id'.

        .EXAMPLE
            Get-HDTJsonSchemaViolation -Json $json -Schema $schema | ForEach-Object { '{0}: {1}' -f $_.Location, $_.Message }

            The form a failing contract puts in its -Because.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Schema
    )

    # Test-Path rather than a $null comparison: Set-StrictMode -Version Latest is
    # in force in HDTTestTools.psm1, and reading a variable that was never
    # assigned throws there rather than returning $null.
    if (-not (Test-Path -Path 'variable:script:HDTJsonSchemaCache')) {
        # A Dictionary and not @{}: a PowerShell hashtable keys case
        # insensitively, and two schemas can differ only in the case of a
        # pattern.
        $script:HDTJsonSchemaCache = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]'
    }

    if (-not $script:HDTJsonSchemaCache.ContainsKey($Schema)) {
        $parsed = $null
        try {
            $parsed = ConvertFrom-Json -InputObject $Schema
        } catch {
            throw ("The schema is not valid JSON: {0}" -f $_.Exception.Message)
        }

        if ($null -eq $parsed) {
            throw 'The schema parsed to nothing. A JSON Schema must be an object or a boolean.'
        }

        # Throws on the first keyword the validator cannot apply, before a single
        # verdict is reached.
        $null = Get-HDTJsonSchemaKeyword -Schema $Schema

        $script:HDTJsonSchemaCache[$Schema] = $parsed
    }

    $root = $script:HDTJsonSchemaCache[$Schema]

    $document = $null
    try {
        $document = ConvertFrom-Json -InputObject $Json
    } catch {
        throw ("The document is not valid JSON: {0}" -f $_.Exception.Message)
    }

    return @(Get-HDTJsonSchemaNodeViolation -Instance $document -Node $root -Root $root -Location '#')
}
