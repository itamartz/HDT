function Invoke-HDTRestartStep {
    <#
        .SYNOPSIS
            Asks the engine to restart the machine before the next step.

        .DESCRIPTION
              - name: Restart into the full OS
                type: Restart
                delaySeconds: 30
                message: restarting to finish setup

            IT DOES NOT REBOOT, AND THAT IS THE DESIGN. The reboot ceremony is

              arm autologon -> save state -> log reboot.arm -> restart

            and a failure between any two of those must leave a machine that can
            still be recovered. That ordering belongs to the
            loop, which owns the state document; a step that rebooted itself
            could not be checkpointed, so the sequence would resume at the wrong
            index or not at all.

            So this step returns RebootRequested, carries the delay in its result
            data for the loop to hand to IPowerService, and touches nothing else -
            not the power service, not the registry, not the LSA.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Its Property may
            carry `delaySeconds` and `message`.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult with Status RebootRequested and Data carrying
            DelaySecond.

        .EXAMPLE
            Invoke-HDTRestartStep -Step $step -Context $context
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    $delaySecond = 0
    if ($null -ne $property -and $property.Contains('delaySeconds')) {
        $delaySecond = [int] $property['delaySeconds']
    }

    $message = 'a restart was requested'
    if ($null -ne $property -and $property.Contains('message') -and
        -not [string]::IsNullOrWhiteSpace([string] $property['message'])) {

        $message = [string] $property['message']
    }

    Write-HDTLog -Context $Context.Log -Message $message -Component 'Restart' `
        -Data ([ordered] @{ delaySecond = $delaySecond })

    return (New-HDTStepResult -Status RebootRequested -Message $message `
            -Data ([pscustomobject] @{ DelaySecond = $delaySecond }))
}
