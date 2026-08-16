function Get-HDTEnableBitLockerStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new EnableBitLocker step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE DEFAULTS ARE WRITTEN OUT RATHER THAN LEFT IMPLICIT, which is the
            opposite of what the other templates do, and deliberately so. Every
            one of these lines is a security decision an administrator should see
            and agree with rather than inherit silently: which volume, how much of
            it, and above all WHERE THE RECOVERY KEY GOES. escrow: ad is written
            in because a key that goes nowhere is the failure mode this step
            exists to prevent - an author who genuinely manages keys another way
            changes it to none and the step warns, which is a decision in a log
            rather than a discovery years later.

            wait: false because encrypting a large disk takes longer than the rest
            of the deployment put together, and nothing after it needs to wait.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTEnableBitLockerStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Enable BitLocker'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: EnableBitLocker'
        "  drive: '%HDTOSVolume%'"
        '  scope: usedSpaceOnly'
        '  method: XtsAes256'
        '  protector: tpm'
        '  recoveryPassword: true'
        '  escrow: ad'
        '  wait: false'
        '  runIn: FullOS'
    )
}
