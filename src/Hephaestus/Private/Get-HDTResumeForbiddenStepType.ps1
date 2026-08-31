function Get-HDTResumeForbiddenStepType {
    <#
        .SYNOPSIS
            The step types a resumed WinPE leg must never run.

        .DESCRIPTION
            ONE LIST, IN ONE PLACE, SO THE TEST CAN WALK IT (CLAUDE.md 8).

            A resumed WinPE leg is the capture half of a reference build: the
            machine has been deployed, customized and generalized, and the only
            thing left to do to it is read its volume into a WIM. Every step
            that would WRITE that volume is therefore a defect if it is reached,
            and the two here are the two that would destroy it outright.

              DiskPartition   formats the disk. The whole reason the WinPE-side
                              resume discovery exists.

              ApplyImage      overwrites the volume the capture is about to
                              read - which on a reference build is the
                              customized installation somebody spent an hour
                              producing. Not a formatted disk, but the same
                              loss, and no more recoverable.

            WHY THIS IS A LIST AND NOT AN `if` IN THE LOOP. A test asserting
            "DiskPartition is refused" passes for DiskPartition and fails
            nobody after it. A test that walks THIS covers the type somebody
            adds next year without knowing this file exists, which is the
            failure mode CLAUDE.md 8 is a list of.

            AND WHY IT REFUSES RATHER THAN SKIPPING. A skip is quieter and lets
            the run go on to capture whatever happens to be on the disk. A
            resumed leg that REACHES one of these has something wrong with it -
            a state document whose stepIndex is lying, most likely - and a step
            failing is how anybody finds out.

            WHAT IS DELIBERATELY NOT HERE. ApplyUnattend, ApplyDrivers and
            Tattoo all write to the OS volume too, and all of them are wrong to
            run on a capture leg - but they are wrong the way a misordered
            sequence is wrong, not the way a format is. They damage an image;
            these two destroy a machine. Refusing them here would turn a
            sequence-authoring mistake into an engine refusal, and the engine
            does not get to overrule an author about steps that are merely
            unwise.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Get-HDTResumeForbiddenStepType

            DiskPartition, ApplyImage.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('DiskPartition', 'ApplyImage')
}
