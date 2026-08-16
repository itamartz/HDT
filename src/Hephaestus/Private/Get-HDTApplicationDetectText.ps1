function Get-HDTApplicationDetectText {
    <#
        .SYNOPSIS
            Renders a detection rule as the app.yaml block that declares it.

        .DESCRIPTION
            THE KEY ORDER COMES FROM Get-HDTApplicationDetectKey, not from the
            hashtable. A hashtable's key order differs between Windows PowerShell
            5.1 and pwsh 7 - the trap ConvertTo-HDTYaml documents - and a rule
            that serialised in a different order on each would make a diff nobody
            can read. 'type' leads, and what follows is the order the shared table
            declares, which is the same order the validator and the projector read
            it in.

            A KEY THE TABLE DOES NOT KNOW IS STILL WRITTEN. Refusing it here would
            put a second copy of the rule schema in this file;
            Assert-HDTApplicationDocument already refuses it, and it names the
            file and the key when it does.

        .PARAMETER Detect
            The rule, as a hashtable in the shape app.yaml declares.

        .PARAMETER Key
            The document key the block hangs off. Always 'detect' today; named
            rather than hard-coded because this function writes it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the block's lines, unindented at the key.

        .EXAMPLE
            Get-HDTApplicationDetectText -Detect @{ type = 'msiProduct'; productCode = '{23170F69}' } -Key 'detect'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Detect,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Key = 'detect'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $type = ''
    if ($Detect.Contains('type')) { $type = [string] $Detect['type'] }

    $ordered = New-Object -TypeName System.Collections.ArrayList
    [void] $ordered.Add('type')

    # .Contains, not .ContainsKey: the shared table is a hashtable, which answers
    # to both, and an ordered dictionary would answer only to the former.
    $schema = Get-HDTApplicationDetectKey
    if ($schema.Contains($type)) {
        foreach ($current in @($schema[$type].Required + $schema[$type].Optional)) {
            if ($Detect.Contains($current)) { [void] $ordered.Add($current) }
        }
    }

    foreach ($current in @($Detect.Keys)) {
        if ($ordered -notcontains [string] $current) { [void] $ordered.Add([string] $current) }
    }

    $text = New-Object -TypeName System.Collections.ArrayList
    [void] $text.Add(('{0}:' -f $Key))

    foreach ($current in $ordered) {
        $value = ''
        if ($Detect.Contains($current)) { $value = [string] $Detect[$current] }

        [void] $text.Add(('  {0}: {1}' -f $current, (Get-HDTConsoleScalarText -Value $value)))
    }

    return [string[]] @($text)
}
