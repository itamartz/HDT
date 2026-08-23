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
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'InstallApplications' })[0]

            Get-HDTInstallApplicationsStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead, which is what MDT's progress line shows.
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
