function Get-HDTDeploymentType {
    <#
        .SYNOPSIS
            What a run started on a given leg IS - NEWCOMPUTER or REFRESH.

        .DESCRIPTION
            THE MAPPING, IN ONE PLACE, BECAUSE TWO THINGS NEED IT AND THEY MUST
            NOT DISAGREE.

            Get-HDTMachineFact publishes HDTDeploymentType into the variable bag;
            New-HDTRunState stamps the same answer onto the state document, which
            is what carries it across the reboot. If each carried its own copy of
            the mapping, one run could be a REFRESH in its log and a NEWCOMPUTER
            in its checkpoint - and the resume guard reads the checkpoint
            (DESIGN 3.2).

            STARTED IN WinPE, IT IS A NEWCOMPUTER; STARTED IN THE FULL OS, IT IS
            A REFRESH. MDT decides it on the same evidence in the same place -
            LiteTouch.wsf:373-387 tests oEnv("SystemDrive") = "X:" and writes
            NEWCOMPUTER when the drive is the RAM disk, REFRESH when it is not.
            HDT reads the drive in Get-HDTDeploymentPhase and maps the answer
            here, which is the same decision split across the two questions it
            actually answers: which leg is this, and what is this run.

            IT IS ABOUT THE RUN, NOT ABOUT THE LEG, AND THAT IS WHY THIS IS
            CALLED ONCE. The phase is re-derived on every leg, correctly - it
            decides where this leg's log goes and which steps it may run. The
            deployment type is decided on the run's FIRST leg and carried from
            there: a Refresh starts in the full OS and its second leg runs in
            WinPE, so a leg that re-derived would call the same run a
            NEWCOMPUTER halfway through. MDT does not re-derive either; it fills
            the value in only when nothing has set it yet.

            NO 'else' AND NO DEFAULT, for the reason Get-HDTMachineFact's copy
            of this carried before it moved here: the ValidateSet is the whole
            set of legs, so a third one added there without a branch here
            publishes an empty deployment type, and a test that walks the
            ValidateSet fails the day it lands rather than the day somebody is
            debugging a rule that never matched.

        .PARAMETER Phase
            The leg the run STARTED on: WinPE or FullOS.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTDeploymentType -Phase WinPE

            NEWCOMPUTER - a bare-metal build, started from boot media.

        .EXAMPLE
            Get-HDTDeploymentType -Phase FullOS

            REFRESH - the same wipe-and-load, launched from the running Windows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Phase -eq 'WinPE') { return 'NEWCOMPUTER' }

    return 'REFRESH'
}
