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
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Restart' })[0]

            Invoke-HDTRestartStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTRestartStep -Step $step -Context $context
            $result.Restart

            True - the step does not restart anything itself. It tells the engine to,
            which is what makes the sequence resumable across the reboot.
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

    # READ THE WAY EVERY OTHER STEP TYPE READS. `message` is the sentence a
    # technician watches the machine go down on, so it is the last place a
    # literal '%HDTComputerName%' should survive to - and reading it raw is
    # exactly what left it there.
    $delaySecond = Get-HDTStepProperty -Step $Step -Name 'delaySeconds' -Default 0 `
        -Context $Context -Expand -As Int

    $message = Get-HDTStepProperty -Step $Step -Name 'message' -Default 'a restart was requested' `
        -Context $Context -Expand -As String

    Write-HDTLog -Context $Context.Log -Message $message -Component 'Restart' `
        -Data ([ordered] @{ delaySecond = $delaySecond })

    return (New-HDTStepResult -Status RebootRequested -Message $message `
            -Data ([pscustomobject] @{ DelaySecond = $delaySecond }))
}
