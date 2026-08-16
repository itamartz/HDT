function Get-HDTApplicationDetectKey {
    <#
        .SYNOPSIS
            The keys each application detection rule type may declare, and which
            of them it must.

        .DESCRIPTION
            ONE TABLE, TWO READERS. Assert-HDTApplicationDocument validates a
            detection rule against it and ConvertTo-HDTApplicationCatalog projects
            one from it, so a rule type gains a key in a single place rather than
            in two that have to be kept in step by hand.

            schemas/app.schema.json states the same thing a third time, in the
            language an editor and CI can read. That duplication is deliberate and
            is held honest by tests/contract/AppSchema.Contract.Tests.ps1, which
            makes both gates agree on every fixture.

            The four types are DESIGN 8's, and there is no fifth: a detection rule
            the engine cannot run is refused at authoring time.

        .OUTPUTS
            System.Collections.IDictionary - keyed by detection type, each value a
            hashtable with Required and Optional key lists.

        .EXAMPLE
            (Get-HDTApplicationDetectKey)['registry'].Required
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return ([ordered] @{
            msiProduct = @{ Required = @('productCode'); Optional = @() }
            file       = @{ Required = @('path'); Optional = @('version') }
            registry   = @{ Required = @('key'); Optional = @('value', 'data') }
            script     = @{ Required = @('path'); Optional = @() }
        })
}
