function Get-HDTConfigureBootStepDescription {
    <#
        .SYNOPSIS
            Describes a ConfigureBoot step by the firmware it will write boot
            files for.

        .DESCRIPTION
            The optional third of the step contract's triple. It names the firmware
            because that is the field failure this step has: BIOS boot files on a
            UEFI machine produce a disk that does not boot, and the message a
            technician needs is which one HDT thought it was building.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ConfigureBoot' })[0]

            Get-HDTConfigureBootStepDescription -Step $step

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

    $firmware = [string] (Get-HDTStepProperty -Step $Step -Name 'firmware' -Default 'auto')

    if ($firmware -eq 'auto') {
        return 'Boot: write the boot files for this machine''s firmware, and boot the disk first'
    }

    return ('Boot: write the {0} boot files, and boot the disk first' -f $firmware)
}
