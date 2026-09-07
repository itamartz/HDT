function Get-HDTResumePermittedStepType {
    <#
        .SYNOPSIS
            The forbidden step types a given deployment type unlocks on a
            resumed leg - today, ApplyImage on a REFRESH, and nothing else.

        .DESCRIPTION
            THE ONE HOLE IN Get-HDTResumeForbiddenStepType, AND IT IS A TABLE SO
            THE TEST CAN WALK IT (CLAUDE.md 8).

            A CAPTURE SURVIVES THE GUARD BY NEVER BEING VISITED. Its ApplyImage
            sits BEHIND the resume point and the loop starts at
            state.stepIndex, so the step is not reached at all. A REFRESH runs
            the other way round: the machine boots into the WinPE it staged onto
            its own disk and only THEN applies the image, so its ApplyImage sits
            AHEAD of the resume point. The guard as written refuses the one step
            the leg exists to run, and the Refresh cannot happen (DESIGN 3.2).

            SO THE EXCEPTION IS ApplyImage, ON A REFRESH, AND NOTHING ELSE.

            AND WHAT IT COSTS, SAID PLAINLY, BECAUSE IT IS NOT FREE.

            The guard's whole design is to DISBELIEVE state.json - that is why
            Invoke-HDTTaskSequence runs it AHEAD of the already-completed check,
            so a stepIndex that has come back wrong cannot launder itself by
            claiming the step is already done. This exception necessarily keys on
            a value that lives in that same state.json, beside that same
            stepIndex. A forged or corrupted document that says
            deploymentType: REFRESH therefore buys back a narrower version of
            exactly the hole the guard's ordering was chosen to close.

            THERE IS NO BETTER SIGNAL, AND THAT IS THE HONEST REASON RATHER THAN
            AN EXCUSE. After the reboot the machine cannot tell you what the run
            was for. Its SystemDrive says X: on a Refresh's second leg exactly as
            it does on a bare-metal first leg; the disk it is standing on carries
            a Windows installation in both cases - one about to be replaced, one
            being captured. The evidence that distinguishes them was on the leg
            BEFORE this one, and the only thing that crosses a reboot is the
            state document. DESIGN 3.2 reaches for "the type the engine derived
            at the start of the leg", and on a resumed leg that value IS the
            carried one - there is nothing else it could be.

            WHAT STILL HOLDS, AND IT IS THE PART WORTH THE TRADE. DiskPartition
            is in the forbidden set and this table never names it, for any
            deployment type. MDT gates all partition work on
            `DeploymentType equals NEWCOMPUTER` (Client.xml:131, mirrored
            Server.xml:115) and a Refresh reuses the partition Windows was
            booting from - repartitioning would destroy the staged WinPE the leg
            is running from. So the worst a forged state document can buy is an
            image apply on a machine, not a repartitioned disk: the loss is
            recoverable from the deployment share, and the partition table, the
            other volumes and the staged transport all survive it.

            AN UNKNOWN OR ABSENT DEPLOYMENT TYPE UNLOCKS NOTHING. A document
            written by an engine older than the deploymentType field says
            nothing about what its run is, and the safe reading of "I do not
            know" is the one that grants no permission. So an older document
            loses a permission rather than gaining one.

        .PARAMETER DeploymentType
            NEWCOMPUTER or REFRESH, as the run's own state document records it.
            Empty and unknown are accepted and answer nothing, because a state
            document is exactly the thing this must not assume is well-formed.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Get-HDTResumePermittedStepType -DeploymentType REFRESH

            ApplyImage - the step a Refresh's resumed leg exists to run.

        .EXAMPLE
            Get-HDTResumePermittedStepType -DeploymentType NEWCOMPUTER

            Nothing. A bare-metal run's resumed leg is a capture leg, and every
            forbidden type stays forbidden on it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DeploymentType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($DeploymentType)) { return [string[]] @() }

    # ORDERED AND CASE-INSENSITIVE, because the key comes out of a JSON document
    # a previous leg wrote and a technician may have looked at.
    $permission = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $permission['REFRESH'] = [string[]] @('ApplyImage')

    if (-not $permission.Contains($DeploymentType)) { return [string[]] @() }

    return [string[]] @($permission[$DeploymentType])
}
