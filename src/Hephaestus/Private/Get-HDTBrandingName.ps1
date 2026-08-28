function Get-HDTBrandingName {
    <#
        .SYNOPSIS
            The name that goes on the deployment banner.

        .DESCRIPTION
            The organisation name a deployment paints on its banner, and the
            reason it is not vanity: a technician at a bench is often looking at
            two toolkits, and the banner is the fastest way to know which one
            has this machine. HDT's banner said 'Hephaestus' on every machine
            ever built from it. MDT carried the same value as _SMSTSOrgName.

            THE DECISION IS PURE AND THE WINDOW IS NOT. Show-HDTWizardShell is
            an adapter no Pester test can open a window against, so what the
            value means - trimmed, and what an unset one falls back to - is
            settled here, where it can be asserted.

            THE FALLBACK IS THE OLD BANNER, deliberately. A share that never
            mentions HDTBrandingName looks exactly as it did, and a value that
            resolved to nothing - a rule that produced an empty string, a wizard
            box a technician cleared - falls back rather than painting a banner
            of three spaces that nobody can read.

        .PARAMETER Value
            What HDTBrandingName resolved to. Empty, null or whitespace all mean
            "nothing was set".

        .OUTPUTS
            System.String.

        .EXAMPLE
            Get-HDTBrandingName -Value $context.Variable['HDTBrandingName']
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $name = ([string] $Value).Trim()

    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'Hephaestus'
    }

    return $name
}
