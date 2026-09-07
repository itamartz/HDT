function Get-HDTDeploymentPhase {
    <#
        .SYNOPSIS
            Answers which leg a run STARTED on - WinPE or FullOS - from the
            system drive.

        .DESCRIPTION
            WinPE BOOTS WITH ITS SYSTEM DRIVE AT X:, AND THAT IS THE WHOLE
            EVIDENCE. WinPE runs from a RAM disk which Windows Setup mounts at
            X:; a machine running an installed Windows has its system drive on a
            real volume, which is C: on all but a handful of estates and is never
            X:. So the drive letter is not a proxy for how the machine started -
            it IS how the machine started, and reading it is what MDT has always
            done: LiteTouch.wsf:373-387 tests oEnv("SystemDrive") = "X:" and
            calls the run NEWCOMPUTER when the drive is the RAM disk, REFRESH
            when it is not, and ZTIUtility.vbs:3339-3347 re-derives it per task
            sequence rather than trusting what an earlier leg recorded.

            THE PHASE IS A FACT ABOUT THE RUN'S ORIGIN, NOT A PREFERENCE, and
            that is why nothing lets a caller or a rules.yaml declare it. It
            decides where the log goes (Get-HDTLogPath), what _HDTPhase says, and
            - through Get-HDTMachineFact - whether HDTDeploymentType is
            NEWCOMPUTER or REFRESH, which is the value DESIGN 3.2 makes the one
            thing that can unlock ApplyImage on a resumed leg. An administrator
            who could declare REFRESH on a machine that booted WinPE would not
            get a Refresh; they would get a run that lies about its own origin,
            and every symptom of that points somewhere else. So the answer is
            derived, here, from evidence nothing on the disk can forge.
            Get-HDTVariableMap accordingly marks HDTDeploymentType
            Writable = $false.

            IT TAKES THE VALUE RATHER THAN READING IT, which is the split that
            makes this testable at all. Engine logic never touches the machine
            (CLAUDE.md rule 5): the raw read is the IEnvironmentProvider
            adapter's - $environment.GetVariable('SystemDrive'), the same call
            Invoke-HDTBootToWinPEStep already makes - and every branch is here,
            against a string. That is what lets a fake say 'X:' on a laptop that
            is not in WinPE, and it is why there is no $env: anywhere in this
            file.

            THE COMPARISON IS DELIBERATELY FUSSY, because the shapes differ and
            the cost of getting it wrong is a wiped volume. $env:SystemDrive is
            'C:' with NO trailing separator on a real machine, so a function
            written against 'C:\' would look right and be wrong everywhere; a
            fixture, a fake or a future caller can equally hand over 'X:\', 'x:'
            or a padded string. All of those name the same drive and all of them
            answer the same way. What does NOT answer the same way is a PATH on
            that drive: 'X:\Windows' is a directory, not a system drive, so a
            StartsWith test would call a full-OS machine WinPE.

            AN EMPTY VALUE IS REFUSED RATHER THAN GUESSED. Both guesses are
            destructive - WinPE publishes NEWCOMPUTER on a running Windows,
            FullOS publishes the REFRESH that unlocks ApplyImage - and every
            Windows and every WinPE sets SystemDrive, so nothing is being made
            robust by picking one. Invoke-HDTBootToWinPEStep refuses the same
            absence for the same reason.

        .PARAMETER SystemDrive
            The system drive as the environment reports it: 'X:' in WinPE, 'C:'
            in the full OS. A trailing separator, surrounding whitespace and
            either case are all accepted and all name the same drive.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String. WinPE or FullOS - the same two values every -Phase
            parameter in the module takes.

        .EXAMPLE
            Get-HDTDeploymentPhase -SystemDrive 'X:'

            WinPE. The machine booted the RAM disk, so this is a NEWCOMPUTER
            deployment and the log starts on X:.

        .EXAMPLE
            $environment = New-HDTEnvironmentProvider
            $phase = Get-HDTDeploymentPhase -SystemDrive ([string] $environment.GetVariable('SystemDrive'))

            How the payload asks. The environment is read through the adapter and
            the decision is made here, so both halves can be proven from a desk.

        .NOTES
            The variable this ultimately feeds is HDTDeploymentType, which
            Get-HDTVariableMap marks not writable - DESIGN 3.2.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $SystemDrive
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -Mandatory already refuses $null and ''; this is the value that arrived as
    # spaces, or as a variable that resolved to nothing on the way in. It is the
    # same refusal either way and it names the thing the operator has to fix.
    if ([string]::IsNullOrWhiteSpace($SystemDrive)) {
        throw 'HDTPhaseUnknown: SystemDrive is empty, so which leg this run started on cannot be established. Every Windows and every WinPE sets it, so an empty value means the environment could not be read - and guessing here picks NEWCOMPUTER or REFRESH, which is the value that decides whether a volume is wiped.'
    }

    # Whitespace first, then the separator, so ' X:\ ' and 'X:' are the same
    # drive. TrimEnd takes both separators because a value that has been through
    # a path join can carry either.
    $drive = $SystemDrive.Trim().TrimEnd('\', '/')

    # ONE COMPARISON, AGAINST THE WHOLE STRING. -eq is case-insensitive in
    # PowerShell, which is what makes 'x:' work, and comparing the whole value
    # rather than its first character is what keeps 'X:\Windows' out.
    if ($drive -eq 'X:') {
        return 'WinPE'
    }

    return 'FullOS'
}
