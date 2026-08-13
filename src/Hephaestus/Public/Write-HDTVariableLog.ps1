function Write-HDTVariableLog {
    <#
        .SYNOPSIS
            Writes a resolution's provenance into the log stream as var.resolve
            records.

        .DESCRIPTION
            DESIGN 3.1: "the single biggest debugging pain in MDT is not knowing
            why HDTComputerName ended up as it did". Export-HDTVariableProvenance
            answers that from a file; this puts the same answer into the log
            STREAM, one var.resolve record per variable, which is what the report
            renderer and the console's monitoring view read.

            Records are emitted at Debug, because DESIGN 4.4.5 puts variable
            resolution there: "Debug adds every variable resolution with its
            provenance and every native command line executed in full - the two
            things most often needed to explain a deployment that went wrong, and
            the two things MDT makes hardest to get". A context at the default
            Info level therefore drops them, which is intended.

            Each record carries the whole provenance entry under data - name,
            value, source, rule, ruleIndex, file, rawValue, expanded, order - in
            resolution order, so reading the stream top to bottom is reading what
            the engine did in the order it did it.

            AN UNRESOLVED %Var% IS A WARNING, NOT A FAILURE. 02-03 settled that a
            token nothing supplied is surfaced in the log and left in place rather
            than ending the deployment, so one Warning record names every
            unresolved token. It is emitted at Warning, so it survives a
            non-Debug verbosity: this is the one part of provenance an
            administrator needs without turning on Debug first.

        .PARAMETER Context
            A New-HDTLogContext result.

        .PARAMETER Resolution
            A Resolve-HDTVariable result.

        .OUTPUTS
            None.

        .EXAMPLE
            Write-HDTVariableLog -Context $context -Resolution $resolution
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Resolution
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    foreach ($record in @(Get-HDTVariableProvenance -Resolution $Resolution)) {
        $data = [ordered] @{
            name      = $record.Name
            value     = $record.Value
            source    = $record.Source
            rule      = $record.Rule
            ruleIndex = $record.RuleIndex
            file      = $record.File
            rawValue  = $record.RawValue
            expanded  = $record.Expanded
            order     = $record.Order
        }

        Write-HDTLog -Context $Context -Severity Debug -Event 'var.resolve' -Component 'Variable' `
            -Message ("{0} = '{1}' ({2})" -f $record.Name, $record.Value, $record.Source) -Data $data
    }

    $unresolved = @($Resolution.Unresolved)
    if ($unresolved.Count -gt 0) {
        Write-HDTLog -Context $Context -Severity Warning -Event 'var.resolve' -Component 'Variable' `
            -Message ("{0} variable token(s) were never supplied and are left unexpanded: {1}." -f
                $unresolved.Count, ($unresolved -join ', ')) `
            -Data ([ordered] @{ unresolved = $unresolved })
    }
}
