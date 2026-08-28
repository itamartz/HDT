function Get-HDTVariableProvenance {
    <#
        .SYNOPSIS
            Returns the provenance records of a resolution, optionally filtered by
            variable name.

        .DESCRIPTION
            Every variable resolution records which source set it, and this is
            what makes that record answerable rather than merely logged. Not
            knowing why HDTComputerName ended up as it did is the single biggest
            debugging pain a deployment has, and here it is one query.

            Provenance survives the Resolve-HDTVariable call and can be queried
            afterwards, one variable at a time, which is how the question is
            actually asked in the field.

            Records come back in resolution order, so reading the output top to
            bottom is reading what the engine did, in the order it did it.

            A -Name that matches nothing returns nothing rather than throwing:
            "what set HDTDriverGroup?" has the perfectly good answer "nothing
            did", and that is often exactly the finding.

        .PARAMETER Resolution
            A Resolve-HDTVariable result.

        .PARAMETER Name
            One or more variable names to report on. Wildcards are supported, so
            HDTSkip* answers for a whole family at once. Omit for everything.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per variable:
            Name, Value, Source, Rule, RuleIndex, File, RawValue, Expanded, Order.

        .EXAMPLE
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $result = Resolve-HDTVariable -Fact $fact
            Get-HDTVariableProvenance -Resolution $result |
                Format-Table Order, Name, Value, Source, Rule -AutoSize

            The whole story of a deployment's variables, in one table.

        .EXAMPLE
            Get-HDTVariableProvenance -Resolution $result -Name HDTComputerName

            Why this machine is called what it is called.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Resolution,

        [Parameter(Position = 1)]
        [AllowNull()]
        [string[]] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $record = @($Resolution.Provenance.Values) | Sort-Object -Property Order

    if ($null -eq $Name -or @($Name).Count -eq 0) {
        return $record
    }

    $selected = New-Object -TypeName System.Collections.ArrayList

    foreach ($item in @($record)) {
        foreach ($pattern in @($Name)) {
            if (($item.Name -like $pattern) -and -not $selected.Contains($item)) {
                [void] $selected.Add($item)
            }
        }
    }

    return @($selected)
}
