function Get-HDTInstallApplicationsStepDescription {
    <#
        .SYNOPSIS
            Describes an InstallApplications step by what it will install.

        .DESCRIPTION
            The optional third of the step contract's triple. This string goes to
            the progress display and to the master log at Info.

            A FIXED LIST IS NAMED; A TOKEN IS NOT RESOLVED. The description is
            built from the step as authored, with no context to expand
            '%HDTApplications%' against - so a selection that is a token is
            reported as the variable it will read rather than as a guess at what
            that variable will hold. The step logs the resolved plan itself, once
            it has one.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTInstallApplicationsStepDescription -Step $step
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    if ($null -ne $property -and $property.Contains('selection')) {
        $selection = $property['selection']

        if ($selection -is [System.Collections.IList] -and -not ($selection -is [string])) {
            $name = @(@($selection) | ForEach-Object { [string] $_ })

            if ($name.Count -gt 0) {
                return ('InstallApplications: {0}' -f ($name -join ', '))
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string] $selection)) {
            return ('InstallApplications: {0}' -f [string] $selection)
        }
    }

    return 'InstallApplications: %HDTApplications%'
}
