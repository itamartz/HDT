function Get-HDTConsoleJsonProperty {
    <#
        .SYNOPSIS
            Reads one property out of a parsed JSON object, answering a default
            when it is absent.

        .DESCRIPTION
            THE BOOT IMAGE MANIFEST IS NOT A SCHEMA-VALIDATED DOCUMENT the way
            the workspace YAML is: it is written by Update-HDTBootImage, it has
            grown keys between phases (artifacts.isoBootWimSha256 arrived in
            05-04), and the console has to read manifests written by older
            builds without falling over.

            Under Set-StrictMode -Version Latest, reading a property that
            ConvertFrom-Json did not create throws PropertyNotFoundException -
            so a console that reads the manifest field by field would refuse to
            open a share whose image was built one phase ago. This is the reader
            that turns "the key is not there" into a default instead, and it is
            the only place that decision is made.

            The lookup goes through PSObject.Properties rather than a dotted
            access, because that is the form that does not throw.

        .PARAMETER InputObject
            The parsed JSON object, or $null.

        .PARAMETER Name
            The property to read.

        .PARAMETER Default
            What to answer when the property is absent, is $null, or the object
            itself is $null. Defaults to an empty string.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Object

        .EXAMPLE
            Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'builtOn'

        .EXAMPLE
            $artifact = Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'artifacts' -Default $null

            The nested case: absent, and the caller gets $null rather than an
            exception three frames down.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [object] $Default = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $InputObject) {
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}
