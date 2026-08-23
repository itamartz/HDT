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
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'EnableBitLocker' })[0]

            Get-HDTEnableBitLockerStepDescription -Step $step

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
