function New-HDTStepResult {
    <#
        .SYNOPSIS
            Builds the one result shape every step type returns.

        .DESCRIPTION
            Every step type has the same Test-Applicable /
            Invoke-Step / Get-StepDescription shape. This is the other half of
            that contract: whatever a step did, it says so in the same four
            properties, and the loop (03-04) branches on Status and nothing else.

              Status    Completed | Failed | RebootRequested
              ExitCode  the native exit code where there was one, else 0
              Message   the sentence a technician reads in the log
              Data      step-specific detail, carried into the JSONL record's
                        data field rather than polluting the top level

            THE STATUS SET IS CLOSED AT THREE NAMES, enforced by ValidateSet. A
            fourth would be treated by the loop as neither success nor failure.

            REBOOTREQUESTED DOES NOT MEAN THE STEP REBOOTED. The reboot ceremony
            is arm autologon -> save state -> log reboot.arm -> restart, and a
            failure between any two of those must leave a machine that can still
            be recovered. That ordering belongs to the loop, which owns the state
            document; a step that rebooted itself could not be checkpointed.

        .PARAMETER Status
            Completed, Failed or RebootRequested.

        .PARAMETER ExitCode
            The native exit code. Defaults to 0.

        .PARAMETER Message
            The message. Defaults to an empty string.

        .PARAMETER Data
            Step-specific detail. Defaults to $null.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Status, ExitCode,
            Message and Data.

        .EXAMPLE
            New-HDTStepResult -Status Completed -Message 'Applied index 1 to W:\'

        .EXAMPLE
            New-HDTStepResult -Status Failed -ExitCode 87 -Message 'dism reported 87'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Completed', 'Failed', 'RebootRequested')]
        [string] $Status,

        [Parameter()]
        [int] $ExitCode = 0,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Message = '',

        [Parameter()]
        [AllowNull()]
        [object] $Data = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        Status   = $Status
        ExitCode = $ExitCode
        Message  = $Message
        Data     = $Data
    }
}
