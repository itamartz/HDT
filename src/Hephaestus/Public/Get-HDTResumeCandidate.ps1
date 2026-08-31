function Get-HDTResumeCandidate {
    <#
        .SYNOPSIS
            Decides, on a WinPE boot, whether a task sequence is already in progress.

        .DESCRIPTION
            THE OTHER DIRECTION OF THE REBOOT, AND THE ONE THAT WAS MISSING.

            Invoke-HDTTaskSequence has survived the WinPE -> FullOS reboot since
            M2: it checkpoints to state.json, stages the resume agent onto the OS
            volume and arms a logon that runs Start-HDTResume.ps1. Coming BACK -
            FullOS -> WinPE, which is what a Sysprep-and-Capture reference build
            does between generalizing a machine and capturing it - had nothing.
            Start-HDTDeployment.ps1 minted a brand-new run at step 1 on every
            WinPE boot, so the capture leg would have reached the sequence's own
            DiskPartition step and formatted the volume it had just sealed.

            THIS IS A SCAN, NOT A BOOT FLAG, AND THAT IS A DELIBERATE DIVERGENCE
            FROM MDT. MDT reboots into WinPE with `bcdedit /bootsequence`
            pointing at a boot.wim staged on the local disk
            (ZTIBCDUtility.vbs AdjustBCDDefaults, called from LTIApply.wsf
            /PE /BCD). But that is a TRANSPORT: it decides which image the
            firmware loads, it is consumed before one line of deployment code
            runs, and the WinPE that boots has no way to ask whether it arrived
            that way. MDT knows this, which is why MDT ALSO stages C:\MININT and
            looks for it - the boot entry gets the machine there, the marker on
            the disk is what tells LiteTouch it is mid-sequence.

            SO THE DISCOVERY IS KEYED TO THE DISK, NOT THE TRANSPORT. A machine
            can reach WinPE by a one-shot boot entry, by PXE, by an ISO left in
            the drive, or because somebody pressed F12, and in all four cases
            the true answer to "is a run in progress" is identical. A check keyed
            to the transport answers correctly for one of them and mints a fresh
            run - which formats the disk - for the other three. That is the
            failure this command exists to make impossible, so it must not
            depend on how the machine got here.

            AND IT READS state.json RATHER THAN A MARKER OF ITS OWN. The engine
            already mirrors the state document to <OSVolume>\HDT\state.json the
            moment the partition step publishes a volume, so the evidence is
            already on the disk and already proven on real hardware. A separate
            marker file would be a second source of truth about whether a run is
            live, and the case where the two disagree is a wiped disk.

            THE ANSWER IS A THREE-WAY, WHICH IS THE WHOLE SAFETY PROPERTY.

              nothing found, or the run has finished    None       deploy normally
              exactly one live, readable, fresh run     Resume     continue it
              anything else                             Ambiguous  REFUSE

            Invoke-HDTBootReconciliation - the full-OS twin of this - is a
            TWO-WAY, and collapses "cannot tell" into Teardown. That is right
            there, where the worst case of guessing wrong is a machine that does
            not log itself on. It would be catastrophic here, because in WinPE
            "there is no run" means "mint one and start at step 1", and step 1 of
            a deployment sequence formats a disk. So every case this cannot read
            with confidence is Ambiguous, and the caller refuses.

            WHAT IS AMBIGUOUS, AND WHY EACH ONE IS:

              the document will not parse     a half-written state.json is a
                                              CRASHED run, not an absent one.
                                              Import-HDTRunState says it in its
                                              own error: "A run with no state
                                              document starts from the beginning;
                                              one that cannot be read does not."

              two volumes carry one           there is no way to tell which run
                                              this boot belongs to, and picking
                                              has even odds of resuming somebody
                                              else's deployment onto this disk.

              the run is stale                THE ONE DELIBERATE DIVERGENCE from
                                              the full-OS reconcile, which tears
                                              a stale run down. An abandoned run
                                              and a live one are indistinguish-
                                              able to a clock that has skewed,
                                              and WinPE's skews. A stale document
                                              here is a question for a person.

              the volumes cannot be listed    a Storage stack that did not answer
                                              is not evidence of an empty
                                              machine.

            EVERY REFUSAL NAMES THE FILE, because the operator's escape hatch is
            to delete it, and deleting one named file is an explicit act of
            consent in a way that "it started a new deployment" never is.

            X: IS NOT SCANNED. It is the WinPE RAM disk, it is new on every boot,
            and it therefore cannot carry a run ACROSS one. The engine writes
            X:\HDT\Logs\state.json before a formatted volume exists to mirror to,
            so a scan that included it would find this boot's own document and
            make every ordinary deployment resume itself.

        .PARAMETER Disk
            An IDiskService. Only GetVolume() is called - the same flat listing
            of lettered volumes the Local content provider scans.

        .PARAMETER FileSystem
            An IFileSystem.
            Defaults to the real one.

        .PARAMETER Clock
            An IClock. The only source of the current time, which is what the
            staleness test is measured against.

        .PARAMETER ExcludeVolume
            Drive letters the scan skips. Defaults to the WinPE RAM disk.

        .PARAMETER MaxAgeHour
            How stale a Running state may be before it stops counting as live.
            Defaults to 12, matching Invoke-HDTBootReconciliation.

        .PARAMETER LogContext
            Optional. Without it the decision is still made and returned;
            nothing is written.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action
            ('None', 'Resume' or 'Ambiguous'), Reason, State, Path and Candidate.

        .EXAMPLE
            $decision = Get-HDTResumeCandidate -Disk (New-HDTDiskService) `
                -FileSystem (New-HDTFileSystem) -Clock (New-HDTClock)

            What Start-HDTDeployment.ps1 asks before it mints a run. On a machine
            that has never been deployed this answers None in a few milliseconds
            and the ordinary path continues.

        .EXAMPLE
            if ($decision.Action -eq 'Ambiguous') { throw $decision.Reason }

            The refusal. It is a throw rather than a warning because the
            alternative to stopping is partitioning a disk on a guess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Disk,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [AllowNull()]
        [string[]] $ExcludeVolume = @('X'),

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $MaxAgeHour = 12,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $answer = {
        param([string] $Action, [string] $Reason, [object] $State, [string] $Path, [string[]] $Candidate)

        if ($null -ne $LogContext) {
            $severity = 'Info'
            if ($Action -eq 'Ambiguous') { $severity = 'Warning' }

            Write-HDTLog -Context $LogContext -Event 'reboot.discover' -Severity $severity `
                -Message ("WinPE resume discovery: {0} - {1}" -f $Action, $Reason) `
                -Data ([ordered] @{
                    action    = $Action
                    path      = $Path
                    candidate = [string[]] @($Candidate)
                })
        }

        return [pscustomobject] ([ordered] @{
                Action    = [string] $Action
                Reason    = [string] $Reason
                State     = $State
                Path      = [string] $Path
                Candidate = [string[]] @($Candidate)
            })
    }

    # -- 1. the volumes ------------------------------------------------------
    #
    # A LISTING THAT THREW IS NOT AN EMPTY MACHINE. Letting this exception out
    # would be correct too, but the caller's contract is a three-way answer and
    # the refusal reads better than a raw Storage error at a WinPE prompt.
    $volume = $null
    try {
        $volume = @($Disk.GetVolume())
    } catch {
        return (& $answer 'Ambiguous' ("the volumes on this machine could not be listed, so it is not known whether a task sequence is already in progress. Nothing will be partitioned until that is answered: {0}" -f $_.Exception.Message) $null '' @())
    }

    $skip = [string[]] @()
    if ($null -ne $ExcludeVolume) {
        $skip = [string[]] @($ExcludeVolume | ForEach-Object { ([string] $_).Trim().TrimEnd('\', '/').TrimEnd(':') })
    }

    # -- 2. the scan ---------------------------------------------------------
    #
    # [IO.Path]::Combine AND NEVER Join-Path. Join-Path resolves the drive and
    # throws DriveNotFound on a letter this process has not mounted, which is
    # every letter under a fake - so the line could not be tested at all.
    # Get-HDTWorkspacePath carries the same note for the same reason.
    $candidate = New-Object -TypeName System.Collections.ArrayList

    foreach ($row in $volume) {
        if ($null -eq $row) { continue }

        $letter = ([string] $row.DriveLetter).Trim().TrimEnd('\', '/').TrimEnd(':')

        if ($letter -notmatch '^[A-Za-z]$') { continue }
        if ($skip -contains $letter) { continue }

        $path = [System.IO.Path]::Combine(('{0}:\' -f $letter.ToUpperInvariant()), 'HDT', 'state.json')

        if ($FileSystem.TestPath($path)) { [void] $candidate.Add([string] $path) }
    }

    if ($candidate.Count -eq 0) {
        return (& $answer 'None' 'no run is in progress on this machine: no volume carries a state document' $null '' @())
    }

    if ($candidate.Count -gt 1) {
        return (& $answer 'Ambiguous' ("{0} volumes carry a state document ({1}), so it is not known which run this boot belongs to. Resuming the wrong one would run this machine's remaining steps against another deployment's disk. Delete the one that does not belong to this machine and boot again." -f
                $candidate.Count, (@($candidate) -join ', ')) $null '' ([string[]] @($candidate)))
    }

    # -- 3. the one document -------------------------------------------------

    $path = [string] $candidate[0]
    $state = $null

    try {
        $state = Import-HDTRunState -Path $path -FileSystem $FileSystem
    } catch {
        # THE BRANCH THE WHOLE COMMAND IS FOR. A corrupt document is a CRASHED
        # run, and the reading that says otherwise formats a disk.
        return (& $answer 'Ambiguous' ("'{0}' exists but could not be read, so it is not known whether a task sequence is in progress on this machine. A half-written state document is a run that crashed, not a machine with no run on it - and starting a new deployment would partition this disk. Delete '{0}' to deploy this machine from the beginning. Underlying error: {1}" -f
                $path, $_.Exception.Message) $null '' ([string[]] @($path)))
    }

    # A FINISHED RUN IS NOT A RUN IN PROGRESS, and this is the case that keeps
    # a machine redeployable. Its last deployment left this document behind
    # saying Succeeded; an operator who has booted the media again means it.
    if (@('Succeeded', 'Failed') -contains [string] $state.status) {
        return (& $answer 'None' ("'{0}' records a run that has already finished ({1}), so this is a new deployment" -f
                $path, [string] $state.status) $null '' ([string[]] @($path)))
    }

    # STALE IS A QUESTION, NOT A LICENCE. See the description: this is where
    # this command and Invoke-HDTBootReconciliation deliberately disagree.
    if (Test-HDTRunStateAbandoned -State $state -Clock $Clock -MaxAgeHour $MaxAgeHour) {
        return (& $answer 'Ambiguous' ("'{0}' records a run that is still marked Running but has not been written to for over {1} hour(s), so it cannot be told apart from a deployment that is still going. Nothing will be partitioned on a guess. Delete '{0}' to deploy this machine from the beginning, or boot it again if that run is still alive." -f
                $path, $MaxAgeHour) $null '' ([string[]] @($path)))
    }

    return (& $answer 'Resume' ("'{0}' records run {1} in progress, resuming at step {2}" -f
            $path, [string] $state.runId, [int] $state.stepIndex) $state $path ([string[]] @($path)))
}
