function Get-HDTJsonSchemaKeyword {
    <#
        .SYNOPSIS
            Every keyword a JSON Schema document uses, refusing any this
            repository's validator does not implement.

        .DESCRIPTION
            THE ANTI-VACUITY GUARD. Get-HDTJsonSchemaViolation runs this over the
            whole schema before it validates anything, so a keyword the validator
            has never heard of fails the run that introduced it rather than being
            quietly ignored for three months. Ignoring one is how a validator
            reports green having checked nothing - the same defect as the
            `-Skip:(-not (Get-Command Test-Json))` this replaced, wearing a
            different hat.

            IT WALKS THE SCHEMA, NOT AN INSTANCE. A keyword under a branch no
            fixture happens to reach would never be visited by a validation run,
            and that is exactly where an unknown one hides.

            EVERY REFERENCE IS RESOLVED HERE TOO. A $ref pointing at a definition
            that does not exist, or at another document, cannot be honoured, and
            a validator that shrugged at one would accept anything underneath it.

        .PARAMETER Schema
            The JSON Schema document, as text.

        .OUTPUTS
            System.String[] - the distinct keywords, sorted.

        .EXAMPLE
            Get-HDTJsonSchemaKeyword -Schema (Get-Content ./schemas/app.schema.json -Raw)

            Lists the keywords app.schema.json uses, or throws naming the first
            one the validator cannot apply.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Schema
    )

    $root = ConvertFrom-Json -InputObject $Schema
    $vocabulary = Get-HDTJsonSchemaVocabulary

    $found = @{}
    $pending = New-Object -TypeName System.Collections.ArrayList
    [void] $pending.Add([pscustomobject] @{ Node = $root; Location = '#' })

    # Iterative rather than recursive, and references are RESOLVED but never
    # followed: sequence.schema.json's group definition contains groups, so a
    # walker that traversed a reference would not terminate. Every definition is
    # still reached, because `definitions` is a SchemaMap and the walk visits all
    # of its members.
    while ($pending.Count -gt 0) {
        $current = $pending[0]
        $pending.RemoveAt(0)

        $node = $current.Node
        $location = $current.Location

        # draft-07 allows `true` and `false` as whole schemas.
        if ($node -is [bool]) { continue }

        if ($null -eq $node -or -not ($node -is [System.Management.Automation.PSCustomObject])) {
            throw ("JSON Schema at '{0}' is neither an object nor a boolean, so it is not a schema." -f $location)
        }

        foreach ($property in $node.PSObject.Properties) {
            $keyword = $property.Name

            if (-not $vocabulary.ContainsKey($keyword)) {
                $message = "JSON Schema keyword '$keyword' at '$location' is not implemented by " +
                'Get-HDTJsonSchemaNodeViolation. Add it to Get-HDTJsonSchemaVocabulary and to the validator, ' +
                'with a case in tests/unit/JsonSchemaValidator.Tests.ps1 that fails without it. Refusing to ' +
                'validate is deliberate: a keyword silently ignored is a contract suite reporting green ' +
                'having checked nothing.'
                throw $message
            }

            $found[$keyword] = $true
            $value = $property.Value

            switch ($vocabulary[$keyword]) {
                'Ignore' { }
                'Assertion' { }

                'Reference' {
                    $null = Resolve-HDTJsonSchemaReference -Root $root -Reference ([string] $value) -Location $location
                }

                'Schema' {
                    if ($keyword -eq 'items' -and ($value -is [array])) {
                        $message = "JSON Schema keyword 'items' at '$location' is an array (draft-07 tuple " +
                        'validation), which is not implemented. No schema in schemas/ uses it; implement it in ' +
                        'Get-HDTJsonSchemaNodeViolation before a schema does.'
                        throw $message
                    }

                    [void] $pending.Add([pscustomobject] @{ Node = $value; Location = ('{0}/{1}' -f $location, $keyword) })
                }

                'SchemaMap' {
                    if ($null -eq $value -or -not ($value -is [System.Management.Automation.PSCustomObject])) {
                        throw ("JSON Schema keyword '{0}' at '{1}' must be an object of subschemas." -f $keyword, $location)
                    }

                    foreach ($member in $value.PSObject.Properties) {
                        [void] $pending.Add([pscustomobject] @{
                                Node     = $member.Value
                                Location = ('{0}/{1}/{2}' -f $location, $keyword, $member.Name)
                            })
                    }
                }

                'SchemaList' {
                    if (-not ($value -is [array])) {
                        throw ("JSON Schema keyword '{0}' at '{1}' must be an array of subschemas." -f $keyword, $location)
                    }

                    $index = 0
                    foreach ($member in $value) {
                        [void] $pending.Add([pscustomobject] @{
                                Node     = $member
                                Location = ('{0}/{1}/{2}' -f $location, $keyword, $index)
                            })
                        $index = $index + 1
                    }
                }

                default {
                    throw ("Get-HDTJsonSchemaVocabulary classifies '{0}' as '{1}', which this walker does not handle." -f $keyword, $vocabulary[$keyword])
                }
            }
        }
    }

    return @($found.Keys | Sort-Object)
}
