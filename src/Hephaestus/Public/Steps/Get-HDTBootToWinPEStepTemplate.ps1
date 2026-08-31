function Get-HDTBootToWinPEStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new BootToWinPE step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            runIn: FullOS IS WRITTEN OUT AND IS NOT OPTIONAL for the two actions
            an author adds by hand. Staging reads the share and the running
            Windows' own boot.sdi, and arming edits the boot store this machine
            booted through - neither of which exists in WinPE the way this step
            needs them. The teardown is the exception and runs in WinPE, which is
            why the action is a property rather than three step types.

            action: stage IS THE DEFAULT BECAUSE IT IS THE HARMLESS ONE. A step
            added to a sequence and then left alone copies two files onto the
            local disk and changes nothing about how the machine boots; the same
            step defaulted to arm would point the next boot somewhere before
            anybody had put anything there.

            bootImage: IS NOT WRITTEN OUT. HDTPE_x64 is the workspace convention
            and the overwhelming majority of shares have exactly one boot image,
            so the key would be a setting that looks like a decision.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTBootToWinPEStepTemplate

            The YAML lines for a new BootToWinPE step, named after its type.

        .EXAMPLE
            $line = Get-HDTBootToWinPEStepTemplate -Name 'Stage WinPE for the capture'
            $line -join [System.Environment]::NewLine

            The same lines under a name of your own. They are lines, not a
            document: Add-HDTStep splices them into a sequence.yaml so the
            comments and the order of everything already in it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Boot into WinPE'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: BootToWinPE'
        '  runIn: FullOS'
        '  action: stage'
    )
}
