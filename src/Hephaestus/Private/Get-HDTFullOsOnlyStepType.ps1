function Get-HDTFullOsOnlyStepType {
    <#
        .SYNOPSIS
            The step types that cannot run in WinPE at all, whatever a sequence
            says.

        .DESCRIPTION
            ONE LIST, IN ONE PLACE, SO THE TEST CAN WALK IT (CLAUDE.md 8).

            DESIGN 10.1 states it for the one member this starts with: "WUA is
            unavailable in WinPE; this step is full-OS only and validation
            rejects it elsewhere."

              WindowsUpdate   The Windows Update Agent COM server -
                              Microsoft.Update.Session - is NOT PRESENT in a
                              WinPE image. Not "does not work well", not
                              "usually fails": the class is not registered,
                              because the WinPE optional components that would
                              carry it do not exist. A WindowsUpdate step in a
                              WinPE group has nothing at all to talk to, and no
                              amount of network, credentials or patience will
                              change that. Offline .msu injection in WinPE is a
                              different step - ApplyUpdates, DESIGN 7.5 - and
                              the refusal names it, because the two step names
                              are close enough that an author who reached for
                              the wrong one needs telling which is right.

            WHY THIS IS A LIST AND NOT AN `if` IN THE FLATTENER. A test
            asserting "a WindowsUpdate step is refused" passes for
            WindowsUpdate and fails nobody after it. A test that walks THIS
            covers the type somebody adds next year without knowing the
            flattener exists, which is the failure mode CLAUDE.md 8 is a list
            of. Get-HDTResumeForbiddenStepType is exactly this pattern, built
            for the same reason.

            WHAT IS DELIBERATELY NOT HERE, AND IT IS MOST OF WHAT LOOKS LIKE IT
            BELONGS. InstallRoles, EnableBitLocker and JoinDomain are full-OS
            steps too - a client OS has no ServerManager, a WinPE RAM disk has
            no volume to encrypt, and there is no machine account to join from a
            preinstallation environment. None of them is here.

            The reason is that their templates already write `runIn: FullOS`,
            and the engine skips a step whose phase does not match
            (Test-HDTStepRunInPhase). An author who goes out of their way to
            write `runIn: WinPE` on one of them is making a mistake that the
            STEP'S OWN failure explains clearly and immediately - "ServerManager
            is not there to ask" names the problem better than a generic
            authoring refusal would.

            Adding them here would be refusal-by-list creeping outward, which is
            how a set stops being a set and becomes a policy: the engine would
            start overruling authors about steps that are merely unwise rather
            than impossible. Revisit only when one of them produces a message
            that does not explain itself.

            SO THE BAR FOR MEMBERSHIP IS: the thing the step talks to DOES NOT
            EXIST in the environment, and the step cannot say so in a way that
            an author would understand.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Get-HDTFullOsOnlyStepType

            WindowsUpdate.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @('WindowsUpdate')
}
