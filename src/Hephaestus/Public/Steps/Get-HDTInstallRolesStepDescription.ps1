function Get-HDTInstallRolesStepDescription {
    <#
        .SYNOPSIS
            Describes an InstallRoles step by the features it will install.

        .DESCRIPTION
            The optional third of the step contract's triple. This string goes to
            the progress display and to the master log at Info.

            A LONG LIST IS TRUNCATED. A server build can name a dozen features and
            a progress window has one line; the first three plus a count says what
            is happening without pushing everything else off the screen.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTInstallRolesStepDescription -Step $step
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
    $feature = @()

    if ($null -ne $property -and $property.Contains('features')) {
        $raw = $property['features']

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            $feature = @(@($raw) | ForEach-Object { [string] $_ })
        } elseif (-not [string]::IsNullOrWhiteSpace([string] $raw)) {
            $feature = @([string] $raw)
        }
    }

    if (@($feature).Count -eq 0) {
        return ('InstallRoles: {0}' -f $Step.Name)
    }

    if (@($feature).Count -le 3) {
        return ('InstallRoles: {0}' -f (@($feature) -join ', '))
    }

    return ('InstallRoles: {0} and {1} more' -f ((@($feature)[0..2]) -join ', '), (@($feature).Count - 3))
}
