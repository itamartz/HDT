function Assert-HDTCleanVolumeTarget {
    <#
        .SYNOPSIS
            Establishes that a path is the deployment target volume this run is
            standing on, and refuses if it cannot.

        .DESCRIPTION
            THE SUBSTITUTE FOR THE RULE CleanVolume CANNOT SATISFY LITERALLY,
            and the reason it is a function of its own rather than four lines
            inside the step: it has to be the thing that cannot be skipped.

            CLAUDE.md forbids building a delete target by enumerating a parent
            directory, and CleanVolume is exactly an enumerate-and-delete loop.
            DESIGN 3.2 resolves the tension rather than waiving it: that rule
            governs code running on a development host, where the parent
            enumerated could be the repository or the lab, whereas this runs in
            WinPE against a deployment target volume the run has already
            identified. "The substitute for the rule it cannot satisfy literally
            is an assertion: the step establishes which volume it is standing
            on, and refuses if it cannot, before it deletes anything. That
            assertion is what the rule was protecting in the first place."

            FOUR THINGS, AND EACH ONE FORECLOSES A DIFFERENT DISASTER:

              1. A DRIVE LETTER, AND NOTHING ELSE. 'C', 'C:' and 'C:\' are the
                 same volume and all three are accepted; 'C:\Users\bob' and
                 '\\srv\share' are refused. This is the delete rule kept
                 literally where it CAN be kept - the only parent this step may
                 enumerate is a volume root, so a path with a folder in it never
                 reaches the loop at all.

              2. IT IS THERE. A volume that does not exist would enumerate to
                 nothing and report a clean that emptied a machine which was
                 never touched.

              3. IT CARRIES THIS RUN'S OWN STATE DIRECTORY. <volume>\HDT is
                 where the full-OS leg mirrored state.json, staged the boot
                 image under Boot\ and put the logs, which is how the resumed
                 leg found the run at all. A volume without it is not the volume
                 this run identified - it is a second disk, a USB stick or a
                 data volume that happens to have a letter - and the step will
                 not empty one on the strength of a letter alone. THIS is the
                 clause that means "the volume it is standing on" rather than
                 "a volume".

              4. IT IS NOT THE VOLUME THE ENGINE IS RUNNING FROM. You cannot
                 delete the Windows you are running: LTIApply.wsf:882 gates the
                 whole clean on OSVersion = WinPE for this reason, and
                 LiteTouch.wsf:373-387 reads the same evidence this does -
                 SystemDrive, which is X: on a WinPE leg and C: in the full OS.
                 One clause therefore does both jobs. In WinPE it refuses X:\,
                 where deleting X:\Windows would destroy the running
                 environment mid-step; in the full OS it refuses C:\, which is
                 the gate MDT states as a phase check.

            IT THROWS RATHER THAN RETURNING FALSE, because every refusal here
            has a different cause and a bare $false would collapse them into
            "no". The step catches, reports the message and the errorId, and
            returns a Failed result - a refusal is returned, not thrown, at the
            step boundary, exactly as Invoke-HDTDiskPartitionStep's is.

        .PARAMETER Volume
            What the step was given: a drive letter, with or without its colon
            and separator.

        .PARAMETER FileSystem
            The injected IFileSystem. Everything this reads goes through it, so
            the assertion is provable against the hand-written fake.

        .PARAMETER SystemDrive
            The volume the engine is running from, read off IEnvironmentProvider
            by the caller. Empty is not an excuse: a run that cannot say where
            it is running from cannot say that this volume is not it.

        .OUTPUTS
            System.String - the volume root, normalised to '<letter>:\'.

        .EXAMPLE
            Assert-HDTCleanVolumeTarget -Volume 'C' -FileSystem $fs -SystemDrive 'X:'

            'C:\', on a WinPE leg standing on the volume the full OS was on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Volume,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $SystemDrive
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $said = [string] $Volume
    if ($null -eq $said) { $said = '' }

    $letter = $said.Trim().TrimEnd('\').TrimEnd(':')

    if ($letter.Length -eq 0) {
        throw [System.ArgumentException]::new(
            'no volume was named. This step empties a volume, so it is given one; it does not go looking for a disk to guess at.')
    }

    # ONE LETTER IS ONE LETTER. Taking the first character of whatever arrived
    # is how Invoke-HDTApplyImageStep once applied Windows to T:\ because
    # somebody wrote 'the big disk', and this step deletes rather than writes.
    if ($letter -notmatch '^[A-Za-z]$') {
        throw [System.ArgumentException]::new(
            ("'{0}' is not a volume. This step empties a volume root and nothing else: a path with a folder in it, or a share, is never a delete target here." -f $said))
    }

    $root = '{0}:\' -f $letter.ToUpperInvariant()

    # Compared as a letter rather than as a path: SystemDrive is 'X:' with no
    # separator, and the two spellings must not be able to disagree.
    $running = [string] $SystemDrive
    if ($null -eq $running) { $running = '' }
    $running = $running.Trim().TrimEnd('\').TrimEnd(':')

    if ($running.Length -eq 0) {
        throw [System.InvalidOperationException]::new(
            ("this run cannot say which volume it is running from, so it cannot say that {0} is not it. Deleting the volume the engine is running from destroys the run mid-step." -f $root))
    }

    # -eq on strings is case-insensitive in PowerShell, which is the comparison
    # a drive letter wants: 'c' and 'C' are one volume.
    if ($running -eq $letter) {
        throw [System.InvalidOperationException]::new(
            ("{0} is the volume this engine is running from. You cannot delete the Windows you are running: a Refresh empties the OS volume from the staged WinPE it rebooted into, never from the full OS it started in." -f $root))
    }

    if (-not $FileSystem.TestPath($root)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            ("{0} is not there. A volume that does not exist enumerates to nothing, and a clean that emptied nothing would report success on a machine it never touched." -f $root))
    }

    # THE CLAUSE THAT SAYS WHICH VOLUME THIS RUN IS STANDING ON. See the
    # description: <volume>\HDT is this run's mirrored state, its staged boot
    # image and its logs, and a volume without one is not the volume the run
    # identified.
    $state = [IO.Path]::Combine($root, 'HDT')

    if (-not $FileSystem.TestPath($state)) {
        throw [System.InvalidOperationException]::new(
            ("{0} does not carry this run's own state directory at {1}, so it is not the volume this deployment identified. HDT will not empty a volume on the strength of a drive letter." -f $root, $state))
    }

    return $root
}
