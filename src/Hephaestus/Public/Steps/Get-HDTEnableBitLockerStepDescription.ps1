function Get-HDTEnableBitLockerStepDescription {
    <#
        .SYNOPSIS
            Describes an EnableBitLocker step by the volume and the scope.

        .DESCRIPTION
            The optional third of the step contract's triple. This string goes to
            the progress display and to the master log at Info.

            IT NAMES THE SCOPE, because that is the number a technician watching a
            progress window cares about: usedSpaceOnly finishes in minutes and
            full can take hours on a large disk, and knowing which one is running
            is the difference between waiting and investigating.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTEnableBitLockerStepDescription -Step $step
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

    $drive = '%HDTOSVolume%'
    if ($null -ne $property -and $property.Contains('drive') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['drive'])) {

        $drive = [string] $property['drive']
    }

    $scope = 'usedSpaceOnly'
    if ($null -ne $property -and $property.Contains('scope') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['scope'])) {

        $scope = [string] $property['scope']
    }

    return ('EnableBitLocker: {0} ({1})' -f $drive, $scope)
}
