function Get-HDTJsonSchemaVocabulary {
    <#
        .SYNOPSIS
            The JSON Schema draft-07 keywords the HDT schema contracts implement,
            and what kind of thing each one's value is.

        .DESCRIPTION
            ONE PLACE OF TRUTH FOR "DO WE UNDERSTAND THIS KEYWORD". Two callers
            read this table and they must not disagree:
            Get-HDTJsonSchemaKeyword walks a schema document and refuses one it
            does not recognise, and Get-HDTJsonSchemaNodeViolation applies it to
            an instance. A keyword listed here and not implemented there would be
            silently ignored, which is the whole failure this replaced.

            WHY A SUBSET AND NOT ALL OF DRAFT-07. Test-Json is PowerShell 6+, and
            HDT's gate is Windows PowerShell 5.1 because that is the edition
            WinPE ships. Twelve contract suites therefore skipped whole on the
            only run that gates a merge. This is the subset schemas/*.schema.json
            actually uses - every keyword in all thirteen files, and nothing
            speculative. Anything else THROWS rather than validating vacuously,
            so the commit that adds `if`/`then`/`else` to a schema is the commit
            that goes red.

            The kinds, and what each means for a walker:

              Ignore       an annotation. Says nothing about validity, and its
                           value is not a schema.
              Assertion    a scalar or a list of scalars the validator compares
                           the instance against.
              Reference    a JSON pointer to another schema in the same document.
              Schema       the value is one subschema.
              SchemaMap    the value is an object whose VALUES are subschemas
                           and whose keys are names, not keywords.
              SchemaList   the value is an array of subschemas.

            additionalProperties is a Schema because draft-07 allows either a
            boolean or a subschema there, and both are handled where it is used.

        .OUTPUTS
            System.Collections.Hashtable - keyword name to kind.

        .EXAMPLE
            (Get-HDTJsonSchemaVocabulary)['oneOf']

            Returns 'SchemaList'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        # Annotations. Present in every shipped schema and irrelevant to a verdict.
        '$schema'             = 'Ignore'
        '$id'                 = 'Ignore'
        'title'               = 'Ignore'
        'description'         = 'Ignore'
        'default'             = 'Ignore'

        # Assertions.
        'type'                = 'Assertion'
        'enum'                = 'Assertion'
        'const'               = 'Assertion'
        'required'            = 'Assertion'
        'minLength'           = 'Assertion'
        'pattern'             = 'Assertion'
        'minimum'             = 'Assertion'
        'maximum'             = 'Assertion'
        'minItems'            = 'Assertion'
        'uniqueItems'         = 'Assertion'
        'minProperties'       = 'Assertion'

        # Applicators.
        '$ref'                = 'Reference'
        'items'               = 'Schema'
        'propertyNames'       = 'Schema'
        'not'                 = 'Schema'
        'additionalProperties' = 'Schema'
        'properties'          = 'SchemaMap'
        'definitions'         = 'SchemaMap'
        'oneOf'               = 'SchemaList'
    }
}
