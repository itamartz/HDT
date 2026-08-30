function Test-HDTAutoLogonNeeded {
    <#
        .SYNOPSIS
            Whether a restart at this point has to arm an autologon, which is
            true only when something after it runs in the full OS.

        .DESCRIPTION
            AN AUTOLOGON EXISTS TO GET A FULL-OS LEG RUNNING AGAIN. HDT's resume
            model is MDT's: the machine reboots, Winlogon signs the local
            Administrator in from an LSA secret, and RunOnce\HDTResume starts the
            engine back up (DESIGN 4.5.2). Every part of that is about a leg that
            resumes INSIDE WINDOWS.

            A LEG THAT RESUMES IN WinPE NEEDS NONE OF IT. It is started by the
            boot media, which is running before there is any session to log on
            to. Arming Winlogon for it would be arming the DEPLOYED machine to
            sign itself in - and, in the one sequence that does this, arming it
            on the machine a moment before that machine is captured into an image
            every future machine is built from.

            WHICH IS WHY THIS EXISTS RATHER THAN BEING ASSUMED. DESIGN 9.3's
            reference build ends:

                Sysprep      (FullOS)   - generalize, and clear the autologon
                Restart      (FullOS)   - into the boot media
                CaptureImage (WinPE)    - read the volume into a WIM

            Invoke-HDTSysprepStep clears Winlogon's values and the LSA secret
            deliberately, because an image that kept them would log itself in and
            re-enter a finished deployment on every machine ever built from it.
            The restart on the next line then asked for the secret sysprep had
            just removed, could not find it, and failed the run at step 11 of 12
            - on a machine that had already been generalized and so could not be
            picked up where it left off. Watched end to end on 2026-08-31, and
            the reason both the pre-flight refusal and the arming itself now ask
            this question first.

            THE ANSWER IS ABOUT THE STEPS AFTER IT AND NOTHING ELSE. Not the
            current phase - a FullOS leg is exactly where the reference build's
            last restart happens. Not the step's own runIn - that says where the
            RESTART runs, not where the machine lands. The steps still to come
            are the only thing that says whether anybody will need a session.

            A STEP WITH NO runIn RUNS IN EITHER PHASE, so it may run in the full
            OS and therefore counts as needing one. The default is the cautious
            answer on purpose: arming an autologon nothing uses costs a registry
            write that Clear-HDTAutoLogon undoes, while failing to arm one that
            IS needed strands the machine at a logon screen with nothing in any
            log to explain it. Between a loop and a stop, choose the stop
            (DESIGN 4.5.2).

        .PARAMETER Step
            The flattened step list the sequence is executing - the same
            $stepList the loop indexes, in order.

        .PARAMETER AfterIndex
            The ONE-BASED index of the restart step being considered. Only steps
            after it are examined; the restart itself never needs a logon armed
            for its own sake.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean. True when any later step could run in the full OS.

        .EXAMPLE
            Test-HDTAutoLogonNeeded -Step $stepList -AfterIndex $index

            What the engine asks before refusing a restart for want of
            HDTAdminPassword, and again before arming Winlogon.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REF-BUILD\sequence.yaml'
            $restartAt = 11
            Test-HDTAutoLogonNeeded -Step @($sequence.Step) -AfterIndex $restartAt

            False, for the reference build: step 12 is the capture and it runs in
            WinPE.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Step,

        [Parameter(Mandatory = $true)]
        [int] $AfterIndex
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NOTHING AFTER IT IS NOTHING TO LOG ON FOR. A restart that ends the sequence
    # has no next leg at all, so there is no session for anybody to come back to.
    if ($null -eq $Step) { return $false }

    $list = @($Step)

    for ($ahead = $AfterIndex; $ahead -lt $list.Count; $ahead++) {
        $candidate = $list[$ahead]

        if ($null -eq $candidate) { continue }

        # PROPERTY-EXISTENCE CHECKED, NOT ASSUMED. StrictMode makes reading an
        # absent property a terminating error, and this walks whatever the
        # document produced.
        $runIn = ''
        if ($null -ne $candidate.PSObject.Properties['RunIn']) {
            $runIn = [string] $candidate.RunIn
        }

        # EITHER, WHICH INCLUDES BLANK. A step that names no phase runs in
        # whichever one reaches it, so it may be the full OS.
        if ([string]::IsNullOrWhiteSpace($runIn) -or $runIn -eq 'Any') { return $true }

        if ($runIn -eq 'FullOS') { return $true }
    }

    return $false
}
