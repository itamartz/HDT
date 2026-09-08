function Resolve-HDTJsonSchemaReference {
    <#
        .SYNOPSIS
            Resolves a JSON Schema $ref against the document that contains it.

        .DESCRIPTION
            Every $ref in schemas/ is an internal JSON pointer - '#/definitions/step'
            and nothing else. This resolves that form and REFUSES everything else
            rather than returning a schema that permits anything: an external
            reference needs a resolver this repository does not have, and a
            pointer at a definition that is not there is a typo in the schema,
            which is precisely the kind of defect these contracts exist to catch.

            Resolution happens per instance rather than by inlining, because
            sequence.schema.json's `group` definition contains groups: inlining
            would not terminate.

        .PARAMETER Root
            The whole schema document, as parsed by ConvertFrom-Json.

        .PARAMETER Reference
            The $ref value.

        .PARAMETER Location
            Where the reference was found, for the error message.

        .OUTPUTS
            The referenced subschema.

        .EXAMPLE
            Resolve-HDTJsonSchemaReference -Root $schema -Reference '#/definitions/step' -Location '#/properties/steps/items'

            Returns the `step` definition.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Reference,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Location
    )

    if (-not $Reference.StartsWith('#/')) {
        $message = "JSON Schema reference '$Reference' at '$Location' is not an internal pointer. Only " +
        "'#/...' is implemented, because every reference in schemas/ is internal and an external one needs a " +
        'resolver this repository does not have. Refusing is deliberate: a reference that cannot be followed ' +
        'would otherwise validate anything underneath it.'
        throw $message
    }

    $node = $Root
    foreach ($token in $Reference.Substring(2).Split('/')) {
        # RFC 6901 escaping. No pointer in schemas/ needs it, and honouring it
        # costs two lines against a silently wrong resolution later.
        $name = $token.Replace('~1', '/').Replace('~0', '~')

        if ($null -eq $node -or -not ($node -is [System.Management.Automation.PSCustomObject]) -or
            $null -eq $node.PSObject.Properties[$name]) {

            throw ("JSON Schema reference '{0}' at '{1}' does not resolve: there is no '{2}' at that point in the document." -f $Reference, $Location, $name)
        }

        $node = $node.PSObject.Properties[$name].Value
    }

    return $node
}
