function Get-HDTValidateStepDescription {
    <#
        .SYNOPSIS
            Describes a Validate step by the bounds it will check.

        .DESCRIPTION
            The optional third of the step contract's triple. A technician watching the
            progress display wants to know which bound a machine failed, so the
            description names them: "Validate: 2048 MB memory, 60 GB disk, UEFI".

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Validate' })[0]

            Get-HDTValidateStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.
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

    $part = New-Object -TypeName System.Collections.ArrayList

    $minimumRamMb = Get-HDTStepProperty -Step $Step -Name 'minRamMB'
    if ($null -ne $minimumRamMb) {
        [void] $part.Add(('{0} MB memory' -f $minimumRamMb))
    }

    $minimumDiskGb = Get-HDTStepProperty -Step $Step -Name 'minDiskGB'
    if ($null -ne $minimumDiskGb) {
        [void] $part.Add(('{0} GB disk' -f $minimumDiskGb))
    }

    $requireUefi = Get-HDTStepProperty -Step $Step -Name 'requireUefi'
    if ($null -ne $requireUefi) {
        [void] $part.Add('UEFI firmware')
    }

    foreach ($name in @(Get-HDTStepProperty -Step $Step -Name 'requireVariable')) {
        $text = ([string] $name).Trim()
        if ($text.Length -gt 0) { [void] $part.Add($text) }
    }

    if ($part.Count -eq 0) {
        return 'Validate: one unambiguous target disk'
    }

    return ('Validate: {0}, and one unambiguous target disk' -f (@($part) -join ', '))
}
