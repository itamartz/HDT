function Get-HDTConsolePropertyLabel {
    <#
        .SYNOPSIS
            The caption a step property wears on the Properties tab.

        .DESCRIPTION
            A YAML KEY IS NOT A LABEL. 'variable' and 'value' are what the
            document calls them, and the tab showed exactly that: two boxes
            labelled in the file's vocabulary rather than the administrator's,
            in a window whose whole job is to spare somebody the file.

            MOST KEYS NEED NOTHING BUT A CAPITAL. 'index' reads as Index and
            'operatingSystem' as Operating system once the camel case is broken
            up, which is the same rule every other label on this window follows.

            THE FEW THAT DO ARE NAMED HERE. 'variable' is the variable's NAME -
            the box beside it holds the variable's value, and two boxes reading
            'Variable' and 'Value' is a distinction nobody should have to infer.

            IT CHANGES NO KEY. The row still writes the property it is named
            after; this is the word on the left of it.

        .PARAMETER Key
            The YAML key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsolePropertyLabel -Key 'operatingSystem'

            Operating system
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Key
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }

    # THE ONES A CAPITAL DOES NOT FIX.
    $named = @{
        'variable' = 'Variable name'
    }

    if ($named.ContainsKey($Key.ToLowerInvariant())) { return [string] $named[$Key.ToLowerInvariant()] }

    # camelCase into words: 'operatingSystem' -> 'operating System'.
    $spaced = [regex]::Replace($Key, '(?<=[a-z0-9])(?=[A-Z])', ' ')

    return $spaced.Substring(0, 1).ToUpperInvariant() + $spaced.Substring(1).ToLowerInvariant()
}
