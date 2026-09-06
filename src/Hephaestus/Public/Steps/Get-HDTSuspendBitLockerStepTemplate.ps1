function Get-HDTSuspendBitLockerStepTemplate {
    <#
        .SYNOPSIS
            The YAML a new SuspendBitLocker step starts life as.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            IT WRITES runIn: FullOS, AND THAT IS THE ONE LINE IT CANNOT LEAVE
            OUT. You cannot suspend the protectors of a volume from a WinPE that
            has not unlocked it, and by the time WinPE is running the boot that
            needed the suspend has already happened. A step added from the
            console into a WinPE group with no runIn on it would run there,
            fail, and look like a BitLocker fault - so the step declares its own
            phase rather than inheriting the group's.

            IT WRITES rebootCount: 0 EVEN THOUGH 0 IS THE DEFAULT, for
            Get-HDTCleanVolumeStepTemplate's reason: this is a setting whose
            wrong value is invisible until a machine asks for a recovery key two
            reboots later. 0 is "until protection is explicitly resumed"; 1
            would be "until the next boot", and a Refresh boots more than once.

            IT NAMES NO DRIVE. Blank is the volume the run published, and
            failing that the one this Windows is running from - which is what a
            Refresh replaces and what MDT pins the destination to. A letter
            written into a template that ships to every share would be a guess
            at somebody else's machine.

        .PARAMETER Name
            The step's name. Defaults to 'Suspend BitLocker', which says what
            happens to the machine rather than naming the type.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTSuspendBitLockerStepTemplate

            The YAML lines for a new SuspendBitLocker step.

        .EXAMPLE
            $line = Get-HDTSuspendBitLockerStepTemplate -Name 'Suspend BitLocker before the transport is armed'
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
        [string] $Name = 'Suspend BitLocker'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: SuspendBitLocker'
        '  runIn: FullOS'
        '  rebootCount: 0'
    )
}
