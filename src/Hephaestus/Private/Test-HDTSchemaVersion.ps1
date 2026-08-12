function Test-HDTSchemaVersion {
    <#
        .SYNOPSIS
            Tests whether a workspace schemaVersion is one this engine understands.

        .DESCRIPTION
            Workspace content carries a schemaVersion. The module refuses to operate
            on a workspace newer than it understands (DESIGN 12.3); older workspaces
            are readable and are upgraded separately.

            Returns $true when SchemaVersion is less than or equal to Supported.
            Throws when SchemaVersion is below 1, because that is a malformed
            document rather than a version the engine merely does not know yet.

        .PARAMETER SchemaVersion
            The schemaVersion declared by the workspace document under inspection.

        .PARAMETER Supported
            The highest schemaVersion this engine understands.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTSchemaVersion -SchemaVersion 1 -Supported 2

            Returns $true - an older document is readable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [int] $SchemaVersion,

        [Parameter(Mandatory = $true, Position = 1)]
        [int] $Supported
    )

    if ($SchemaVersion -lt 1) {
        throw "Unsupported schemaVersion '$SchemaVersion': schemaVersion must be 1 or greater."
    }

    return ($SchemaVersion -le $Supported)
}
