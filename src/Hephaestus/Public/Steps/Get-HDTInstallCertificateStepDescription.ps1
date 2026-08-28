function Get-HDTInstallCertificateStepDescription {
    <#
        .SYNOPSIS
            One line describing an InstallCertificate step, for the console.

        .DESCRIPTION
            The third of the step contract: what this step will do, in a
            sentence, without running it. See Get-HDTNoOpStepDescription for the
            shape all of them share.

            IT NAMES THE VOLUME WHEN THE STEP DOES, because that is the only
            thing about this step an author can get wrong from the tree.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'InstallCertificate' })[0]

            Get-HDTInstallCertificateStepDescription -Step $step

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

    $target = ''
    if ($null -ne $Step.Property -and $Step.Property.Contains('target')) {
        $target = [string] $Step.Property['target']
    }

    if ([string]::IsNullOrWhiteSpace($target)) { $target = '%HDTOSVolume%' }

    return ("Stages the boot image's certificates on {0} and imports them on the first boot, before anybody logs on - so the deployed machine can authenticate to the same network WinPE did." -f $target)
}
