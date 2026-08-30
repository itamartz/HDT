function Get-HDTSysprepStepDescription {
    <#
        .SYNOPSIS
            Describes a Sysprep step by whether it answers Setup from a file.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the step a
            technician watches in silence for several minutes at the end of a
            reference build, so the line says what is happening to the machine -
            it is being generalized, not merely "sysprepped" - and names the
            answer file when one is in play, because a wrong one is the
            commonest reason a generalize refuses.

            IT NAMES THE FILE AND NOT ITS CONTENTS. A sysprep answer file
            routinely carries a product key.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REF-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Sysprep' })[0]

            Get-HDTSysprepStepDescription -Step $step

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

    $unattend = [string] (Get-HDTStepProperty -Step $Step -Name 'unattend' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($unattend)) {
        return ('Sysprep: generalize this machine, answering Setup from {0}' -f $unattend)
    }

    return 'Sysprep: generalize this machine and seal it for OOBE'
}
