function Test-HDTStepApplicable {
    <#
        .SYNOPSIS
            Asks a step type whether this step applies to this machine.

        .DESCRIPTION
            The optional half of the step contract's triple. A step type may declare

              Test-HDT<Type>StepApplicable -Step -Context

            to say "there is nothing for me to do here" - a driver step with no
            matching driver group, a BitLocker step on a machine with no TPM -
            without that being a failure. A type that declares no such function
            is always applicable.

            The result is coerced to a boolean, because an applicability function
            written by a third party may return anything truthy.

            AN UNKNOWN TYPE IS APPLICABLE. Applicability is not where an unknown
            type is reported: Invoke-HDTStep owns that error, and reporting it
            from two places would give the loop two different messages for one
            fault.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. The loop calls this once per
            step, so without it every step would pay a Get-Command enumeration.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) `
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step)[0]
            Test-HDTStepApplicable -Step $step -Context $context

            Whether this step applies to this machine at all - its phase, its
            condition, and whatever the step type itself declares.

        .EXAMPLE
            $registry = @(Get-HDTStepType)
            if (-not (Test-HDTStepApplicable -Step $step -Context $context -StepType $registry)) { 'skipped' }

            A step that does not apply is Skipped, and skipped is not failed. The
            difference matters to a sequence that carries a BIOS branch and a
            UEFI one.

    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $StepType
    if ($null -eq $registry) {
        $registry = @(Get-HDTStepType)
    }

    $entry = @($registry | Where-Object { $_.Type -eq [string] $Step.Type })

    if ($entry.Count -eq 0) {
        return $true
    }

    if ($null -eq $entry[0].TestCommand) {
        return $true
    }

    return [bool] (& $entry[0].TestCommand -Step $Step -Context $Context)
}
