function Get-HDTConsoleDetectRuleText {
    <#
        .SYNOPSIS
            A detection rule as the lines an administrator types into the
            console's Detection box.

        .DESCRIPTION
            THE BOX HOLDS THE DOCUMENT'S OWN BLOCK, minus the key it hangs off.
            app.yaml writes

                detect:
                  type: msiProduct
                  productCode: '{23170F69}'

            and the box shows the two lines under it, unindented - because what
            is typed back goes through the same YAML parser, and a block indented
            under nothing is not a block.

            THE ORDER IS Get-HDTApplicationDetectText'S, not a hashtable's. A
            hashtable enumerates in a different order on 5.1 and 7, so rendering
            the rule here would make the box read differently on the two engines
            for the same document. This calls the one function that already
            settles the order, and takes the indentation off.

            AN APPLICATION WITH NO RULE GETS AN EMPTY STRING, not the sentence
            Get-HDTConsoleDetectionText writes. That sentence is for reading; in
            a box that writes app.yaml it would become the rule.

            THE KEYS GO BACK TO camelCase. ConvertTo-HDTApplicationCatalog hands
            out a projection with PascalCase properties - Type, ProductCode -
            because that is how the engine reads a rule off an object, while the
            document is authored in camelCase like every other HDT file. YAML
            keys are case-sensitive, so a box showing 'Type:' would write a
            document the validator refuses.

            AND A KEY THE RULE NEVER DECLARED IS NOT SHOWN. That same projection
            fills every optional key in, empty where the file left it out, so a
            step can read a stable shape under StrictMode. A box is not a step:
            "version: ''" in it becomes an empty version in app.yaml the moment
            somebody tabs away.

        .PARAMETER Detect
            The rule, or $null for an application that declares none.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleDetectRuleText -Detect $application.Detect
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Detect
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Detect) { return '' }

    $rule = $Detect

    if (-not ($rule -is [System.Collections.IDictionary])) {
        $copy = [ordered] @{}
        foreach ($property in @($rule.PSObject.Properties)) { $copy[$property.Name] = $property.Value }
        $rule = $copy
    }

    $declared = [ordered] @{}

    foreach ($key in @($rule.Keys)) {
        $value = [string] $rule[$key]
        if ([string]::IsNullOrEmpty($value)) { continue }

        $name = [string] $key
        $declared[($name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1))] = $value
    }

    if ($declared.Count -eq 0) { return '' }

    $rule = $declared

    # The first line is 'detect:' and the rest are indented under it; the box
    # wants the rest, at the margin.
    $line = @(Get-HDTApplicationDetectText -Detect $rule -Key 'detect')

    $body = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $line[1..($line.Count - 1)]) {
        [void] $body.Add(([string] $current).Trim())
    }

    return ($body -join [System.Environment]::NewLine)
}
