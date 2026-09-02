function Get-HDTDeploymentMethod {
    <#
        .SYNOPSIS
            Answers how this machine reached its content - UNC or MEDIA.

        .DESCRIPTION
            MDT CARRIES TWO VARIABLES HERE AND THEY ARE NOT THE SAME QUESTION.
            ZTIGather.xml declares DeploymentMethod - "the method being used for
            the deployment" - beside DeploymentType, which is NEWCOMPUTER,
            REFRESH or REPLACE. HDT has had HDTDeploymentType since M2 and this
            is the other one: what HDTDeploymentType says is WHAT is being done,
            and a media deployment is still NEWCOMPUTER. This says HOW THE
            MACHINE GOT ITS CONTENT, which is the question every offline-media
            behaviour actually asks.

            TWO VALUES.

              UNC   - the content is on a share, reached over the network.
              MEDIA - the content is on the thing the machine booted from: a
                      disc, a USB stick, an ISO attached to a VM.

            MDT ALSO HAS OSD AND SCCM, AND HDT HAS NEITHER, deliberately. Those
            two are MECM's, and HDT takes no dependency on MECM (CLAUDE.md rule
            4), so a value naming it would describe a deployment this engine
            cannot perform. Two values is the whole set, and
            tests/unit/Get-HDTDeploymentMethod.Tests.ps1 asserts that it stays
            two by reading Resolve-HDTDeployRoot's own ValidateSet rather than
            trusting a literal here.

            IT DECIDES FROM THE PROVIDER, NOT FROM A MARKER ON A DRIVE.
            LiteTouch.wsf walks every ready drive looking for Media.tag and
            defaults to UNC when it finds none, because a VBScript booted by
            WinPE has nothing better to go on. HDT does: bootstrap.json already
            names the provider the boot image was built with, and
            Resolve-HDTDeployRoot already validates it against the same two
            names. Deciding from that means the answer cannot disagree with the
            provider actually in use, which is the failure mode a drive-sniffing
            search has - a stale Media.tag on a second disk and the deployment
            silently stops using the network it is really reading from.

            THE VALIDATESET IS THE REFUSAL. A provider that is neither gets the
            same shape of error Resolve-HDTDeployRoot gives for the same
            mistake, before the body runs, and it costs no branch to maintain.

        .PARAMETER Provider
            The content provider named in bootstrap.json: Smb or Local. Read
            case-insensitively, the way every other bootstrap.json value is.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String. UNC or MEDIA.

        .EXAMPLE
            Get-HDTDeploymentMethod -Provider Smb

            UNC. The deployment is reading from a share.

        .EXAMPLE
            Get-HDTDeploymentMethod -Provider Local

            MEDIA. The deployment is reading from the media it booted from.

        .NOTES
            The variable this feeds is HDTDeploymentMethod, which
            Get-HDTVariableMap marks not writable - it is a fact about how the
            machine booted, not a preference, so a rules.yaml that declares it
            is refused by Assert-HDTRuleDocument.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Smb', 'Local')]
        [string] $Provider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Two branches over a validated set, and nothing else. Anything cleverer
    # here would be a second place UNC/MEDIA is decided.
    if ($Provider -eq 'Local') {
        return 'MEDIA'
    }

    return 'UNC'
}
