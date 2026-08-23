function Get-HDTGatherStepDescription {
    <#
        .SYNOPSIS
            One line describing a Gather step, for the console's tree.

        .DESCRIPTION
            The third of the step contract: what this step will do, in a
            sentence, without running it. See Get-HDTNoOpStepDescription for the
            shape all of them share.

            THE SENTENCE DOES NOT VARY, because the step takes no properties.
            What it says instead is WHY it is worth having twice in a sequence,
            since that is the only question this step raises.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Gather' })[0]

            Get-HDTGatherStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead, which is what MDT's progress line shows.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Step',
        Justification = 'The step contract requires -Step on every step command. A Gather step declares no properties - what to gather is not a choice - so the parameter is bound and unread, which is the contract being honoured rather than an oversight.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return 'Re-reads the machine facts - make, model, memory, firmware, TPM, network - into the sequence variables. Worth running again after the disk is laid out or the OS applied, because those change what the machine reports.'
}
